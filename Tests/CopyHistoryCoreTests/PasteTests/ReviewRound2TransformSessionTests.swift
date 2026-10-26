import Foundation
import Testing
@testable import CopyHistoryCore

// Review round 2, F2-L6: the transform-session tests that asserted "nothing was delivered" after a
// fixed sleep (vacuous on a slow machine) are restated with awaited signals: the runner is held at
// a gate, released after the cancel, and the test awaits the run's task to its very end before
// checking. The second-run refusal also checks that the first run is unaffected.

private struct EchoTransform: Transform {
  let id = "echo"
  let title = "Echo"
  func canApply(to text: String) -> Bool { true }
  func apply(to text: String) throws -> String { text }
}

/// Holds every run until `open()`; then each returns its input, as an uninterruptible transform would.
private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      lock.lock()
      if isOpen { lock.unlock(); c.resume(); return }
      waiters.append(c)
      lock.unlock()
    }
  }

  func open() {
    lock.lock(); isOpen = true; let w = waiters; waiters = []; lock.unlock()
    w.forEach { $0.resume() }
  }

  var runner: TransformSession.Runner {
    { [self] _, text in
      await self.wait()
      return "out:\(text)"
    }
  }
}

@MainActor @Suite struct AwaitedTransformSessionTests {
  @Test(.timeLimit(.minutes(1))) func cancelledRunNeverDelivers() async {
    let gate = Gate()
    let session = TransformSession(runner: gate.runner)
    var delivered = 0
    #expect(session.start(EchoTransform(), on: ClipboardEntry(kind: .text, text: "abc")) { _ in delivered += 1 })
    let run = session.currentRun
    session.cancel()
    #expect(!session.isRunning)
    gate.open()
    if let run { await run.value }  // the run's result came back and was dropped
    #expect(run != nil)
    #expect(delivered == 0)
  }

  @Test(.timeLimit(.minutes(1))) func cancelledRunDoesNotDeliverIntoTheNextRun() async {
    let gate = Gate()
    let session = TransformSession(runner: gate.runner)
    var delivered: [(UUID, String?)] = []
    let first = ClipboardEntry(kind: .text, text: "first")
    let second = ClipboardEntry(kind: .text, text: "second")
    session.start(EchoTransform(), on: first) { delivered.append(($0.entryID, try? $0.result.get())) }
    let firstRun = session.currentRun
    session.cancel()
    #expect(session.start(EchoTransform(), on: second) { delivered.append(($0.entryID, try? $0.result.get())) })
    let secondRun = session.currentRun
    gate.open()
    if let firstRun { await firstRun.value }
    if let secondRun { await secondRun.value }
    #expect(delivered.map(\.0) == [second.id])
    #expect(delivered.first?.1 == "out:second")
  }

  @Test(.timeLimit(.minutes(1))) func secondStartIsRefusedAndTheFirstRunStillDelivers() async {
    let gate = Gate()
    let session = TransformSession(runner: gate.runner)
    var delivered: [UUID] = []
    let entry = ClipboardEntry(kind: .text, text: "abc")
    let other = ClipboardEntry(kind: .text, text: "other")
    #expect(session.start(EchoTransform(), on: entry) { delivered.append($0.entryID) })
    let run = session.currentRun
    #expect(!session.start(EchoTransform(), on: other) { delivered.append($0.entryID) })
    #expect(session.isRunning)  // the refusal did not cancel the first run
    #expect(session.currentRun == run)
    gate.open()
    if let run { await run.value }
    #expect(delivered == [entry.id])
    #expect(!session.isRunning)
  }
}
