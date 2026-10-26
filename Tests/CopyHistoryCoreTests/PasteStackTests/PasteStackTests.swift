import Foundation
import Testing
@testable import CopyHistoryCore

// Fake secrets only: none of these values is a real credential.
private let fakeKey = "sk-proj-FAKEFAKEFAKEFAKEFAKEFAKE1234"

/// Both sides of one pasteboard, like `NSPasteboard.general`: the stack reads back what was copied.
private final class RecordingPasteboard: PasteboardWriting, PasteboardReading {
  var changeCount = 0
  var contents: [String: Data] = [:]
  var lastClearWasCurrentHostOnly = false
  func clearContents(currentHostOnly: Bool) {
    contents = [:]; changeCount += 1; lastClearWasCurrentHostOnly = currentHostOnly
  }
  func setString(_ string: String, forType type: String) { contents[type] = Data(string.utf8) }
  func setData(_ data: Data, forType type: String) { contents[type] = data }

  var text: String? { contents["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } }
  var isConcealed: Bool { contents["org.nspasteboard.ConcealedType"] != nil }
  var isInternal: Bool { contents["com.example.copyhistory.internal"] != nil }
  /// Simulates another app (or the user) writing to the pasteboard.
  func externalCopy(_ s: String) { clearContents(currentHostOnly: false); setString(s, forType: "public.utf8-plain-text") }
  func externalCopy(png: Data) { clearContents(currentHostOnly: false); setData(png, forType: "public.png") }

  var types: [String] { Array(contents.keys) }
  func string() -> String? { text }
  func pngData() -> Data? { contents["public.png"] }
  var frontmostAppBundleID: String? { nil }
}

/// Collects scheduled work so tests run it explicitly instead of sleeping.
@MainActor
private final class ManualScheduler {
  var pending: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
  var closure: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void {
    { [unowned self] delay, work in self.pending.append((delay, work)) }
  }
  /// Runs everything scheduled with exactly `delay` (in scheduling order).
  func run(delay: TimeInterval) {
    let due = pending.filter { $0.delay == delay }
    pending.removeAll { $0.delay == delay }
    due.forEach { $0.work() }
  }
}

@MainActor
private final class FakeKeyMonitor: PasteKeyMonitoring {
  var available = true
  var onKey: (@MainActor (PasteStackKeyPress) -> Void)?
  var startCount = 0, stopCount = 0
  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool {
    startCount += 1
    guard available else { return false }
    self.onKey = onKey
    return true
  }
  func stop() { stopCount += 1; onKey = nil }
  func press(_ key: PasteStackKeyPress) { onKey?(key) }
}

private let cmdV = PasteStackKeyPress(keyCode: PasteStackKeyPress.vKeyCode, modifiers: .command, character: "v")
private let ownCmdV = PasteStackKeyPress(keyCode: PasteStackKeyPress.vKeyCode, modifiers: .command, character: "v",
                                         fromOwnProcess: true)
private let escapeKeyCode: UInt16 = 53
private let esc = PasteStackKeyPress(keyCode: escapeKeyCode, modifiers: [])

private func text(_ s: String) -> ClipboardEntry { ClipboardEntry(kind: .text, text: s) }
private func flagged(_ s: String) -> ClipboardEntry {
  ClipboardEntry(kind: .text, text: s, findings: [SecretFinding(category: .openAIKey, range: 0..<s.count)])
}

@MainActor
private struct Harness {
  let pasteboard = RecordingPasteboard()
  let scheduler = ManualScheduler()
  let keys = FakeKeyMonitor()
  let clock = Clock()
  let engine: PasteStackEngine
  var events: [PasteStackEngine.Event] { recorder.events }
  private let recorder = EventRecorder()

  init(capacity: Int = PasteStack.defaultCapacity, maxBytes: Int = PasteStack.defaultMaxBytes) {
    let writer = PasteStackPasteboardWriter(pasteboard: pasteboard, reader: pasteboard, schedule: scheduler.closure)
    let clock = clock
    engine = PasteStackEngine(writer: writer, keyMonitor: keys, capacity: capacity, maxBytes: maxBytes,
                              now: { clock.now }, schedule: scheduler.closure)
    let recorder = recorder
    engine.onEvent = { recorder.events.append($0) }
  }

  /// One ⌘V followed by the advance delay elapsing.
  func paste() {
    keys.press(cmdV)
    scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
  }

  /// The user copies `entry` and the clipboard monitor delivers it, as in the app.
  @discardableResult
  func copy(_ entry: ClipboardEntry, awaitingOCR: Bool = false) -> Bool {
    switch entry.kind {
    case .text: pasteboard.externalCopy(entry.text ?? "")
    case .image: pasteboard.externalCopy(png: entry.imagePNG ?? Data())
    }
    return engine.enqueue(entry, awaitingOCR: awaitingOCR)
  }

  /// A clipboard monitor poll has had time to see the pasteboard.
  func settle() { scheduler.run(delay: PasteStackEngine.monitorSettleDelay) }
}

@MainActor private final class EventRecorder { var events: [PasteStackEngine.Event] = [] }
private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }

// MARK: Model

@Suite struct PasteStackModelTests {
  // Swift Testing cannot evaluate mutating calls inside #expect, so results are bound first.

