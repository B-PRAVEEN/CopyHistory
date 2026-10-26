import CoreGraphics
import Foundation
import Testing
@testable import CopyHistoryCore

// Review R-L5, R-L6 and R-L8, plus the cancellable OCR timer.

/// R-L8: absurd budgets neither trap nor fail a scan that would succeed.
@Suite struct OCRDeadlineBudgetTests {
  @Test func hugeBudgetsAreClampedNotTrapped() async {
    let png = Data([1, 2, 3])
    #expect(await OCRDeadline.scan(FakeScanner(result: .noText), png: png, within: .infinity) == .noText)
    #expect(await OCRDeadline.scan(FakeScanner(result: .text("a")), png: png, within: 1e30) == .text("a"))
  }

  @Test func nanZeroAndNegativeBudgetsFailAtOnce() async {
    let png = Data([1, 2, 3])
    for seconds: TimeInterval in [.nan, 0, -1, -TimeInterval.infinity] {
      #expect(await OCRDeadline.scan(FakeScanner(result: .noText), png: png, within: seconds) == .failed)
    }
  }

  @Test(.timeLimit(.minutes(1))) func visionOCRClampsItsOwnBudget() async {
    let blank = makeImage(width: 300, height: 100, type: "public.png")
    #expect(await VisionOCR(timeBudget: .infinity).scan(png: blank) == .noText)
    #expect(await VisionOCR(timeBudget: .nan).scan(png: blank) == .failed)
  }
}

/// R-L5: cancelling the scanning task stops the Vision work instead of leaving it on the queue.
@Suite struct VisionOCRCancellationTests {
  @Test(.timeLimit(.minutes(1))) func alreadyCancelledTaskFailsWithoutHanging() async throws {
    let png = try #require(makeTextImage("Invoice number 4271"))
    let task = Task { () -> OCRScanResult in
      withUnsafeCurrentTask { $0?.cancel() }
      return await VisionOCR(timeBudget: 600).scan(png: png)
    }
    #expect(await task.value == .failed)
  }

  /// A cancelled scan of a large image frees the serial queue: the next image is read well within
  /// its own budget instead of timing out behind the abandoned one.
  @Test(.timeLimit(.minutes(1))) func cancelledScanFreesTheQueueForTheNextImage() async throws {
    let big = try #require(makeTextCanvas(width: 6016, height: 3384, lines: [("Quarterly summary", 400)]))
    let small = try #require(makeTextImage("Invoice number 4271"))
    let slow = Task { await VisionOCR(timeBudget: 600).scan(png: big) }
    slow.cancel()
    #expect(await slow.value == .failed)
    guard case .text(let text) = await VisionOCR(timeBudget: 20).scan(png: small) else {
      Issue.record("next image did not get its budget"); return
    }
    #expect(text.contains("4271"))
  }

  @Test(.timeLimit(.minutes(1))) func setAfterTimeOutResumesImmediately() async {
    let once = ResumeOnce()
    once.timeOut()
    let result = await withCheckedContinuation { (c: CheckedContinuation<OCRScanResult, Never>) in
      if once.set(c) { Issue.record("continuation accepted after time-out"); once.resume(.noText) }
    }
    #expect(result == .failed)
  }

  @Test func timeOutCancelsTheInstalledRequest() {
    let once = ResumeOnce()
    let cancelled = Flag()
    #expect(once.install(cancel: { cancelled.set() }))
    once.timeOut()
    #expect(cancelled.isSet)
    #expect(once.isDone)
    #expect(!once.install(cancel: {}))
  }

