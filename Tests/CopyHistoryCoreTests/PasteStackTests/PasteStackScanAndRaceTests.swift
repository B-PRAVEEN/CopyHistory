import Foundation
import Testing
@testable import CopyHistoryCore

/// Both sides of one pasteboard, like `NSPasteboard.general`.
private final class SharedPasteboard: PasteboardWriting, PasteboardReading {
  var changeCount = 0
  var contents: [String: Data] = [:]
  func clearContents(currentHostOnly: Bool) { contents = [:]; changeCount += 1 }
  func setString(_ string: String, forType type: String) { contents[type] = Data(string.utf8) }
  func setData(_ data: Data, forType type: String) { contents[type] = data }

  var text: String? { contents["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } }
  var png: Data? { contents["public.png"] }
  var isConcealed: Bool { contents["org.nspasteboard.ConcealedType"] != nil }
  func externalCopy(_ s: String) { clearContents(currentHostOnly: false); setString(s, forType: "public.utf8-plain-text") }
  func externalCopy(png: Data) { clearContents(currentHostOnly: false); setData(png, forType: "public.png") }

  var types: [String] { Array(contents.keys) }
  func string() -> String? { text }
  func pngData() -> Data? { png }
  var frontmostAppBundleID: String? { nil }
}

/// Collects scheduled work so tests run it explicitly instead of sleeping.
@MainActor
private final class Scheduler {
  var pending: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
  var closure: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void {
    { [unowned self] delay, work in self.pending.append((delay, work)) }
  }
  func run(delay: TimeInterval) {
    let due = pending.filter { $0.delay == delay }
    pending.removeAll { $0.delay == delay }
    due.forEach { $0.work() }
  }
}

@MainActor
private final class Keys: PasteKeyMonitoring {
  var onKey: (@MainActor (PasteStackKeyPress) -> Void)?
  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool { self.onKey = onKey; return true }
  func stop() { onKey = nil }
}

@MainActor
private struct Rig {
  let pasteboard = SharedPasteboard()
  let scheduler = Scheduler()
  let keys = Keys()
  let engine: PasteStackEngine

  init() {
    let writer = PasteStackPasteboardWriter(pasteboard: pasteboard, reader: pasteboard, schedule: scheduler.closure)
    engine = PasteStackEngine(writer: writer, keyMonitor: keys, schedule: scheduler.closure)
    engine.start(useKeyMonitor: true)
  }

  /// One ⌘V followed by the advance delay elapsing.
  func paste() {
    keys.onKey?(PasteStackKeyPress(keyCode: PasteStackKeyPress.vKeyCode, modifiers: .command, character: "v"))
    scheduler.run(delay: PasteStackEngine.defaultAdvanceDelay)
  }
}

private func image(_ bytes: [UInt8]) -> ClipboardEntry { ClipboardEntry(kind: .image, imagePNG: Data(bytes)) }

// MARK: Review R-M2: an image without a clean, completed scan stays concealed

@MainActor @Suite struct PasteStackUnscannedImageTests {
  @Test func failedScanKeepsTheHeadConcealed() {
    let r = Rig()
    let shot = image([1, 2])
    r.pasteboard.externalCopy(png: Data([1, 2]))
    r.engine.enqueue(shot, awaitingOCR: true)
    #expect(r.pasteboard.isConcealed)
    r.engine.applyOCR(entryID: shot.id, scanned: false, ocrText: nil, findings: [])  // timeout / Vision error
    #expect(r.pasteboard.png == Data([1, 2]))
    #expect(r.pasteboard.isConcealed)
  }

  @Test func imageSkippedByTheOCRBacklogIsConcealed() {
    let r = Rig()
    r.pasteboard.externalCopy(png: Data([3]))
    r.engine.enqueue(image([3]), awaitingOCR: false)  // no OCR update will ever come
    #expect(r.pasteboard.png == Data([3]))
    #expect(r.pasteboard.isConcealed)
  }

  @Test func cleanCompletedScanUnmarksTheHead() {
    let r = Rig()
    let shot = image([4])
    r.pasteboard.externalCopy(png: Data([4]))
    r.engine.enqueue(shot, awaitingOCR: true)
    r.engine.applyOCR(entryID: shot.id, scanned: true, ocrText: "hello", findings: [])
    #expect(r.pasteboard.png == Data([4]))
    #expect(!r.pasteboard.isConcealed)
  }

  @Test func failedScanBehindTheHeadIsConcealedWhenItBecomesTheHead() {
    let r = Rig()
    r.pasteboard.externalCopy("first")
    r.engine.enqueue(ClipboardEntry(kind: .text, text: "first"))
    let shot = image([5])
    r.pasteboard.externalCopy(png: Data([5]))
    r.engine.enqueue(shot, awaitingOCR: true)
    r.engine.applyOCR(entryID: shot.id, scanned: false, ocrText: nil, findings: [])
    #expect(r.pasteboard.text == "first")
    #expect(!r.pasteboard.isConcealed)
    r.paste()
    #expect(r.pasteboard.png == Data([5]))
    #expect(r.pasteboard.isConcealed)
  }

  @Test func lastUnscannedImageIsClearedSoonAfterItsPaste() {
    let r = Rig()
    r.pasteboard.externalCopy(png: Data([6]))
    r.engine.enqueue(image([6]))
    r.paste()
    #expect(!r.engine.isActive)
    #expect(r.pasteboard.isConcealed)
    r.scheduler.run(delay: PasteStackEngine.secretClearAfterPaste)
    #expect(r.pasteboard.png == nil)
  }

  @Test func onlyAwaitedEntriesCanBeMarkedScanned() {
    let r = Rig()
    let shot = image([7])
    r.pasteboard.externalCopy(png: Data([7]))
    r.engine.enqueue(shot, awaitingOCR: false)
    // A stray update for an image that was not waiting cannot unmark it.
    r.engine.applyOCR(entryID: shot.id, scanned: true, ocrText: nil, findings: [])
    #expect(r.pasteboard.isConcealed)
    #expect(r.engine.stack.peek?.ocrText == nil)
  }

  @Test func textIsUnaffected() {
    let r = Rig()
    r.pasteboard.externalCopy("plain")
    r.engine.enqueue(ClipboardEntry(kind: .text, text: "plain"))
    #expect(r.pasteboard.text == "plain")
    #expect(!r.pasteboard.isConcealed)
  }
}

// MARK: Review R-M3: the head never overwrites a newer image copy

@MainActor @Suite struct PasteStackCapturedChangeCountTests {
  /// B is delivered after the user already copied C (an image too): the content check cannot tell
  /// them apart, the generation can.
  @Test func newerImageCopyIsNotOverwrittenByAnEarlierImageDelivery() {
    let r = Rig()
    r.pasteboard.externalCopy("A")
    r.engine.enqueue(ClipboardEntry(kind: .text, text: "A"), capturedChangeCount: r.pasteboard.changeCount)
    #expect(r.pasteboard.text == "A")
    r.pasteboard.externalCopy(png: Data([0xB]))
    let capturedB = r.pasteboard.changeCount
    r.pasteboard.externalCopy(png: Data([0xC]))  // copied while B was being converted
    r.engine.enqueue(image([0xB]), capturedChangeCount: capturedB)
    #expect(r.pasteboard.png == Data([0xC]))  // C survives for the monitor to capture
    r.engine.enqueue(image([0xC]), capturedChangeCount: r.pasteboard.changeCount)
    #expect(r.pasteboard.text == "A")  // now the head goes back
    #expect(r.engine.count == 3)
  }

  @Test func headReplacesTheCopyItWasCapturedFrom() {
    let r = Rig()
    r.pasteboard.externalCopy(png: Data([1]))
    r.engine.enqueue(image([1]), capturedChangeCount: r.pasteboard.changeCount)
    #expect(r.pasteboard.png == Data([1]))
    #expect(r.pasteboard.isConcealed)  // written by the stack (unscanned image)
  }

  @Test func staleTextGenerationIsNotOverwrittenEvenWithEqualText() {
    let r = Rig()
    r.pasteboard.externalCopy("A")
    r.engine.enqueue(ClipboardEntry(kind: .text, text: "A"), capturedChangeCount: r.pasteboard.changeCount)
    r.pasteboard.externalCopy("B")
    let capturedB = r.pasteboard.changeCount
    r.pasteboard.externalCopy("B")  // copied again: same text, a newer copy
    r.engine.enqueue(ClipboardEntry(kind: .text, text: "B"), capturedChangeCount: capturedB)
    #expect(r.pasteboard.text == "B")
    #expect(r.pasteboard.changeCount == capturedB + 1)
  }

  @Test func withoutAGenerationTheContentCheckStillApplies() {
    let r = Rig()
    r.pasteboard.externalCopy("A")
    r.engine.enqueue(ClipboardEntry(kind: .text, text: "A"))
    r.pasteboard.externalCopy("B")
    r.pasteboard.externalCopy("C")
    r.engine.enqueue(ClipboardEntry(kind: .text, text: "B"))
    #expect(r.pasteboard.text == "C")
  }
}
