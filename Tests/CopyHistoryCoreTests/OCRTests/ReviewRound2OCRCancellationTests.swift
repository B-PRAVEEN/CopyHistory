import Foundation
import Testing
@testable import CopyHistoryCore

// Review round 2, F2-L6: the cancellation test cancels a scan that is really running on the
// recognition queue (it waits for the first strip's request to be installed), not one cancelled
// before it ever got there.
//
// Vision ignores a `cancel()` that arrives before `perform` has started (checked empirically), so
// whether that particular call stops the first strip early depends on timing; what is deterministic
// is that the scan fails at once, no later strip starts, and the queue is free for the next image.

/// Signals each strip's start to the test; the first one waits there until the test has cancelled.
private final class StripProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var _started: [Int] = []
  private var waiter: CheckedContinuation<Void, Never>?
  private var firstSeen = false
  let cancelled = DispatchSemaphore(value: 0)

  var started: [Int] { lock.lock(); defer { lock.unlock() }; return _started }

  /// Called on the recognition queue.
  func willRecognize(_ n: Int) {
    lock.lock()
    _started.append(n)
    let first = !firstSeen
    firstSeen = true
    let w = waiter; waiter = nil
    lock.unlock()
    w?.resume()
    if first { cancelled.wait() }  // the test cancels while this strip is about to run
  }

  /// Returns once the first strip is about to be recognised.
  func waitForFirstStrip() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      lock.lock()
      if firstSeen { lock.unlock(); c.resume(); return }
      waiter = c
      lock.unlock()
    }
  }
}

@Suite struct RunningScanCancellationTests {
  @Test(.timeLimit(.minutes(1))) func cancellingARunningScanFreesTheQueue() async throws {
    // Two strips: 6016 × 3384 is over one Vision pass.
    let big = try #require(makeTextCanvas(width: 6016, height: 3384, lines: [("Quarterly summary", 400)]))
    let small = try #require(makeTextImage("Invoice number 4271"))
    let probe = StripProbe()
    var ocr = VisionOCR(timeBudget: 600)
    ocr.willRecognizeStrip = { probe.willRecognize($0) }
    let slow = Task { await ocr.scan(png: big) }

    await probe.waitForFirstStrip()  // the work is on the queue, its request installed
    slow.cancel()
    #expect(await slow.value == .failed)  // resumed by the cancellation, not by the work
    probe.cancelled.signal()

    // The next image runs right after the abandoned one and gets its whole (short) budget.
    guard case .text(let text) = await VisionOCR(timeBudget: 20).scan(png: small) else {
      Issue.record("next image did not get its budget"); return
    }
    #expect(text.contains("4271"))
    #expect(probe.started == [0])  // the second strip of the cancelled scan never started
  }
}