  @Test func fifoOrder() {
    var stack = PasteStack()
    stack.start()
    let accepted = ["one", "two", "three"].map { stack.enqueue(text($0)) }
    #expect(accepted == [true, true, true])
    #expect(stack.count == 3)
    #expect(stack.peek?.text == "one")
    var popped: [String?] = []
    for _ in 0..<4 { popped.append(stack.popNext()?.text) }
    #expect(popped == ["one", "two", "three", nil])
    #expect(stack.isActive)
  }

  @Test func inactiveStackRejectsEntries() {
    var stack = PasteStack()
    #expect(!stack.isActive)
    let accepted = stack.enqueue(text("ignored"))
    #expect(!accepted)
    #expect(stack.isEmpty)
  }

  @Test func capacityIsBounded() {
    var stack = PasteStack(capacity: 2)
    stack.start()
    let accepted = ["a", "b", "c"].map { stack.enqueue(text($0)) }
    #expect(accepted == [true, true, false])
    #expect(stack.count == 2)
    #expect(PasteStack(capacity: 0).capacity == 1)
  }

  @Test func payloadBytesAreBounded() {
    var stack = PasteStack(maxBytes: 10)
    stack.start()
    let accepted = [
      ClipboardEntry(kind: .image, imagePNG: Data(count: 6)),
      ClipboardEntry(kind: .image, imagePNG: Data(count: 6)),  // 12 > 10
      text("abcd"),                                              // 6 + 4 = 10
    ].map { stack.enqueue($0) }
    #expect(accepted == [true, false, true])
    #expect(stack.byteCount == 10)
    stack.popNext()
    #expect(stack.byteCount == 4)
    let fits = stack.enqueue(text("é"))  // 2 UTF-8 bytes
    #expect(fits)
    #expect(stack.byteCount == 6)
    stack.clear()
    #expect(stack.byteCount == 0)
  }

  @Test func entriesWithoutPayloadAreRejected() {
    var stack = PasteStack()
    stack.start()
    let accepted = [
      ClipboardEntry(kind: .text, text: nil),
      ClipboardEntry(kind: .text, text: ""),
      ClipboardEntry(kind: .image, imagePNG: nil),
      ClipboardEntry(kind: .image, imagePNG: Data([0x89])),
    ].map { stack.enqueue($0) }
    #expect(accepted == [false, false, false, true])
  }

  @Test func clearAndStop() {
    var stack = PasteStack()
    stack.start()
    stack.enqueue(text("a"))
    stack.clear()
    #expect(stack.isEmpty && stack.isActive)
    stack.enqueue(text("b"))
    stack.stop()
    #expect(stack.isEmpty && !stack.isActive)
  }

  @Test func flaggedEntriesStayFlagged() {
    var stack = PasteStack()
    stack.start()
    let secret = flagged(fakeKey)
    stack.enqueue(secret)
    let popped = stack.popNext()
    #expect(popped?.findings == secret.findings)
  }

