import Foundation

/// Listen-only source of key presses (a `CGEventTap` in the app, a fake in tests).
@MainActor
public protocol PasteKeyMonitoring: AnyObject {
  /// Starts delivering key presses on the main actor. Returns false when monitoring is unavailable
  /// (Input Monitoring denied, tap creation failed); the stack then advances via the fallback hotkey.
  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool
  func stop()
  /// Whether the release of each reported ⌘V is delivered too (`PasteStackKeyPress.isKeyUp`). Then
  /// the stack advances `advanceDelay` after the key-up rather than after the key-down.
  var reportsKeyUp: Bool { get }
  /// Whether `keyCode` is held down right now. A ⌘V held past `PasteStackEngine.keyUpTimeout`
  /// keeps the advance waiting for its release instead of advancing under the user's finger.
  func isKeyDown(_ keyCode: UInt16) -> Bool
}

extension PasteKeyMonitoring {
  public var reportsKeyUp: Bool { false }
  public func isKeyDown(_ keyCode: UInt16) -> Bool { false }
}

/// Puts stack entries on the pasteboard.
@MainActor
public protocol PasteStackWriting: AnyObject {
  /// Pasteboard generation; compared with the value right after our last write to tell whether
  /// anyone (the user, another app, the popup) replaced the head since.
  var changeCount: Int { get }
  /// `sensitive` entries are marked Concealed/Transient, kept current-host-only and cleared after
  /// `clearAfter` if still on the pasteboard.
  func write(_ entry: ClipboardEntry, sensitive: Bool, clearAfter: TimeInterval)
  /// Whether the pasteboard holds the copy `entry` was captured from (and nothing newer). The stack
  /// only puts its head over a copy it has queued, so a newer copy that the clipboard monitor has
  /// not picked up yet is never overwritten.
  func holds(_ entry: ClipboardEntry) -> Bool
}

extension PasteStackWriting {
  /// Conformers that cannot read the pasteboard never overwrite a user copy.
  public func holds(_ entry: ClipboardEntry) -> Bool { false }
}

/// Writes through `SecretPasteboardWriter`: every write carries the internal marker (so the clipboard
/// monitor ignores it), and flagged entries are Concealed/Transient, current-host-only and cleared
/// after `clearAfter`. The engine decides sensitivity; text is not rescanned here: stack entries come
/// from the clipboard monitor, which already scanned them, and rescanning up to 512 KB would block
/// the main thread.
@MainActor
public final class PasteStackPasteboardWriter: PasteStackWriting {
  private let pasteboard: PasteboardWriting
  private let reader: PasteboardReading
  private let writer: SecretPasteboardWriter

  /// `reader` must see the same pasteboard as `pasteboard`.
  public init(pasteboard: PasteboardWriting = SystemPasteboardWriter(),
              reader: PasteboardReading = SystemPasteboard(),
              detector: SecretDetecting = SecretDetector(),
              schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
                Task { @MainActor in
                  try? await Task.sleep(for: .seconds(delay))
                  work()
                }
              }) {
    self.pasteboard = pasteboard
    self.reader = reader
    writer = SecretPasteboardWriter(pasteboard: pasteboard, detector: detector, schedule: schedule)
  }

  public var changeCount: Int { pasteboard.changeCount }

  public func write(_ entry: ClipboardEntry, sensitive: Bool, clearAfter: TimeInterval) {
    switch entry.kind {
    case .text:
      guard let text = entry.text else { return }
      writer.write(text: text, sensitive: sensitive, clearAfter: clearAfter)
    case .image:
      guard let png = entry.imagePNG else { return }
      writer.write(png: png, sensitive: sensitive, clearAfter: clearAfter)
    }
  }

  /// Text: the same string. Image: no text and image data present (the PNG was converted, so bytes
  /// cannot be compared; two images copied within one monitor poll are indistinguishable).
  public func holds(_ entry: ClipboardEntry) -> Bool {
    let string = reader.string()
    switch entry.kind {
    case .text:
      return entry.text != nil && string == entry.text
    case .image:
      guard string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return false }
      return reader.types.contains { Self.imageTypes.contains($0) }
    }
  }

  private static let imageTypes: Set<String> = ["public.png", "public.tiff", "NSTIFFPboardType"]
}

