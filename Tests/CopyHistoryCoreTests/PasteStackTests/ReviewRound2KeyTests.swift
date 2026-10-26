import Foundation
import Testing
@testable import CopyHistoryCore

// Review round 2: F2-L3 (the posted ⌘V keycode is classified like the tap classifies it) and F2-L4
// (a ⌘V held past `keyUpTimeout` advances exactly once, after its release). Fake layouts, fake key
// state and a manual scheduler: no installed input sources and no sleeps.

// MARK: - F2-L3

/// A third-party layout whose ⌘ layer types native (non-ASCII) letters on every key.
private func cyrillic(_ keyCode: UInt16) -> String? { "м" }

/// The ASCII-capable layout AppKit falls back to: Dvorak (keycode 9 types "k", 47 types "v").
private func dvorak(_ keyCode: UInt16) -> String? {
  [9: "k", 47: "v", 40: "t"][keyCode] ?? "x"
}

/// What the Paste Stack's tap would see for a ⌘ press of `keyCode` with these layouts.
private func tapAction(keyCode: UInt16, primary: (UInt16) -> String?, ascii: (UInt16) -> String?,
                       fromOwnProcess: Bool = true) -> PasteStackKeyPress.Action {
  let character = KeyboardLayoutCharacter.commandCharacter(primary: primary(keyCode), asciiCapable: { ascii(keyCode) })
  return PasteStackKeyPress(keyCode: keyCode, modifiers: .command, character: character,
                            fromOwnProcess: fromOwnProcess).action
}

@Suite struct CommandVKeyCodeClassificationTests {
  /// Cyrillic primary with Dvorak as the ASCII-capable layout: keycode 9 would be ⌘K for the target
  /// app and for the tap, so the key Dvorak types "v" with is posted instead.
  @Test func nonLatinPrimaryUsesTheASCIICapableLayoutsKey() throws {
    let code = try #require(KeyboardLayoutCharacter.commandVKeyCode(primary: cyrillic, asciiCapable: dvorak))
    #expect(code == 47)
    #expect(tapAction(keyCode: code, primary: cyrillic, ascii: dvorak) == .ownPaste)
    #expect(tapAction(keyCode: 9, primary: cyrillic, ascii: dvorak) == .ignore)  // what used to be posted
  }

  /// The primary layout's ASCII character wins on a key, as in `commandCharacter`: a key that types
  /// "." in the primary layout is not ⌘V even if the ASCII-capable layout types "v" there.
  @Test func primaryASCIICharacterWinsPerKey() throws {
    let primary: (UInt16) -> String? = { [47: ".", 20: "v"][$0] ?? "м" }
    let code = try #require(KeyboardLayoutCharacter.commandVKeyCode(primary: primary, asciiCapable: dvorak))
    #expect(code == 20)
    #expect(tapAction(keyCode: code, primary: primary, ascii: dvorak) == .ownPaste)
    #expect(tapAction(keyCode: 47, primary: primary, ascii: dvorak) == .ignore)
  }

  @Test func keycode9IsKeptWhenItTypesV() {
    let qwerty: (UInt16) -> String? = { $0 == 9 ? "v" : "q" }
    #expect(KeyboardLayoutCharacter.commandVKeyCode(primary: qwerty, asciiCapable: dvorak) == 9)
    // A Latin key under ⌘ in the primary layout (e.g. Russian): no fallback needed.
    #expect(KeyboardLayoutCharacter.commandVKeyCode(primary: qwerty, asciiCapable: { _ in nil }) == 9)
  }

  /// No key types "v" anywhere: nil, and the caller posts keycode 9, which the tap counts as ⌘V when
  /// it knows no ASCII character for it.
  @Test func noVAnywhereFallsBackToKeycode9() {
    #expect(KeyboardLayoutCharacter.commandVKeyCode(primary: cyrillic, asciiCapable: { _ in nil }) == nil)
    #expect(tapAction(keyCode: 9, primary: cyrillic, ascii: { _ in nil }) == .ownPaste)
  }

