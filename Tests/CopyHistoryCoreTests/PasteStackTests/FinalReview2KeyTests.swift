import Foundation
import Testing
@testable import CopyHistoryCore

// Final review 2: FF-L4 (a key that never reads as released no longer holds the Paste Stack back
// forever) and FF-L5 (the real-layout ⌘V keycode test checks exact keycodes instead of a round trip
// through the same rule). Fake key state and a manual scheduler: no sleeps.

// MARK: - FF-L4

@MainActor
private final class NullWriter: PasteStackWriting {
  var changeCount = 0
  var written: [String?] = []
  func write(_ entry: ClipboardEntry, sensitive: Bool, clearAfter: TimeInterval) {
    changeCount += 1
    written.append(entry.text)
  }
  func holds(_ entry: ClipboardEntry) -> Bool { true }
}

@MainActor
private final class ManualScheduler {
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

/// Reports releases, and says every key in `held` is down.
@MainActor
private final class StuckKeyMonitor: PasteKeyMonitoring {
  var held: Set<UInt16> = []
  var reportsKeyUp: Bool { true }
  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool { true }
  func stop() {}
  func isKeyDown(_ keyCode: UInt16) -> Bool { held.contains(keyCode) }
}

@MainActor @Suite struct StuckCommandVTests {
  private let v = PasteStackKeyPress.vKeyCode
  private var timeout: TimeInterval { PasteStackEngine.keyUpTimeout }

  /// The key state stays "down" forever (e.g. a virtual keyboard never posted its key-up): the stack
  /// advances exactly once after `maxHeldKeyRounds` rounds, and a late release does nothing.
  @Test func aKeyThatNeverReleasesAdvancesOnceAtTheCap() {
    let writer = NullWriter(), scheduler = ManualScheduler(), monitor = StuckKeyMonitor()
    let engine = PasteStackEngine(writer: writer, keyMonitor: monitor, schedule: scheduler.closure)
    #expect(engine.start(useKeyMonitor: true) == .commandV)
    for text in ["A", "B", "C"] { engine.enqueue(ClipboardEntry(kind: .text, text: text)) }
    monitor.held = [v]
    engine.handle(PasteStackKeyPress(keyCode: v, modifiers: .command, character: "v"))

    for _ in 0..<PasteStackEngine.maxHeldKeyRounds {
      scheduler.run(delay: timeout)
      #expect(engine.count == 3)
    }
    scheduler.run(delay: timeout)  // the cap: advances although the key still reads as down
    #expect(engine.count == 2)
    #expect(writer.written.last == "B")
    #expect(scheduler.pending.filter { $0.delay == timeout }.isEmpty)  // the loop has ended

    engine.handle(PasteStackKeyPress(keyCode: v, modifiers: [], isKeyUp: true))  // late release
    #expect(scheduler.pending.isEmpty)
    #expect(engine.count == 2)
  }

  @Test func theCapIsWellAboveARealHold() {
    #expect(Double(PasteStackEngine.maxHeldKeyRounds) * PasteStackEngine.keyUpTimeout >= 10)
  }
}

// MARK: - FF-L5: real layouts, exact keycodes

@MainActor @Suite struct RealLayoutCommandVKeyCodeTests {
  private func layout(_ id: String) throws -> (UInt16) -> String? {
    let data = try #require(KeyboardLayoutCharacter.layoutData(inputSourceID: id))
    return { KeyboardLayoutCharacter.character(forKeyCode: $0, layout: data) }
  }

  @Test func exactKeycodes() throws {
    let us = try layout("com.apple.keylayout.US")
    let dvorak = try layout("com.apple.keylayout.Dvorak")
    let russian = try layout("com.apple.keylayout.Russian")
    #expect(KeyboardLayoutCharacter.commandVKeyCode(primary: us, asciiCapable: us) == 9)
    #expect(KeyboardLayoutCharacter.commandVKeyCode(primary: dvorak, asciiCapable: dvorak) == 47)
    #expect(KeyboardLayoutCharacter.commandVKeyCode(primary: russian, asciiCapable: dvorak) == 9)
  }

  /// Russian's ⌘ layer types Latin "v" on keycode 9, so the ASCII-capable fallback is never needed
  /// for it: the answer is the same without one. (A real layout whose ⌘ layer is non-Latin is not
  /// shipped with macOS; that path is covered with fake layouts in `ReviewRound2KeyTests`.)
  @Test func russianResolvesFromItsOwnCommandLayer() throws {
    let russian = try layout("com.apple.keylayout.Russian")
    #expect(russian(9) == "v")
    #expect(KeyboardLayoutCharacter.commandVKeyCode(primary: russian, asciiCapable: { _ in nil }) == 9)
  }
}
