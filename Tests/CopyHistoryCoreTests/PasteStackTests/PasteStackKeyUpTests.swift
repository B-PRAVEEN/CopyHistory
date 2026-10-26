import Foundation
import Testing
@testable import CopyHistoryCore

// Review R-L2: with a key monitor that reports releases, the stack advances `advanceDelay` after the
// ⌘V key-up (not the key-down), with a timeout for a lost key-up; double-taps still advance once.

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

@MainActor
private final class KeyUpMonitor: PasteKeyMonitoring {
  let reportsKeyUp: Bool
  init(reportsKeyUp: Bool = true) { self.reportsKeyUp = reportsKeyUp }
  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool { true }
  func stop() {}
}

private let v = PasteStackKeyPress.vKeyCode
private let down = PasteStackKeyPress(keyCode: v, modifiers: .command, character: "v")
private let up = PasteStackKeyPress(keyCode: v, modifiers: [], isKeyUp: true)
@MainActor private var delay: TimeInterval { PasteStackEngine.defaultAdvanceDelay }
@MainActor private var timeout: TimeInterval { PasteStackEngine.keyUpTimeout }

@MainActor
private func engine(reportsKeyUp: Bool = true) -> (PasteStackEngine, RecordingWriter, Scheduler) {
  let writer = RecordingWriter(), scheduler = Scheduler()
  let engine = PasteStackEngine(writer: writer, keyMonitor: KeyUpMonitor(reportsKeyUp: reportsKeyUp),
                                schedule: scheduler.closure)
  #expect(engine.start(useKeyMonitor: true) == .commandV)
  engine.enqueue(ClipboardEntry(kind: .text, text: "A"))
  engine.enqueue(ClipboardEntry(kind: .text, text: "B"))
  engine.enqueue(ClipboardEntry(kind: .text, text: "C"))
  return (engine, writer, scheduler)
}

@MainActor @Suite struct PasteStackKeyUpTests {
  @Test func defaultDelayIsAboutAQuarterSecond() {
    #expect(PasteStackEngine.defaultAdvanceDelay >= 0.25 && PasteStackEngine.defaultAdvanceDelay <= 0.3)
    #expect(PasteStackEngine.keyUpTimeout > PasteStackEngine.defaultAdvanceDelay)
  }

  @Test func advancesOnlyAfterTheKeyUpPlusTheDelay() {
    let (engine, writer, scheduler) = engine()
    engine.handle(down)
    #expect(scheduler.pending.map(\.delay) == [timeout])  // nothing at `advanceDelay` from the press
    scheduler.run(delay: delay)
    #expect(engine.count == 3)
    engine.handle(up)
    scheduler.run(delay: delay)
    #expect(engine.count == 2)
    #expect(writer.written.last == "B")
    scheduler.run(delay: timeout)  // the press's own timeout is stale now
    #expect(engine.count == 2)
  }

  @Test func doubleTapAdvancesOnce() {
    let (engine, _, scheduler) = engine()
    engine.handle(down); engine.handle(up)
    engine.handle(down); engine.handle(up)
    scheduler.run(delay: delay)
    scheduler.run(delay: timeout)
    #expect(engine.count == 2)
  }

  @Test func lostKeyUpAdvancesAfterTheTimeoutAndALateKeyUpDoesNothing() {
    let (engine, writer, scheduler) = engine()
    engine.handle(down)
    scheduler.run(delay: timeout)
    #expect(engine.count == 2)
    #expect(writer.written.last == "B")
    engine.handle(up)  // released after the timeout fired
    #expect(scheduler.pending.isEmpty)
    #expect(engine.count == 2)
  }

  @Test func otherReleasesAreIgnored() {
    let (engine, _, scheduler) = engine()
    engine.handle(PasteStackKeyPress(keyCode: 8, modifiers: [], isKeyUp: true))  // C, not the ⌘V key
    engine.handle(PasteStackKeyPress(keyCode: v, modifiers: [], fromOwnProcess: true, isKeyUp: true))
    #expect(scheduler.pending.isEmpty)
    engine.handle(down)
    engine.handle(PasteStackKeyPress(keyCode: 8, modifiers: [], isKeyUp: true))
    engine.handle(PasteStackKeyPress(keyCode: v, modifiers: [], fromOwnProcess: true, isKeyUp: true))
    #expect(scheduler.pending.map(\.delay) == [timeout])
    engine.handle(PasteStackKeyPress(keyCode: v, modifiers: .command, isKeyUp: true))  // ⌘ still held: fine
    #expect(scheduler.pending.map(\.delay) == [timeout, delay])
  }

  @Test func releaseIsNeverAPaste() {
    #expect(up.action == .ignore)
    #expect(PasteStackKeyPress(keyCode: v, modifiers: .command, character: "v", isKeyUp: true).action == .ignore)
  }

  /// A monitor that does not report releases keeps the key-down timing (with the longer delay).
  @Test func monitorWithoutReleasesAdvancesAfterTheKeyDown() {
    let (engine, _, scheduler) = engine(reportsKeyUp: false)
    engine.handle(down)
    #expect(scheduler.pending.map(\.delay) == [delay])
    scheduler.run(delay: delay)
    #expect(engine.count == 2)
  }

  @Test func cancelDropsAPendingKeyUp() {
    let (engine, _, scheduler) = engine()
    engine.handle(down)
    engine.cancel()
    #expect(engine.start(useKeyMonitor: true) == .commandV)
    engine.enqueue(ClipboardEntry(kind: .text, text: "X"))
    engine.enqueue(ClipboardEntry(kind: .text, text: "Y"))
    scheduler.pending = []
    engine.handle(up)  // the release of a press from the cancelled session
    #expect(scheduler.pending.isEmpty)
    #expect(engine.count == 2)
  }
}