  @Test func updateChangesOnlyTheMatchingEntry() {
    var stack = PasteStack()
    stack.start()
    let a = text("a"), b = text("b")
    stack.enqueue(a)
    stack.enqueue(b)
    let found = stack.update(id: b.id) { $0.ocrText = "x" }
    let missing = stack.update(id: UUID()) { $0.ocrText = "y" }
    #expect(found && !missing)
    #expect(stack.items.map(\.ocrText) == [nil, "x"])
  }
}

// MARK: Key classification

@Suite struct PasteStackKeyPressTests {
  @Test func onlyPlainCommandVPastes() {
    #expect(cmdV.action == .paste)
    let v = PasteStackKeyPress.vKeyCode
    #expect(PasteStackKeyPress(keyCode: v, modifiers: [.command, .shift]).action == .ignore)   // popup hotkey
    #expect(PasteStackKeyPress(keyCode: v, modifiers: [.command, .option]).action == .ignore)  // fallback hotkey
    #expect(PasteStackKeyPress(keyCode: v, modifiers: []).action == .ignore)
    #expect(PasteStackKeyPress(keyCode: 8, modifiers: .command).action == .ignore)  // ⌘C
  }

  @Test func autorepeatIsIgnoredAndOwnPastesAreTold() {
    let v = PasteStackKeyPress.vKeyCode
    #expect(PasteStackKeyPress(keyCode: v, modifiers: .command, isAutorepeat: true).action == .ignore)
    // PasteService synthesizes ⌘V for popup pastes; those must not advance the stack.
    #expect(ownCmdV.action == .ownPaste)
  }

  @Test func commandVIsMatchedByLayoutCharacterNotKeycode() {
    // Dvorak: keycode 9 types "k", so it is ⌘K; ⌘V is keycode 47.
    #expect(PasteStackKeyPress(keyCode: 9, modifiers: .command, character: "k").action == .ignore)
    #expect(PasteStackKeyPress(keyCode: 47, modifiers: .command, character: "v").action == .paste)
    // Dvorak - QWERTY ⌘ and QWERTY: keycode 9 types "v" with ⌘ held.
    #expect(PasteStackKeyPress(keyCode: 9, modifiers: .command, character: "v").action == .paste)
    #expect(PasteStackKeyPress(keyCode: 9, modifiers: .command, character: "V").action == .paste)
    // Layout unreadable: the QWERTY keycode is the best guess.
    #expect(PasteStackKeyPress(keyCode: 9, modifiers: .command).action == .paste)
    #expect(PasteStackKeyPress(keyCode: 40, modifiers: .command).action == .ignore)
  }

  @Test func escapeIsIgnored() {
    // A stray Esc (autocomplete, IME, vim) must not throw the queue away.
    #expect(esc.action == .ignore)
    #expect(PasteStackKeyPress(keyCode: escapeKeyCode, modifiers: .command).action == .ignore)
  }
}

// MARK: Preview

@Suite struct PasteStackPreviewTests {
  @Test func flaggedTextNeverShowsPlaintext() {
    let title = PasteStackPreview.title(for: flagged("token \(fakeKey)"))
    #expect(!title.contains("FAKE"))
    #expect(!title.contains("token"))
    #expect(title.contains("OpenAI key"))
  }

  @Test func flaggedImageNeverShowsOCRText() {
    let entry = ClipboardEntry(kind: .image, imagePNG: Data([1]),
                               findings: [SecretFinding(category: .awsAccessKey, range: 0..<20)],
                               ocrText: "AKIAFAKEFAKEFAKEFAKE")
    let title = PasteStackPreview.title(for: entry)
    #expect(!title.contains("AKIA"))
    #expect(title.contains("Image"))
  }

  @Test func textIsCollapsedAndTruncated() {
    #expect(PasteStackPreview.title(for: text("  hello\n\n\tworld  ")) == "hello world")
    let long = String(repeating: "x", count: 10_000)
    let title = PasteStackPreview.title(for: text(long), maxLength: 20)
    #expect(title == String(repeating: "x", count: 20) + "…")
    #expect(PasteStackPreview.title(for: text(" \n ")) == "(blank text)")
  }