  /// Every keycode the search can return is one the tap classifies as ⌘V, for real installed layouts.
  @MainActor @Test func realLayoutsRoundTrip() throws {
    for (primaryID, asciiID) in [("com.apple.keylayout.US", "com.apple.keylayout.US"),
                                 ("com.apple.keylayout.Dvorak", "com.apple.keylayout.Dvorak"),
                                 ("com.apple.keylayout.Russian", "com.apple.keylayout.Dvorak")] {
      let p = try #require(KeyboardLayoutCharacter.layoutData(inputSourceID: primaryID))
      let a = try #require(KeyboardLayoutCharacter.layoutData(inputSourceID: asciiID))
      let primary: (UInt16) -> String? = { KeyboardLayoutCharacter.character(forKeyCode: $0, layout: p) }
      let ascii: (UInt16) -> String? = { KeyboardLayoutCharacter.character(forKeyCode: $0, layout: a) }
      let code = try #require(KeyboardLayoutCharacter.commandVKeyCode(primary: primary, asciiCapable: ascii))
      #expect(tapAction(keyCode: code, primary: primary, ascii: ascii) == .ownPaste, "\(primaryID)")
    }
  }
}

// MARK: - F2-L4

@MainActor
private final class RecordingWriter: PasteStackWriting {
  var changeCount = 0
  var written: [String?] = []
  func write(_ entry: ClipboardEntry, sensitive: Bool, clearAfter: TimeInterval) {
    changeCount += 1
    written.append(entry.text)
  }
  func holds(_ entry: ClipboardEntry) -> Bool { true }
}

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

/// Reports releases, and says whether a key is down from `held`.
@MainActor
private final class HeldKeyMonitor: PasteKeyMonitoring {
  var held: Set<UInt16> = []
  var reportsKeyUp: Bool { true }
  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool { true }
  func stop() {}
  func isKeyDown(_ keyCode: UInt16) -> Bool { held.contains(keyCode) }
}

private let v = PasteStackKeyPress.vKeyCode
private let down = PasteStackKeyPress(keyCode: v, modifiers: .command, character: "v")
private let up = PasteStackKeyPress(keyCode: v, modifiers: [], isKeyUp: true)

@MainActor @Suite struct HeldCommandVTests {
  private var delay: TimeInterval { PasteStackEngine.defaultAdvanceDelay }
  private var timeout: TimeInterval { PasteStackEngine.keyUpTimeout }

  private func engine() -> (PasteStackEngine, RecordingWriter, Scheduler, HeldKeyMonitor) {
    let writer = RecordingWriter(), scheduler = Scheduler(), monitor = HeldKeyMonitor()
    let engine = PasteStackEngine(writer: writer, keyMonitor: monitor, schedule: scheduler.closure)
    #expect(engine.start(useKeyMonitor: true) == .commandV)
    for text in ["A", "B", "C"] { engine.enqueue(ClipboardEntry(kind: .text, text: text)) }
    return (engine, writer, scheduler, monitor)
  }

  @Test func heldPastTheTimeoutAdvancesOnceAfterTheRelease() {
    let (engine, writer, scheduler, monitor) = engine()
    monitor.held = [v]
    engine.handle(down)
    for _ in 0..<5 {  // the timeout comes round while the key is still down: no advance
      scheduler.run(delay: timeout)
      #expect(engine.count == 3)
      #expect(scheduler.pending.map(\.delay) == [timeout])
    }
    monitor.held = []
    engine.handle(up)
    scheduler.run(delay: delay)
    #expect(engine.count == 2)
    #expect(writer.written.last == "B")
    scheduler.run(delay: timeout)  // the rescheduled timeout is stale after the release
    #expect(engine.count == 2)
    #expect(scheduler.pending.isEmpty)
  }

  /// Released but the key-up was lost (e.g. the tap was disabled): the next timeout round sees the
  /// key up and advances, once.
  @Test func lostReleaseOfAHeldKeyAdvancesOnce() {
    let (engine, _, scheduler, monitor) = engine()
    monitor.held = [v]
    engine.handle(down)
    scheduler.run(delay: timeout)
    #expect(engine.count == 3)
    monitor.held = []  // no key-up reported
    scheduler.run(delay: timeout)
    #expect(engine.count == 2)
    #expect(scheduler.pending.isEmpty)
    engine.handle(up)  // a late release does nothing
    #expect(scheduler.pending.isEmpty)
    #expect(engine.count == 2)
  }

  /// Only the awaited key counts as held.
  @Test func anotherHeldKeyDoesNotDelayTheTimeout() {
    let (engine, _, scheduler, monitor) = engine()
    monitor.held = [8]
    engine.handle(down)
    scheduler.run(delay: timeout)
    #expect(engine.count == 2)
  }

  /// Monitors that cannot read key state keep the old behaviour (advance at the timeout).
  @Test func defaultMonitorNeverReportsAKeyDown() {
    final class Plain: PasteKeyMonitoring {
      func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool { true }
      func stop() {}
    }
    #expect(!Plain().isKeyDown(v))
  }
}
