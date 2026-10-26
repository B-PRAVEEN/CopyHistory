import Foundation
import Testing
@testable import CopyHistoryCore

// Final review 2, FF-L5: `RunningScanCancellationTests` cannot prove that cancelling reaches the
// running Vision request (Vision ignores a cancel before `perform` starts). These check the wiring
// it relies on directly: the cancel closure a strip installs is called by a timeout or a task
// cancellation, exactly once, and never after the scan has its result. No Vision, no timing.

private final class Calls: @unchecked Sendable {
  private let lock = NSLock()
  private var _n = 0
  var n: Int { lock.lock(); defer { lock.unlock() }; return _n }
  func hit() { lock.lock(); _n += 1; lock.unlock() }
}

@Suite struct ResumeOnceCancelWiringTests {
  @Test func timeOutCallsTheInstalledCancelOnceAndFails() async {
    let once = ResumeOnce()
    let calls = Calls()
    let result = await withCheckedContinuation { (c: CheckedContinuation<OCRScanResult, Never>) in
      #expect(once.set(c))
      #expect(once.install(cancel: { calls.hit() }))
      once.timeOut()
      once.timeOut()  // a second timeout (e.g. the timer after a task cancel) does nothing more
    }
    #expect(result == .failed)
    #expect(calls.n == 1)
    #expect(once.isDone)
    #expect(!once.install(cancel: { calls.hit() }))  // a later strip is never started
  }

  @Test func noCancelAfterTheResult() async {
    let once = ResumeOnce()
    let calls = Calls()
    let result = await withCheckedContinuation { (c: CheckedContinuation<OCRScanResult, Never>) in
      #expect(once.set(c))
      #expect(once.install(cancel: { calls.hit() }))
      once.resume(.noText)
      once.timeOut()
    }
    #expect(result == .noText)
    #expect(calls.n == 0)
  }

  /// The latest strip's request is the one cancelled.
  @Test func cancelsTheLatestInstalledRequest() async {
    let once = ResumeOnce()
    let first = Calls(), second = Calls()
    _ = await withCheckedContinuation { (c: CheckedContinuation<OCRScanResult, Never>) in
      _ = once.set(c)
      _ = once.install(cancel: { first.hit() })
      _ = once.install(cancel: { second.hit() })
      once.timeOut()
    }
    #expect(first.n == 0)
    #expect(second.n == 1)
  }
}