  @Test func imageShowsOCRSnippetWhenClean() {
    #expect(PasteStackPreview.title(for: ClipboardEntry(kind: .image, imagePNG: Data([1]))) == "Image")
    let entry = ClipboardEntry(kind: .image, imagePNG: Data([1]), ocrText: "Invoice\n42")
    #expect(PasteStackPreview.title(for: entry) == "Image — Invoice 42")
  }
}

// MARK: Engine

@MainActor @Suite struct PasteStackEngineTests {
  @Test func pastesInCopyOrderAndEndsWhenEmpty() {
    let h = Harness()
    #expect(h.engine.start(useKeyMonitor: true) == .commandV)
    for s in ["1", "2", "3"] { #expect(h.copy(text(s))) }
    // The head is back on the pasteboard, marked so the clipboard monitor skips it.
    #expect(h.pasteboard.text == "1")
    #expect(h.pasteboard.isInternal)

    h.paste()
    #expect(h.pasteboard.text == "2")
    h.paste()
    #expect(h.pasteboard.text == "3")
    h.paste()
    #expect(!h.engine.isActive)
    #expect(h.events.last == .ended(.finished))
    #expect(h.keys.stopCount == 1)
  }

  @Test func rapidPressesAdvanceOnce() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("a"))
    h.copy(text("b"))
    h.copy(text("c"))
    h.keys.press(cmdV)
    h.keys.press(cmdV)
    h.keys.press(cmdV)
    h.scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
    #expect(h.engine.count == 2)
    #expect(h.pasteboard.text == "b")
  }