/// The Paste Stack state machine, free of AppKit so it is unit-testable.
///
/// While active the pasteboard holds the queue head. ⌘V (seen by a listen-only key monitor) pastes
/// it; `advanceDelay` after the key is released (after the press, for a monitor that does not report
/// releases) — time for the target app to read the pasteboard — the head is popped and the next
/// entry written. Presses inside that window restart it, so a double-tap advances once. A release
/// that never arrives (e.g. the tap was disabled mid-press) advances after `keyUpTimeout`, unless the
/// key is still held then: a held ⌘V advances exactly once, after its release.
/// A target that reads the pasteboard later than that (a remote desktop, a stalled app) can still
/// get the next entry.
/// When the last entry has been pasted the mode ends (`.finished`); `cancel()` ends it early.
///
/// The head never replaces a copy the stack has not queued: a copy is on the pasteboard first, and
/// the stack writes its head over it only once the clipboard monitor has delivered that very copy
/// (its captured `changeCount` is still current, or else `PasteStackWriting.holds`). A newer copy still on its way therefore survives, joins the queue
/// when it arrives, and that enqueue puts the head back.
@MainActor
public final class PasteStackEngine {
  public enum AdvanceMode: Equatable, Sendable {
    case commandV        // the key monitor advances after each ⌘V
    case fallbackHotKey  // no key monitor: the app's fallback hotkey calls `advanceNow()`
  }

  public enum EndReason: Equatable, Sendable { case finished, cancelled }

  public enum Event: Equatable, Sendable {
    case started(AdvanceMode)
    case changed  // queue contents changed
    case ended(EndReason)
  }

  /// ~250 ms after the key-up: long enough for a busy target app to read the pasteboard after ⌘V.
  public static let defaultAdvanceDelay: TimeInterval = 0.25
  /// How long after a ⌘V press the stack advances anyway when its release is never reported.
  public static let keyUpTimeout: TimeInterval = 1
  /// A flagged head can wait on the pasteboard this long before it is cleared. After a clear the
  /// next ⌘V pastes nothing, and the stack re-writes the head instead of advancing.
  public static let secretHoldSeconds: TimeInterval = 120
  /// A flagged entry that was just pasted only needs to survive until the target app has read it.
  public static let secretClearAfterPaste: TimeInterval = 2
  /// After a cancel the user may still paste the flagged head by hand; matches the app's copy-only delay.
  public static let secretClearAfterCancel: TimeInterval = 30
  /// Longer than the clipboard monitor's poll interval (0.5 s): content on the pasteboard this long
  /// has been read by a poll, so writing over it loses nothing.
  public static let monitorSettleDelay: TimeInterval = 0.6

  public private(set) var stack: PasteStack
  public private(set) var advanceMode: AdvanceMode?
  /// Why the last `enqueue` returned false; nil after one that succeeded.
  public private(set) var lastRejection: PasteStack.Rejection?
  public var onEvent: (@MainActor (Event) -> Void)?

  public var isActive: Bool { stack.isActive }
  public var count: Int { stack.count }

  private let writer: PasteStackWriting
  private let keyMonitor: PasteKeyMonitoring?
  private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
  private let advanceDelay: TimeInterval
  private let now: () -> Date
  /// Bumped on every ⌘V and on start/stop; a scheduled advance runs only if it is still current.
  private var generation = 0
  /// Whether any ⌘V since the last advance found the head on the pasteboard, i.e. pasted it.
  private var pastedHeadSinceAdvance = false
  /// Keycode of the ⌘V press whose release the advance waits for.
  private var awaitingKeyUp: UInt16?
  /// `writer.changeCount` right after the last head write; nil when no head is on the pasteboard.
  private var headChangeCount: Int?
  /// Image entries whose OCR result has not arrived yet; only their results are accepted.
  private var awaitingOCR: Set<UUID> = []
  /// Image entries an OCR scan checked and found clean. Every other image is written as sensitive
  /// (fail closed): its scan is pending, failed, timed out or never ran (backlog full, OCR off), so
  /// it may show a secret nobody flagged.
  private var scannedImages: Set<UUID> = []

