import Foundation
import Testing
@testable import CopyHistoryCore

/// `TransformRegistry.all` is lock-guarded (no `nonisolated(unsafe)` static): concurrent registration
/// and reads stay consistent, and registration stays idempotent.
@Suite struct TransformRegistryConcurrencyTests {
  @Test func concurrentRegistrationAndReadsStayConsistent() async {
    let ids = TransformRegistry.defaultTransforms.map(\.id)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<64 {
        group.addTask { TransformRegistry.registerDefaults() }
        group.addTask { _ = TransformRegistry.all.count }
      }
    }
    let registered = TransformRegistry.all.map(\.id)
    for id in ids { #expect(registered.filter { $0 == id }.count == 1, Comment(rawValue: id)) }
  }

  @Test func updateIsOneReadModifyWrite() {
    TransformRegistry.registerDefaults()
    var seen = 0
    TransformRegistry.update { seen = $0.count }
    #expect(seen == TransformRegistry.all.count)
  }
}

/// (a) The transform runner's timeout is a cancellable work item, cancelled once the run is over.
@Suite struct TransformRunTimerTests {
  @Test func timeoutTimerIsCancelledWhenTheRunEnds() async throws {
    let once = TransformRunOnce()
    let timer = DispatchWorkItem {}
    let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
      #expect(once.install(c))
      once.setTimer(timer)
      once.resume(.success("done"))
    }
    #expect(result == "done")
    #expect(timer.isCancelled)
    let late = DispatchWorkItem {}
    once.setTimer(late)
    #expect(late.isCancelled)
  }

  @Test func runsStillTimeOut() async {
    struct Slow: Transform {
      var id: String { "slow" }
      var title: String { "Slow" }
      func canApply(to text: String) -> Bool { true }
      func apply(to text: String) throws -> String {
        while !TransformRunner.isCancelled { usleep(1000) }
        throw CancellationError()
      }
    }
    await #expect(throws: TransformError.timedOut) {
      try await TransformRunner.run(Slow(), on: "x", timeout: 0.05, limiter: .init(maxConcurrent: 1))
    }
  }
}