  @Test func commandVOnEmptyQueueKeepsModeOn() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.paste()
    #expect(h.engine.isActive)
    #expect(h.pasteboard.changeCount == 0)
  }

  @Test func escapeDoesNotCancel() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("a"))
    h.keys.press(esc)
    #expect(h.engine.isActive)
    #expect(h.engine.count == 1)
    #expect(!h.events.contains(.ended(.cancelled)))
  }

  @Test func pendingAdvanceIsDroppedAfterCancel() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("a"))
    h.copy(text("b"))
    h.keys.press(cmdV)
    h.engine.cancel()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("x"))
    h.copy(text("y"))
    h.scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
    #expect(h.engine.count == 2)
    #expect(h.pasteboard.text == "x")
  }

  @Test func ignoredKeysDoNothing() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("a"))
    let before = h.pasteboard.changeCount
    h.keys.press(ownCmdV)
    h.keys.press(PasteStackKeyPress(keyCode: PasteStackKeyPress.vKeyCode, modifiers: .command, isAutorepeat: true))
    h.keys.press(PasteStackKeyPress(keyCode: 9, modifiers: .command, character: "k"))  // ⌘K on Dvorak
    h.scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
    #expect(h.engine.count == 1)
    #expect(h.pasteboard.changeCount == before)
  }

  @Test func externalWriteMeansHeadWasNotPasted() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("a"))
    h.copy(text("b"))
    // The user copied something new; its ⌘V pasted that, not the head.
    h.pasteboard.externalCopy("other")
    h.paste()
    #expect(h.engine.count == 2)
    #expect(h.pasteboard.text == "other")  // until a monitor poll has seen it
    h.settle()
    #expect(h.pasteboard.text == "a")
    h.paste()
    #expect(h.pasteboard.text == "b")
  }

  @Test func fallbackWhenKeyMonitorUnavailable() {
    let h = Harness()
    h.keys.available = false
    #expect(h.engine.start(useKeyMonitor: true) == .fallbackHotKey)
    h.copy(text("a"))
    h.copy(text("b"))
    h.keys.press(cmdV)  // never delivered in practice; must not advance even if it were
    #expect(h.scheduler.pending.isEmpty)
    h.engine.advanceNow()
    #expect(h.pasteboard.text == "b")
    h.engine.advanceNow()
    #expect(!h.engine.isActive)
    #expect(h.keys.stopCount == 0)
  }

  @Test func deniedPermissionSkipsKeyMonitor() {
    let h = Harness()
    #expect(h.engine.start(useKeyMonitor: false) == .fallbackHotKey)
    #expect(h.keys.startCount == 0)
  }

  @Test func startWhileActiveKeepsQueue() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("a"))
    h.engine.start(useKeyMonitor: true)
    #expect(h.engine.count == 1)
    #expect(h.keys.startCount == 1)
  }

  @Test func fullQueueRejects() {
    let h = Harness(capacity: 1)
    h.engine.start(useKeyMonitor: true)
    #expect(h.copy(text("a")))
    #expect(!h.copy(text("b")))
    #expect(h.engine.lastRejection == .full)
  }

  @Test func enqueueWhileOffIsIgnored() {
    let h = Harness()
    #expect(!h.engine.enqueue(text("a")))
    #expect(h.pasteboard.changeCount == 0)
  }

  // MARK: Secrets

  @Test func flaggedHeadIsConcealedAndClearedLater() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(flagged(fakeKey))
    #expect(h.pasteboard.text == fakeKey)
    #expect(h.pasteboard.isConcealed)
    #expect(h.pasteboard.isInternal)
    #expect(h.pasteboard.lastClearWasCurrentHostOnly)
    #expect(h.scheduler.pending.contains { $0.delay == PasteStackEngine.secretHoldSeconds })
    h.scheduler.run(delay: PasteStackEngine.secretHoldSeconds)
    #expect(h.pasteboard.text == nil)
  }

  @Test func clearedSecretIsRewrittenNotSkipped() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(flagged(fakeKey))
    h.copy(text("next"))
    h.scheduler.run(delay: PasteStackEngine.secretHoldSeconds)
    // ⌘V pasted an empty pasteboard: the secret must not be popped unpasted.
    h.paste()
    h.settle()
    #expect(h.engine.count == 2)
    #expect(h.pasteboard.text == fakeKey)
    #expect(h.pasteboard.isConcealed)
  }

  @Test func plainEntryAfterSecretIsNotConcealed() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(flagged(fakeKey))
    h.copy(text("plain"))
    h.paste()
    #expect(h.pasteboard.text == "plain")
    #expect(!h.pasteboard.isConcealed)
    #expect(!h.pasteboard.lastClearWasCurrentHostOnly)
  }

  @Test func cancelShortensSecretClear() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(flagged(fakeKey))
    h.engine.cancel()
    #expect(h.pasteboard.isConcealed)
    h.scheduler.run(delay: PasteStackEngine.secretClearAfterCancel)
    #expect(h.pasteboard.text == nil)
  }

  @Test func cancelLeavesSomeoneElsesCopyAlone() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(flagged(fakeKey))
    h.pasteboard.externalCopy("mine")
    h.engine.cancel()
    #expect(h.pasteboard.text == "mine")
  }

  @Test func lastPastedSecretIsClearedSoon() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(flagged(fakeKey))
    h.paste()
    #expect(!h.engine.isActive)
    #expect(h.pasteboard.isConcealed)
    h.scheduler.run(delay: PasteStackEngine.secretClearAfterPaste)
    #expect(h.pasteboard.text == nil)
  }

  @Test func flaggedImageIsConcealed() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    h.copy(ClipboardEntry(kind: .image, imagePNG: png,
                                    findings: [SecretFinding(category: .awsAccessKey, range: 0..<20)],
                                    ocrText: "AKIAFAKEFAKEFAKEFAKE"))
    #expect(h.pasteboard.contents["public.png"] == png)
    #expect(h.pasteboard.isConcealed)
    #expect(h.pasteboard.text == nil)  // OCR text is never put on the pasteboard
  }

  @Test func plainImageIsInternalButNotConcealed() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(ClipboardEntry(kind: .image, imagePNG: Data([1, 2])))
    #expect(h.pasteboard.isInternal)
    #expect(!h.pasteboard.isConcealed)
  }

  // MARK: Late OCR results

  @Test func imageAwaitingOCRIsConcealedUntilCleanResult() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    let image = ClipboardEntry(kind: .image, imagePNG: Data([1, 2]))
    h.copy(image, awaitingOCR: true)
    #expect(h.pasteboard.isConcealed)
    h.engine.applyOCR(entryID: image.id, ocrText: "hello", findings: [])
    #expect(!h.pasteboard.isConcealed)
    #expect(h.pasteboard.isInternal)
    #expect(h.engine.stack.peek?.ocrText == "hello")
  }

  @Test func lateOCRFindingKeepsImageConcealedAndFlagged() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("first"))
    let image = ClipboardEntry(kind: .image, imagePNG: Data([1, 2]))
    h.copy(image, awaitingOCR: true)
    let findings = [SecretFinding(category: .awsAccessKey, range: 0..<20)]
    h.engine.applyOCR(entryID: image.id, ocrText: "AKIAFAKEFAKEFAKEFAKE", findings: findings)
    #expect(h.pasteboard.text == "first")  // the head is untouched
    h.paste()
    #expect(h.pasteboard.contents["public.png"] == Data([1, 2]))
    #expect(h.pasteboard.isConcealed)
    #expect(h.engine.stack.peek?.findings == findings)
  }

  @Test func pendingOCRImageStaysConcealedWhenPastedLast() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(ClipboardEntry(kind: .image, imagePNG: Data([3])), awaitingOCR: true)
    h.paste()
    #expect(!h.engine.isActive)
    #expect(h.pasteboard.isConcealed)
    h.scheduler.run(delay: PasteStackEngine.secretClearAfterPaste)
    #expect(h.pasteboard.contents["public.png"] == nil)
  }

  @Test func ocrForUnknownEntryIsIgnored() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("a"))
    let before = h.pasteboard.changeCount
    h.engine.applyOCR(entryID: UUID(), ocrText: "x", findings: [])
    #expect(h.pasteboard.changeCount == before)
  }
}