  public init(writer: PasteStackWriting,
              keyMonitor: PasteKeyMonitoring?,
              capacity: Int = PasteStack.defaultCapacity,
              maxBytes: Int = PasteStack.defaultMaxBytes,
              advanceDelay: TimeInterval = PasteStackEngine.defaultAdvanceDelay,
              now: @escaping () -> Date = Date.init,
              schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
                Task { @MainActor in
                  try? await Task.sleep(for: .seconds(delay))
                  work()
                }
              }) {
    self.writer = writer; self.keyMonitor = keyMonitor; self.schedule = schedule
    self.advanceDelay = advanceDelay; self.now = now
    stack = PasteStack(capacity: capacity, maxBytes: maxBytes)
  }

  /// Turns stack mode on with an empty queue. `useKeyMonitor` false (Input Monitoring denied) or a
  /// key monitor that fails to start selects `.fallbackHotKey`. Returns the mode in effect.
  @discardableResult
  public func start(useKeyMonitor: Bool) -> AdvanceMode {
    if let advanceMode, stack.isActive { return advanceMode }
    generation += 1
    headChangeCount = nil
    pastedHeadSinceAdvance = false
    awaitingKeyUp = nil
    lastRejection = nil
    awaitingOCR = []
    scannedImages = []
    stack.start()
    var mode = AdvanceMode.fallbackHotKey
    if useKeyMonitor, let keyMonitor,
       keyMonitor.start(onKey: { [weak self] key in self?.handle(key) }) {
      mode = .commandV
    }
    advanceMode = mode
    onEvent?(.started(mode))
    return mode
  }

  /// Ends stack mode early (the toggle hotkey again). A flagged head still on the pasteboard is
  /// re-written so it is cleared after `secretClearAfterCancel` rather than `secretHoldSeconds`.
  public func cancel() {
    if let head = stack.peek, isSensitive(head),
       let headChangeCount, writer.changeCount == headChangeCount {
      writer.write(head, sensitive: true, clearAfter: Self.secretClearAfterCancel)
    }
    end(.cancelled)
  }

  /// Appends a copy made while stack mode is on, then puts the head back on the pasteboard if it still
  /// holds this copy (a newer copy is left alone; its own enqueue restores the head). Returns false
  /// when stack mode is off or the queue is full (by count or bytes); `lastRejection` says why, and
  /// the head is put back over the rejected copy all the same.
  /// `awaitingOCR`: the clipboard monitor will deliver an OCR result for this entry later
  /// (see `applyOCR`). An image is treated as sensitive until a clean, completed scan arrives.
  /// `capturedChangeCount`: the pasteboard generation the entry was read from
  /// (`ClipboardMonitor.capturingChangeCount`). When given, the pasteboard holds this copy exactly
  /// when its generation is unchanged; otherwise `PasteStackWriting.holds` guesses from its content,
  /// which cannot tell two images apart.
  @discardableResult
  public func enqueue(_ entry: ClipboardEntry, awaitingOCR: Bool = false, capturedChangeCount: Int? = nil) -> Bool {
    guard stack.isActive else { lastRejection = .inactive; return false }
    let droppedExpired = dropExpiredSecrets()
    lastRejection = stack.rejection(for: entry)
    if lastRejection == nil {
      stack.enqueue(entry)
      if awaitingOCR { self.awaitingOCR.insert(entry.id) }
      scheduleExpiry(of: entry)
    }
    let holdsEntry = capturedChangeCount.map { writer.changeCount == $0 } ?? writer.holds(entry)
    if isHeadOnPasteboard || holdsEntry { writeHead() }
    if lastRejection == nil || droppedExpired { onEvent?(.changed) }
    return lastRejection == nil
  }

  /// Records the late OCR result for a queued image entry. If it is the head and still on the
  /// pasteboard, the head is re-written with its final sensitivity (flagged, or not `scanned`: still
  /// concealed; clean: unmarked, so it is no longer cleared from under the user).
  public func applyOCR(entryID: UUID, scanned: Bool, ocrText: String?, findings: [SecretFinding]) {
    guard stack.isActive, awaitingOCR.remove(entryID) != nil else { return }
    if scanned && findings.isEmpty { scannedImages.insert(entryID) }
    let found = stack.update(id: entryID) {
      $0.ocrText = ocrText
      $0.findings = findings
    }
    guard found else { return }
    if stack.peek?.id == entryID, let headChangeCount, writer.changeCount == headChangeCount { writeHead() }
    onEvent?(.changed)
  }

  /// Entry point for the key monitor.
  public func handle(_ key: PasteStackKeyPress) {
    guard stack.isActive else { return }
    if key.isKeyUp {
      guard advanceMode == .commandV, !key.fromOwnProcess, let pending = awaitingKeyUp,
            key.keyCode == pending else { return }
      awaitingKeyUp = nil
      generation += 1
      scheduleAdvance(after: advanceDelay)
      return
    }
    switch key.action {
    case .paste:
      guard advanceMode == .commandV else { return }
      // Decided now: by the time the advance runs the user may have copied something new.
      if isHeadOnPasteboard { pastedHeadSinceAdvance = true }
      generation += 1
      if keyMonitor?.reportsKeyUp == true {
        awaitingKeyUp = key.keyCode
        scheduleAdvance(after: Self.keyUpTimeout, unlessHeld: true)  // only if the release is lost
      } else {
        scheduleAdvance(after: advanceDelay)
      }
    case .ownPaste:
      // The popup wrote its item and pasted it. Once the target has read it, put the head back so the
      // next ⌘V pastes the stack again — unless the user copied meanwhile.
      let written = writer.changeCount
      schedule(advanceDelay) { [weak self] in
        guard let self, self.stack.isActive, self.writer.changeCount == written,
              written != self.headChangeCount else { return }
        self.writeHead()
      }
    case .ignore:
      break
    }
  }

  /// Runs the advance `delay` from now unless another ⌘V press or release comes first.
  /// `unlessHeld`: the key-up timeout; while the awaited key is still down it waits another round.
  private func scheduleAdvance(after delay: TimeInterval, unlessHeld: Bool = false) {
    let current = generation
    schedule(delay) { [weak self] in
      guard let self, current == self.generation else { return }
      if unlessHeld, let pending = self.awaitingKeyUp, self.keyMonitor?.isKeyDown(pending) == true {
        self.scheduleAdvance(after: delay, unlessHeld: true)
        return
      }
      let pastedHead = self.pastedHeadSinceAdvance
      self.pastedHeadSinceAdvance = false
      self.awaitingKeyUp = nil
      self.advance(pastedHead: pastedHead)
    }
  }

  /// Advances past the head, which the user has just pasted (the fallback hotkey). If the pasteboard
  /// no longer holds the head (someone copied or wrote since, or the secret clear ran), whatever was
  /// pasted was not the head: nothing is popped and the head is written again.
  public func advanceNow() {
    advance(pastedHead: isHeadOnPasteboard)
  }

  /// `pastedHead`: the paste being acted on read the head. If not, the head is written again once the
  /// clipboard monitor has had time to record what was pasted instead (see `restoreHeadLater`). If so, it is popped and the next head is
  /// written — unless the user copied since the paste: that copy stays until it is queued.
  private func advance(pastedHead: Bool) {
    guard stack.isActive, let head = stack.peek else { return }
    guard pastedHead else {
      if dropExpiredSecrets() { onEvent?(.changed) }
      restoreHeadLater()
      return
    }
    // Pop what was pasted before dropping expired entries, so an expired head that was just pasted
    // is not mistaken for the entry behind it.
    let headStillThere = isHeadOnPasteboard
    stack.popNext()
    defer { awaitingOCR.remove(head.id); scannedImages.remove(head.id) }
    dropExpiredSecrets()
    if stack.isEmpty {
      // Re-writing the pasted secret shortens its clear from `secretHoldSeconds` to a moment.
      if headStillThere, isSensitive(head) {
        writer.write(head, sensitive: true, clearAfter: Self.secretClearAfterPaste)
      }
      end(.finished)
    } else {
      if headStillThere { writeHead() } else { headChangeCount = nil }
      onEvent?(.changed)
    }
  }

  /// Puts the head back over whatever replaced it, once a clipboard monitor poll has certainly seen
  /// that content (recorded or deliberately skipped it), and only if nothing changed meanwhile. A copy
  /// the monitor delivers first is queued instead, and that enqueue restores the head.
  private func restoreHeadLater() {
    let seen = writer.changeCount
    guard seen != headChangeCount else { return }
    schedule(Self.monitorSettleDelay) { [weak self] in
      guard let self, self.stack.isActive, self.writer.changeCount == seen else { return }
      self.writeHead()
    }
  }

  private var isHeadOnPasteboard: Bool {
    guard let headChangeCount else { return false }
    return writer.changeCount == headChangeCount
  }

  private func writeHead() {
    guard let head = stack.peek else { return }
    writer.write(head, sensitive: isSensitive(head), clearAfter: Self.secretHoldSeconds)
    headChangeCount = writer.changeCount
  }

  /// Drops flagged entries whose redaction expiry has passed: the history already forgot them, so
  /// the stack must not keep (or paste) them either. Returns whether any went; callers decide
  /// whether the head on the pasteboard must change.
  @discardableResult
  private func dropExpiredSecrets() -> Bool {
    let current = now()
    let expired = Set(stack.items.filter { !$0.findings.isEmpty && ($0.expiresAt.map { $0 <= current } ?? false) }
      .map(\.id))
    guard !expired.isEmpty else { return false }
    stack.removeAll { expired.contains($0.id) }
    awaitingOCR.subtract(expired)
    scannedImages.subtract(expired)
    return true
  }

  /// At a flagged entry's expiry: drop it, and if it was the head on the pasteboard, replace it with
  /// the new head. (An expired head with nothing behind it stays until its `secretHoldSeconds` clear.)
  private func scheduleExpiry(of entry: ClipboardEntry) {
    guard !entry.findings.isEmpty, let expiresAt = entry.expiresAt else { return }
    schedule(max(0, expiresAt.timeIntervalSince(now()))) { [weak self] in
      guard let self, self.stack.isActive else { return }
      let headID = self.stack.peek?.id
      let headOnPasteboard = self.isHeadOnPasteboard
      guard self.dropExpiredSecrets() else { return }
      if headOnPasteboard, self.stack.peek?.id != headID {
        if self.stack.isEmpty { self.headChangeCount = nil } else { self.writeHead() }
      }
      self.onEvent?(.changed)
    }
  }

  private func isSensitive(_ entry: ClipboardEntry) -> Bool {
    !entry.findings.isEmpty || (entry.kind == .image && !scannedImages.contains(entry.id))
  }

  private func end(_ reason: EndReason) {
    guard stack.isActive else { return }
    generation += 1
    headChangeCount = nil
    awaitingKeyUp = nil
    awaitingOCR = []
    scannedImages = []
    stack.stop()
    if advanceMode == .commandV { keyMonitor?.stop() }
    advanceMode = nil
    onEvent?(.ended(reason))
  }
}
