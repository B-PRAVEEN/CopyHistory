import Testing
import Foundation
@testable import CopyHistoryCore

private final class ResultBox: @unchecked Sendable {
  var result: Result<String, Error>?
}

/// Applies `transform` on a thread that is already cancelled, as an abandoned runner thread is.
private func applyOnCancelledThread(_ transform: any Transform, _ text: String) -> Result<String, Error> {
  let box = ResultBox()
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    // Cancelled here, not before `start()`: a thread cancelled before it starts never runs.
    Thread.current.cancel()
    box.result = Result { try transform.apply(to: text) }
    done.signal()
  }
  thread.stackSize = 32 * 1024 * 1024
  thread.start()
  done.wait()
  return box.result!
}

private func isCancellation(_ r: Result<String, Error>) -> Bool {
  if case .failure(let e) = r { return e is CancellationError }
  return false
}

/// R5: transforms poll `TransformRunner.isCancelled`, so an abandoned run stops instead of
/// holding a limiter slot until it finishes on its own.
@Suite(.serialized, .timeLimit(.minutes(2))) struct TransformCancellationTests {
  static let bigHTML = String(repeating: "<p>some <b>bold</b> text</p>", count: 40_000)

  @Test func htmlStopsOnCancelledThread() {
    // The renderer runs on a nested large-stack thread, which must see the outer cancellation.
    #expect(isCancellation(applyOnCancelledThread(HTMLToMarkdown(), Self.bigHTML)))
  }

  @Test func stripFormattingStopsOnCancelledThread() {
    #expect(isCancellation(applyOnCancelledThread(StripFormatting(), Self.bigHTML)))
    #expect(isCancellation(applyOnCancelledThread(StripFormatting(), String(repeating: "**a** b\n", count: 40_000))))
  }

  @Test func delimitedStopsOnCancelledThread() {
    let csv = String(repeating: "a,b,c\n", count: 40_000)
    #expect(isCancellation(applyOnCancelledThread(DelimitedToMarkdown(), csv)))
  }

  @Test func notCancelledStillConverts() throws {
    #expect(try HTMLToMarkdown().apply(to: Self.bigHTML).hasPrefix("some **bold** text"))
    #expect(try DelimitedToMarkdown().apply(to: String(repeating: "a,b\n", count: 40_000)).hasPrefix("| a | b |"))
  }

  /// The review's scenario: a heavy run abandoned after its timeout must free its slot promptly.
  @Test func timedOutHeavyRunFreesItsSlotPromptly() async throws {
    let limiter = TransformRunner.Limiter(maxConcurrent: 1)
    let heavy = String(repeating: "<blockquote><p>x</p>", count: 90) + String(repeating: "<p>word <i>w</i></p>", count: 200_000)
    await #expect(throws: TransformError.timedOut) {
      try await TransformRunner.run(HTMLToMarkdown(), on: heavy, timeout: 0.1, limiter: limiter)
    }
    let start = Date()
    for _ in 0..<300 where limiter.liveCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
    let held = Date().timeIntervalSince(start)
    #expect(limiter.liveCount == 0)
    #expect(held < 0.5, "slot held \(held)s after the timeout")
    #expect(try await TransformRunner.run(StripFormatting(), on: "**hi**", limiter: limiter) == "hi")
  }
  /// The review's exact R5 experiment: most of this input's cost is in each nesting level
  /// re-processing its whole subtree, after all child nodes have been walked.
  @Test func timedOutDeepListFreesItsSlotPromptly() async throws {
    let limiter = TransformRunner.Limiter(maxConcurrent: 1)
    let input = String(repeating: "<ul><li>", count: 100_000)
    let direct = Date()
    _ = try? HTMLToMarkdown().apply(to: input)
    let directSeconds = Date().timeIntervalSince(direct)
    await #expect(throws: TransformError.timedOut) {
      try await TransformRunner.run(HTMLToMarkdown(), on: input, timeout: 0.05, limiter: limiter)
    }
    let start = Date()
    for _ in 0..<300 where limiter.liveCount > 0 { try await Task.sleep(for: .milliseconds(5)) }
    let held = Date().timeIntervalSince(start)
    #expect(limiter.liveCount == 0)
    #expect(held < 0.5, "slot held \(held)s after the timeout (direct run: \(directSeconds)s)")
    #expect(try await TransformRunner.run(StripFormatting(), on: "**hi**", limiter: limiter) == "hi")
  }
}

/// Carry-over from F7/R5: nested lists no longer grow output by one indent level per element,
/// and the renderer enforces `transformMaxOutputBytes` for every construct, not only tables.
@Suite(.serialized, .timeLimit(.minutes(2))) struct HTMLOutputBoundTests {
  @Test func listIndentationIsCapped() throws {
    // 40 levels stays within the parser's element depth limit, so every item is still a list item.
    let input = String(repeating: "<ul><li>x", count: 40)
    let out = try HTMLToMarkdown().apply(to: input)
    let lines = out.split(separator: "\n")
    let widest = lines.map { (line: Substring) -> Int in line.prefix(while: { $0 == " " }).count }.max() ?? 0
    #expect(widest == 2 * MarkdownRenderer.maxListIndentDepth)
    #expect(lines.count == 40)
    #expect(lines.allSatisfy { $0.hasSuffix("- x") })
  }

  @Test func shallowNestingKeepsItsIndentation() throws {
    let out = try HTMLToMarkdown().apply(to: "<ul><li>a<ul><li>b<ol><li>c</li></ol></li></ul></li></ul>")
    #expect(out == "- a\n  - b\n    1. c")
  }

  @Test func deepListGrowthIsBounded() throws {
    // Was ~12.5x the input (and ~10 s per 800 KB) with 100 indentation levels per line.
    let input = String(repeating: "<ul><li>", count: 20_000)
    let out = try HTMLToMarkdown().apply(to: input)
    #expect(out.utf8.count < 4 * input.utf8.count)
  }

  @Test func outputCapAppliesBeyondTables() {
    // Every line inside 99 nested blockquotes gets a 198-byte prefix: ~33 MB from 750 KB.
    let input = String(repeating: "<blockquote>", count: 99) + String(repeating: "x<br>", count: 150_000)
    // Not `#expect(throws:)`: on failure it would print the whole 33 MB result.
    var thrown: Error?
    do { _ = try HTMLToMarkdown().apply(to: input) } catch { thrown = error }
    #expect(thrown as? TransformError == .invalidInput("Output too large"))
  }
}

/// Cancelling between `install` and `attach` used to cancel the worker thread before `start()`;
/// such a thread never runs, so its limiter slot leaked for good. Probabilistic: it races on purpose.
@Suite(.timeLimit(.minutes(1))) struct TransformRunnerCancelRaceTests {
  @Test func immediateCancellationsNeverLeakSlots() async throws {
    let limiter = TransformRunner.Limiter(maxConcurrent: 1_000)
    let tasks = (0..<400).map { _ in
      Task { try await TransformRunner.run(StripFormatting(), on: "**a**", timeout: 5, limiter: limiter) }
    }
    for t in tasks { t.cancel() }
    for t in tasks { _ = try? await t.value }
    for _ in 0..<200 where limiter.liveCount > 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(limiter.liveCount == 0)
  }
}