// MARK: Copies racing the stack's own writes

@MainActor @Suite struct PasteStackRaceTests {
  @Test func newerCopyIsNotOverwrittenByAnEarlierDelivery() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("A"))
    // The user copies X, then Y before the monitor has delivered X.
    h.pasteboard.externalCopy("X")
    h.pasteboard.externalCopy("Y")
    h.engine.enqueue(text("X"))
    #expect(h.pasteboard.text == "Y")
    #expect(!h.pasteboard.isInternal)
    // Y arrives: it joins the queue, and only now does the head go back.
    h.engine.enqueue(text("Y"))
    #expect(h.engine.stack.items.map(\.text) == ["A", "X", "Y"])
    #expect(h.pasteboard.text == "A")
    #expect(h.pasteboard.isInternal)
  }

  @Test func copyDuringTheAdvanceDelayIsKeptAndTheHeadIsNotPastedTwice() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("A"))
    h.copy(text("B"))
    h.keys.press(cmdV)                  // pastes A
    h.pasteboard.externalCopy("Y")      // within the 120 ms
    h.scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
    #expect(h.engine.stack.items.map(\.text) == ["B"])  // A was pasted: popped
    #expect(h.pasteboard.text == "Y")                   // the user's copy survives
    h.engine.enqueue(text("Y"))
    #expect(h.engine.stack.items.map(\.text) == ["B", "Y"])
    #expect(h.pasteboard.text == "B")
    h.paste()
    #expect(h.pasteboard.text == "Y")
  }

  @Test func undeliveredCopyThatWasPastedIsNotOverwrittenBeforeAPoll() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("A"))
    h.pasteboard.externalCopy("Z")  // not polled yet
    h.paste()                       // pasted Z, not the head
    #expect(h.engine.count == 1)
    #expect(h.pasteboard.text == "Z")
    h.engine.enqueue(text("Z"))     // the monitor delivers it
    #expect(h.engine.stack.items.map(\.text) == ["A", "Z"])
    #expect(h.pasteboard.text == "A")
    h.settle()                      // the stale restore must not fire twice
    #expect(h.pasteboard.text == "A")
  }

  @Test func skippedCopyIsLeftAloneUntilPastedOnce() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("A"))
    h.copy(text("B"))
    h.keys.press(cmdV)
    h.pasteboard.externalCopy("password")  // a concealed copy the monitor never delivers
    h.scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
    h.settle()
    #expect(h.pasteboard.text == "password")
    h.paste()                              // the user pastes the password
    #expect(h.engine.stack.items.map(\.text) == ["B"])
    h.settle()
    #expect(h.pasteboard.text == "B")
  }

  @Test func imageDeliveryDoesNotOverwriteANewerTextCopy() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("A"))
    let image = ClipboardEntry(kind: .image, imagePNG: Data([1, 2, 3]))
    h.pasteboard.externalCopy(png: Data([1, 2, 3]))
    h.pasteboard.externalCopy("typed later")
    h.engine.enqueue(image, awaitingOCR: true)
    #expect(h.pasteboard.text == "typed later")
    h.engine.enqueue(text("typed later"))
    #expect(h.pasteboard.text == "A")
  }

  // MARK: Popup pastes (L1)

  @Test func headReturnsAfterThePopupPastes() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("A"))
    h.copy(text("B"))
    h.pasteboard.externalCopy("from popup")  // the popup's (internal) write
    h.keys.press(ownCmdV)
    h.scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
    #expect(h.pasteboard.text == "A")
    #expect(h.engine.count == 2)
    h.paste()
    #expect(h.pasteboard.text == "B")
  }

  @Test func headDoesNotReturnOverACopyMadeAfterThePopupPaste() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    h.copy(text("A"))
    h.pasteboard.externalCopy("from popup")
    h.keys.press(ownCmdV)
    h.pasteboard.externalCopy("Y")
    h.scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
    #expect(h.pasteboard.text == "Y")
  }

  // MARK: Rejections (L2)

  @Test func rejectionSaysWhyAndPutsTheHeadBack() {
    let h = Harness(maxBytes: 5)
    h.engine.start(useKeyMonitor: true)
    h.copy(text("abc"))
    #expect(!h.copy(text("defgh")))
    #expect(h.engine.lastRejection == .tooLarge)
    #expect(h.pasteboard.text == "abc")  // ⌘V still pastes the stack, not the rejected copy
    #expect(h.copy(text("de")))
    #expect(h.engine.lastRejection == nil)
    var stack = PasteStack(capacity: 1)
    stack.start()
    #expect(stack.rejection(for: text("")) == .empty)
    stack.enqueue(text("x"))
    #expect(stack.rejection(for: text("y")) == .full)
    #expect(PasteStack().rejection(for: text("y")) == .inactive)
  }

  // MARK: Expiry (L5)

  @Test func expiredSecretsLeaveTheStack() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    var secret = flagged(fakeKey)
    secret.expiresAt = h.clock.now.addingTimeInterval(60)
    h.copy(secret)
    h.copy(text("after"))
    #expect(h.pasteboard.text == fakeKey)
    h.clock.now += 61
    h.scheduler.run(delay: 60)
    #expect(h.engine.stack.items.map(\.text) == ["after"])
    #expect(h.pasteboard.text == "after")
    #expect(!h.pasteboard.isConcealed)
    #expect(h.events.last == .changed)
  }

  @Test func expiredSecretIsNeverWrittenAgain() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    var secret = flagged(fakeKey)
    secret.expiresAt = h.clock.now.addingTimeInterval(60)
    h.copy(text("first"))
    h.copy(secret)
    h.clock.now += 61  // the expiry timer has not fired yet
    h.paste()
    #expect(h.engine.stack.isEmpty)
    #expect(h.pasteboard.text == "first")
  }

  @Test func pastingAnExpiredHeadDoesNotPopTheNextEntry() {
    let h = Harness()
    h.engine.start(useKeyMonitor: true)
    var secret = flagged(fakeKey)
    secret.expiresAt = h.clock.now.addingTimeInterval(60)
    h.copy(secret)
    h.copy(text("B"))
    h.copy(text("C"))
    h.clock.now += 61  // expired, but its timer has not fired yet
    h.paste()          // the user pasted the secret
    #expect(h.engine.stack.items.map(\.text) == ["B", "C"])
    #expect(h.pasteboard.text == "B")
  }
}

