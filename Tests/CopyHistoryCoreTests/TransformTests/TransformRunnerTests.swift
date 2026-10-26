import Testing
import Foundation
@testable import CopyHistoryCore

private struct SlowTransform: Transform {
  let id = "slow"
  let title = "Slow"
  let delay: TimeInterval
  func canApply(to text: String) -> Bool { true }
  func apply(to text: String) throws -> String {
    Thread.sleep(forTimeInterval: delay)
    return text.uppercased()
  }
}

/// Spins until the runner marks its thread cancelled, like a long transform loop polling the flag.
private final class CooperativeTransform: Transform, @unchecked Sendable {
  let id = "cooperative"
  let title = "Cooperative"
  private let lock = NSLock()
  private var _exited = false
  var exited: Bool { lock.lock(); defer { lock.unlock() }; return _exited }
  func canApply(to text: String) -> Bool { true }
  func apply(to text: String) throws -> String {
    let deadline = Date().addingTimeInterval(30)
    while !TransformRunner.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    lock.lock(); _exited = true; lock.unlock()
    return text
  }
}

private struct FailingTransform: Transform {
  let id = "failing"
  let title = "Failing"
  func canApply(to text: String) -> Bool { true }
  func apply(to text: String) throws -> String { throw TransformError.noContent }
}

private func elapsed(since start: UInt64) -> Double {
  Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

/// Every test passes its own `Limiter`: tests run in parallel, and sharing `.shared` would make them
/// (and other suites that use the real runner) fail with `.busy` at random.
@Suite struct TransformRunnerTests {
  @Test func returnsResult() async throws {
    #expect(try await TransformRunner.run(SlowTransform(delay: 0), on: "abc", limiter: .init(maxConcurrent: 1)) == "ABC")
  }

  @Test func propagatesTransformErrors() async {
    await #expect(throws: TransformError.noContent) { try await TransformRunner.run(FailingTransform(), on: "x", limiter: .init(maxConcurrent: 1)) }
  }

  @Test func timesOutWithoutWaitingForTheWork() async {
    let start = DispatchTime.now().uptimeNanoseconds
    await #expect(throws: TransformError.timedOut) {
      try await TransformRunner.run(SlowTransform(delay: 10), on: "x", timeout: 0.2, limiter: .init(maxConcurrent: 1))
    }
    #expect(elapsed(since: start) < 5)
  }

  @Test func cancellationReturnsPromptly() async {
    let start = DispatchTime.now().uptimeNanoseconds
    let task = Task { try await TransformRunner.run(SlowTransform(delay: 10), on: "x", timeout: 60, limiter: .init(maxConcurrent: 1)) }
    try? await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(elapsed(since: start) < 5)
  }

  @Test func alreadyCancelledTaskDoesNotRun() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await TransformRunner.run(SlowTransform(delay: 10), on: "x", timeout: 60, limiter: .init(maxConcurrent: 1))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func adversarialHTMLFinishesWithinBudget() async throws {
    // Took tens of seconds before the tokenizer fix, so it would have thrown `timedOut`.
    let out = try await TransformRunner.run(HTMLToMarkdown(), on: "<b>x</b>" + String(repeating: "<a x=1 ", count: 20_000),
                                         limiter: .init(maxConcurrent: 1))
    #expect(out.hasPrefix("**x**\\<a x=1"))
  }

  /// Abandoned runs keep their thread busy; retrying must not stack up unbounded threads.
  @Test func abandonedRunsBoundConcurrentThreads() async throws {
    let limiter = TransformRunner.Limiter(maxConcurrent: 2)
    for _ in 0..<2 {
      await #expect(throws: TransformError.timedOut) {
        try await TransformRunner.run(SlowTransform(delay: 1), on: "x", timeout: 0.05, limiter: limiter)
      }
    }
    #expect(limiter.liveCount == 2)
    await #expect(throws: TransformRunnerError.busy) {
      try await TransformRunner.run(SlowTransform(delay: 0), on: "x", limiter: limiter)
    }
    #expect(limiter.liveCount == 2)
    // Once the abandoned threads really finish, their slots are free again.
    for _ in 0..<100 where limiter.liveCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(limiter.liveCount == 0)
    #expect(try await TransformRunner.run(SlowTransform(delay: 0), on: "abc", limiter: limiter) == "ABC")
  }

  @Test func timedOutThreadIsMarkedCancelledSoCooperativeTransformsStop() async throws {
    let limiter = TransformRunner.Limiter(maxConcurrent: 1)
    let t = CooperativeTransform()
    await #expect(throws: TransformError.timedOut) {
      try await TransformRunner.run(t, on: "x", timeout: 0.1, limiter: limiter)
    }
    for _ in 0..<100 where !t.exited || limiter.liveCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(t.exited)
    #expect(limiter.liveCount == 0)
  }

  @Test func sharedLimiterIsBounded() {
    #expect(TransformRunner.maxConcurrentRuns == 2)
  }
}
