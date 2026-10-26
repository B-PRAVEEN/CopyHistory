import Foundation
import Testing
@testable import CopyHistoryCore

/// The popup shows `localizedDescription` of a failed transform, so these strings are user-facing.
@Suite struct TransformErrorDescriptionTests {
  @Test func transformErrorDescriptions() {
    #expect(TransformError.invalidInput("Expected a JSON object").errorDescription == "Expected a JSON object")
    #expect(TransformError.unsupported("--data-binary").errorDescription == "Unsupported: --data-binary")
    #expect(TransformError.noContent.errorDescription == "Nothing to convert")
    #expect(TransformError.timedOut.errorDescription == "Took too long")
  }

  /// `LocalizedError` bridges through `any Error`, which is how the UI receives it.
  @Test func transformErrorBridgesToLocalizedDescription() {
    let errors: [any Error] = [TransformError.invalidInput("bad"), TransformError.unsupported("x"),
                               TransformError.noContent, TransformError.timedOut]
    #expect(errors.map(\.localizedDescription) == ["bad", "Unsupported: x", "Nothing to convert", "Took too long"])
  }

  @Test func runnerBusyDescription() {
    #expect(TransformRunnerError.busy.errorDescription == "Still finishing a previous transform; try again in a moment")
    let error: any Error = TransformRunnerError.busy
    #expect(error.localizedDescription == TransformRunnerError.busy.errorDescription)
  }

  /// A run that exceeds its budget surfaces `.timedOut` and its description.
  @Test func timedOutRunReportsItsDescription() async {
    struct Stuck: Transform {
      let id = "stuck"
      let title = "Stuck"
      func canApply(to text: String) -> Bool { true }
      func apply(to text: String) throws -> String {
        // Polls cancellation, so the abandoned thread exits promptly after the timeout.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !TransformRunner.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        throw CancellationError()
      }
    }
    let limiter = TransformRunner.Limiter(maxConcurrent: 1)
    do {
      _ = try await TransformRunner.run(Stuck(), on: "x", timeout: 0.05, limiter: limiter)
      Issue.record("expected a timeout")
    } catch {
      #expect(error as? TransformError == .timedOut)
      #expect(error.localizedDescription == "Took too long")
    }
  }
}