// MARK: Keyboard layouts (real system layouts)

@MainActor @Suite struct KeyboardLayoutCharacterTests {
  private func commandCharacter(_ keyCode: UInt16, _ sourceID: String) throws -> String? {
    let layout = try #require(KeyboardLayoutCharacter.layoutData(inputSourceID: sourceID))
    return KeyboardLayoutCharacter.character(forKeyCode: keyCode, layout: layout)
  }

  @Test func qwertyCommandVIsKeycode9() throws {
    #expect(try commandCharacter(9, "com.apple.keylayout.US") == "v")
  }

  @Test func dvorakCommandVIsNotKeycode9() throws {
    #expect(try commandCharacter(9, "com.apple.keylayout.Dvorak") == "k")
    #expect(try commandCharacter(47, "com.apple.keylayout.Dvorak") == "v")
    let press = PasteStackKeyPress(keyCode: 9, modifiers: .command,
                                   character: try commandCharacter(9, "com.apple.keylayout.Dvorak"))
    #expect(press.action == .ignore)
  }

  @Test func nonLatinLayoutsKeepCommandVOnKeycode9() throws {
    // macOS gives ⌘ shortcuts on Cyrillic/Greek layouts their Latin key; the stack must too.
    #expect(try commandCharacter(9, "com.apple.keylayout.Russian") == "v")
    #expect(try commandCharacter(9, "com.apple.keylayout.Greek") == "v")
  }

  @Test func dvorakQwertyCommandSwitchesToQwertyUnderCommand() throws {
    #expect(try commandCharacter(9, "com.apple.keylayout.DVORAK-QWERTYCMD") == "v")
  }

  @Test func currentLayoutResolves() {
    #expect(KeyboardLayoutCharacter.currentCommandCharacter(forKeyCode: 9) != nil)
  }
}
