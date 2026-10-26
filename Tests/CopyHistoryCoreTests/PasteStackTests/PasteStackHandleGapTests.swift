import Foundation
import Testing
@testable import CopyHistoryCore

// Covers what `PasteStackTests` leaves out: the ⌃ modifier, `PasteStackEngine.handle` called directly
// (the fallback-mode test there never reaches it, its fake monitor delivers nothing), and a writer
// that relies on the `PasteStackWriting.holds` default.

/// A pasteboard writer with no read side: uses the protocol's default `holds` (always false).
@MainActor
private final class BlindWriter: PasteStackWriting {
  var changeCount = 0
  var writes: [(text: String?, sensitive: Bool)] = []
  func write(_ entry: ClipboardEntry, sensitive: Bool, clearAfter: TimeInterval) {
    changeCount += 1
    writes.append((entry.text, sensitive))
  }
  /// Another app (or the popup) writes to the pasteboard.
  func externalWrite() { changeCount += 1 }
}

/// Like `BlindWriter`, but it sees every copy the monitor delivers as still on the pasteboard.
@MainActor
private final class SeeingWriter: PasteStackWriting {
  var changeCount = 0
  var lastWritten: String?
  func write(_ entry: ClipboardEntry, sensitive: Bool, clearAfter: TimeInterval) {
    changeCount += 1
    lastWritten = entry.text
  }
  func holds(_ entry: ClipboardEntry) -> Bool { true }
  func externalWrite() { changeCount += 1 }
}

@MainActor
private final class Scheduled {
  var pending: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
  var closure: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void {
    { [unowned self] delay, work in self.pending.append((delay, work)) }
  }
  func runAll() {
    let due = pending
    pending = []
    due.forEach { $0.work() }
  }
}

@MainActor
private final class AlwaysOnMonitor: PasteKeyMonitoring {
  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool { true }
  func stop() {}
}

private let cmdV = PasteStackKeyPress(keyCode: PasteStackKeyPress.vKeyCode, modifiers: .command, character: "v")
private let ownCmdV = PasteStackKeyPress(keyCode: PasteStackKeyPress.vKeyCode, modifiers: .command, character: "v",
                                         fromOwnProcess: true)
private func text(_ s: String) -> ClipboardEntry { ClipboardEntry(kind: .text, text: s) }

@Suite struct PasteStackModifierTests {
  @Test func controlIsNotPlainCommandV() {
    let v = PasteStackKeyPress.vKeyCode
    #expect(PasteStackKeyPress(keyCode: v, modifiers: [.command, .control], character: "v").action == .ignore)
    #expect(PasteStackKeyPress(keyCode: v, modifiers: .control, character: "v").action == .ignore)
    #expect(PasteStackKeyPress(keyCode: v, modifiers: [.command, .shift, .option, .control]).action == .ignore)
    // Own-process presses are classified by the same modifier rule.
    #expect(PasteStackKeyPress(keyCode: v, modifiers: [.command, .control], fromOwnProcess: true).action == .ignore)
    #expect(PasteStackKeyPress(keyCode: v, modifiers: .command, isAutorepeat: true, fromOwnProcess: true).action
            == .ignore)
  }

  @Test func modifierBitsAreDistinct() {
    let all: [PasteStackKeyPress.Modifiers] = [.command, .shift, .option, .control]
    #expect(Set(all.map(\.rawValue)).count == 4)
    #expect(all.allSatisfy { $0.rawValue.nonzeroBitCount == 1 })
    let combined: PasteStackKeyPress.Modifiers = [.command, .control]
    #expect(combined.contains(.command) && combined.contains(.control) && !combined.contains(.shift))
    #expect(combined != .command)
  }
}

@MainActor @Suite struct PasteStackEngineHandleTests {
  @Test func handleIsIgnoredWhileInactive() {
    let writer = BlindWriter(), scheduler = Scheduled()
    let engine = PasteStackEngine(writer: writer, keyMonitor: AlwaysOnMonitor(), schedule: scheduler.closure)
    engine.handle(cmdV)
    engine.handle(ownCmdV)
    #expect(scheduler.pending.isEmpty)
    #expect(writer.changeCount == 0)
  }

  @Test func commandVDoesNothingInFallbackMode() {
    let writer = SeeingWriter(), scheduler = Scheduled()
    let engine = PasteStackEngine(writer: writer, keyMonitor: AlwaysOnMonitor(), schedule: scheduler.closure)
    #expect(engine.start(useKeyMonitor: false) == .fallbackHotKey)
    engine.enqueue(text("a"))
    engine.enqueue(text("b"))
    engine.handle(cmdV)
    #expect(scheduler.pending.isEmpty)
    #expect(engine.count == 2)
    #expect(writer.lastWritten == "a")
  }

  @Test func commandVSchedulesTheAdvanceWithTheConfiguredDelay() {
    let writer = SeeingWriter(), scheduler = Scheduled()
    let engine = PasteStackEngine(writer: writer, keyMonitor: AlwaysOnMonitor(), advanceDelay: 0.3,
                                  schedule: scheduler.closure)
    #expect(engine.start(useKeyMonitor: true) == .commandV)
    engine.enqueue(text("a"))
    engine.enqueue(text("b"))
    engine.handle(cmdV)
    #expect(scheduler.pending.map(\.delay) == [0.3])
    #expect(engine.count == 2)  // nothing happens before the delay
    scheduler.runAll()
    #expect(engine.count == 1)
    #expect(writer.lastWritten == "b")
  }

  @Test func ignoredKeySchedulesNothing() {
    let writer = SeeingWriter(), scheduler = Scheduled()
    let engine = PasteStackEngine(writer: writer, keyMonitor: AlwaysOnMonitor(), schedule: scheduler.closure)
    engine.start(useKeyMonitor: true)
    engine.enqueue(text("a"))
    engine.handle(PasteStackKeyPress(keyCode: 8, modifiers: .command))  // ⌘C
    #expect(scheduler.pending.isEmpty)
  }

  /// The popup's own paste is not tied to ⌘V mode: in fallback mode the head still comes back.
  @Test func ownPasteRestoresTheHeadInFallbackMode() {
    let writer = SeeingWriter(), scheduler = Scheduled()
    let engine = PasteStackEngine(writer: writer, keyMonitor: nil, schedule: scheduler.closure)
    engine.start(useKeyMonitor: true)
    engine.enqueue(text("a"))
    writer.externalWrite()  // the popup writes its item
    writer.lastWritten = nil
    engine.handle(ownCmdV)
    scheduler.runAll()
    #expect(writer.lastWritten == "a")
    #expect(engine.count == 1)
  }

  /// A writer that cannot read the pasteboard never puts the head over a copy (default `holds`).
  @Test func blindWriterNeverOverwritesACopy() {
    let writer = BlindWriter(), scheduler = Scheduled()
    let engine = PasteStackEngine(writer: writer, keyMonitor: AlwaysOnMonitor(), schedule: scheduler.closure)
    engine.start(useKeyMonitor: true)
    #expect(engine.enqueue(text("a")))
    #expect(engine.enqueue(text("b")))
    #expect(writer.writes.isEmpty)
    // ⌘V pasted the user's copy, not the head: nothing is popped.
    engine.handle(cmdV)
    scheduler.runAll()
    #expect(engine.count == 2)
    // Once a monitor poll has seen the pasted copy, the head is written.
    scheduler.runAll()
    #expect(writer.writes.map(\.text) == ["a"])
  }
}