  /// (a) The deadline timer is a cancellable work item, cancelled as soon as the result is in.
  @Test func deadlineTimerIsCancelledOnceTheResultIsIn() {
    let once = ResumeOnce()
    let timer = DispatchWorkItem {}
    once.setTimer(timer)
    #expect(!timer.isCancelled)
    once.resume(.noText)
    #expect(timer.isCancelled)
    let late = DispatchWorkItem {}
    once.setTimer(late)  // set after the result: cancelled at once
    #expect(late.isCancelled)
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
  func set() { lock.lock(); value = true; lock.unlock() }
}

/// R-L6: every line no taller than the overlap is kept from exactly one strip, which holds it whole.
@Suite struct StripOverlapTests {
  /// What a strip's Vision pass reports for a line spanning image rows `top..<bottom`: the visible part
  /// as a normalised box (origin bottom left), and whether that part is the whole line.
  private func observation(top: Int, bottom: Int, in strip: VisionOCR.Strip) -> (box: CGRect, whole: Bool)? {
    let s = strip.rect
    let lo = max(CGFloat(top), s.minY), hi = min(CGFloat(bottom), s.maxY)
    guard hi > lo else { return nil }
    let box = CGRect(x: 0, y: (s.maxY - hi) / s.height, width: 1, height: (hi - lo) / s.height)
    return (box, lo == CGFloat(top) && hi == CGFloat(bottom))
  }

  /// Strip indexes that keep the line, and whether each kept reading is whole.
  private func reads(top: Int, bottom: Int, strips: [VisionOCR.Strip]) -> [(index: Int, whole: Bool)] {
    strips.enumerated().compactMap { i, strip in
      guard let seen = observation(top: top, bottom: bottom, in: strip) else { return nil }
      let below = i + 1 < strips.count ? strips[i + 1].overlap : 0
      let kept = VisionOCR.keeps(seen.box, tileHeight: Int(strip.rect.height), overlapAbove: strip.overlap,
                                 overlapBelow: below)
      return kept ? (i, seen.whole) : nil
    }
  }

  // 1000 px wide, 500 px strips sharing 100 px: strips start at rows 0, 400, 800, ...
  private let strips = VisionOCR.strips(width: 1000, height: 2300, maxPixels: 1000 * 500)!

  @Test func layout() {
    #expect(strips.map(\.rect.minY) == [0, 400, 800, 1200, 1600, 2000])
    #expect(strips.dropFirst().allSatisfy { $0.overlap == 100 })
  }

  /// The duplicated line from the review: starts in the band (rows 400-500) and ends below it.
  @Test func lineStartingInTheBandAndEndingBelowIsReadOnceWholeFromTheNextStrip() {
    let r = reads(top: 470, bottom: 530, strips: strips)
    #expect(r.count == 1)
    #expect(r.first?.index == 1 && r.first?.whole == true)
  }

  @Test func lineStartingAboveTheBandAndEndingInsideIsReadOnceWholeFromThePreviousStrip() {
    let r = reads(top: 370, bottom: 430, strips: strips)
    #expect(r.count == 1)
    #expect(r.first?.index == 0 && r.first?.whole == true)
  }

  @Test func lineWhollyInsideTheBandIsReadOnce() {
    let r = reads(top: 420, bottom: 480, strips: strips)
    #expect(r.count == 1)
    #expect(r.first?.whole == true)
  }

  /// Exhaustive: no line of height up to the overlap is dropped by every strip, read twice, or read cut.
  @Test func everyLineIsReadExactlyOnceAndWhole() {
    for height in [8, 31, 64, 99, 100] {
      for top in 0...(2300 - height) {
        let r = reads(top: top, bottom: top + height, strips: strips)
        guard r.count == 1, r[0].whole else {
          Issue.record("line \(top)..<\(top + height): \(r)"); return
        }
      }
    }
  }

  @Test func singleStripKeepsEverything() {
    let one = VisionOCR.Strip(rect: CGRect(x: 0, y: 0, width: 100, height: 100), overlap: 0)
    #expect(VisionOCR.keeps(CGRect(x: 0, y: 0, width: 1, height: 0.05), tileHeight: Int(one.rect.height),
                            overlapAbove: 0, overlapBelow: 0))
    #expect(VisionOCR.keeps(CGRect(x: 0, y: 0.95, width: 1, height: 0.05), tileHeight: 100, overlapAbove: 0, overlapBelow: 0))
  }
}
