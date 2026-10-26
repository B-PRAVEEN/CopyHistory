import CoreText
import Foundation
import ImageIO
import Testing
@testable import CopyHistoryCore

/// Returns canned text per image (or for every image), optionally after a delay; records whether it
/// ran on the main thread. `hang` never returns (until the test process ends).
final class FakeOCR: OCRRecognizing, @unchecked Sendable {
  private let lock = NSLock()
  private let texts: [Data: String]
  private let fallback: String?
  let delay: TimeInterval
  let hang: Bool
  private var _onMain: [Bool] = []
  var calledOnMain: [Bool] { lock.lock(); defer { lock.unlock() }; return _onMain }

  init(_ texts: [Data: String] = [:], fallback: String? = nil, delay: TimeInterval = 0, hang: Bool = false) {
    self.texts = texts; self.fallback = fallback; self.delay = delay; self.hang = hang
  }

  private func recordThread() { lock.lock(); _onMain.append(Thread.isMainThread); lock.unlock() }

  func recognize(png: Data) async -> String? {
    recordThread()
    if hang {
      await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }  // never resumed
    }
    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    return texts[png] ?? fallback
  }
}

/// A recogniser that reports its outcome explicitly, like `VisionOCR`.
struct FakeScanner: OCRScanning {
  var result: OCRScanResult
  func scan(png: Data) async -> OCRScanResult { result }
}

/// Black text lines on a white canvas; `top` is the distance from the top edge to each line's baseline.
func makeTextCanvas(width: Int, height: Int, lines: [(text: String, top: Int)], fontSize: CGFloat = 48) -> Data? {
  guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
  let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
  let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: black] as CFDictionary
  for line in lines {
    guard let str = CFAttributedStringCreate(nil, line.text as CFString, attrs) else { return nil }
    ctx.textPosition = CGPoint(x: 40, y: height - line.top)  // CoreGraphics' origin is bottom left
    CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
  }
  guard let image = ctx.makeImage() else { return nil }
  let out = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { return nil }
  return out as Data
}

/// Black text on white, large enough for Vision.
func makeTextImage(_ text: String, width: Int = 1400, height: Int = 200) -> Data? {
  guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
  let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
  let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: black] as CFDictionary
  guard let str = CFAttributedStringCreate(nil, text as CFString, attrs) else { return nil }
  let line = CTLineCreateWithAttributedString(str)
  ctx.textPosition = CGPoint(x: 40, y: 70)
  CTLineDraw(line, ctx)
  guard let image = ctx.makeImage() else { return nil }
  let out = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { return nil }
  return out as Data
}

@Suite struct VisionOCRTests {
  /// The reviewer's fake key (Phase 2 review, E1); Vision reads it reliably.
  static let fakeKeyLine = "API_KEY=sk-proj-abcdefghjkmnpqrstuvwxyzABCDEFGH"

  @Test func recognisesRenderedText() async throws {
    let png = try #require(makeTextImage("Invoice number 4271"))
    let text = try #require(await VisionOCR().recognize(png: png))
    #expect(text.lowercased().contains("invoice"))
    #expect(text.contains("4271"))
    guard case .text(let scanned) = await VisionOCR().scan(png: png) else { Issue.record("not scanned"); return }
    #expect(scanned == text)
  }

  @Test func blankImageIsScannedAndHasNoText() async {
    let blank = makeImage(width: 300, height: 100, type: "public.png")
    #expect(await VisionOCR().scan(png: blank) == .noText)
    #expect(await VisionOCR().recognize(png: blank) == nil)
  }

  /// Phase 2 review H1: a 6016×3384 screenshot (20 MP, over the 16 MP per-pass cap) used to be
  /// skipped, so the key in it was never found and the PNG was persisted.
  @Test func sixKScreenshotIsReallyScanned() async throws {
    let png = try #require(makeTextCanvas(width: 6016, height: 3384, lines: [(Self.fakeKeyLine, 3000)], fontSize: 40))
    #expect(try #require(VisionOCR.pixelCount(of: png)) > VisionOCR.defaultMaxPixels)
    guard case .text(let text) = await VisionOCR().scan(png: png) else { Issue.record("6K image not scanned"); return }
    #expect(!SecretDetector().scan(text).isEmpty)
  }

  /// A tall scrolling capture (2880×8000, 23 MP) with the key near the bottom, read in strips.
  @Test func tallScrollingCaptureIsScannedToTheBottom() async throws {
    let png = try #require(makeTextCanvas(width: 2880, height: 8000,
                                          lines: [("Release notes", 200), (Self.fakeKeyLine, 7900)]))
    guard case .text(let text) = await VisionOCR().scan(png: png) else { Issue.record("tall image not scanned"); return }
    #expect(text.contains("Release"))
    #expect(!SecretDetector().scan(text).isEmpty)
  }

  /// Small per-pass cap so the strip logic is exercised on a small image: a line cut by one strip's
  /// bottom edge is whole in the next, and a line inside the shared band is read once.
  @Test func linesAcrossStripBoundariesAreReadOnce() async throws {
    // 1400 px wide, 500 px strips sharing 100 px: strips start at rows 0, 400, 800, 1200, 1600.
    let png = try #require(makeTextCanvas(width: 1400, height: 2000, lines: [
      ("Quarterly summary", 120),
      (Self.fakeKeyLine, 520),   // its glyphs span row 500, the first strip's bottom edge
      ("Zebra crossing", 870),   // wholly inside the band shared by strips 2 and 3 (rows 800-900)
      ("Final total 4271", 1960),
    ]))
    let ocr = VisionOCR(maxPixels: 1400 * 500)
    guard case .text(let text) = await ocr.scan(png: png) else { Issue.record("not scanned"); return }
    #expect(text.contains("Quarterly"))
    #expect(!SecretDetector().scan(text).isEmpty)
    #expect(text.contains("4271"))
    #expect(text.components(separatedBy: "Zebra").count - 1 == 1)
  }

  @Test func stripsCoverTheImageWithinTheCap() throws {
    #expect(VisionOCR.strips(width: 100, height: 100, maxPixels: 10_000)
            == [.init(rect: CGRect(x: 0, y: 0, width: 100, height: 100), overlap: 0)])
    for (w, h) in [(8192, 8192), (2880, 8000), (6016, 3384), (1400, 2000), (4001, 4000)] {
      let max = w == 1400 ? 1400 * 500 : VisionOCR.defaultMaxPixels
      let strips = try #require(VisionOCR.strips(width: w, height: h, maxPixels: max))
      #expect(strips.first?.rect.minY == 0 && strips.last?.rect.maxY == CGFloat(h))
      #expect(strips.allSatisfy { Int($0.rect.width) == w && Int($0.rect.width * $0.rect.height) <= max })
      for (a, b) in zip(strips, strips.dropFirst()) {
        #expect(a.rect.maxY - b.rect.minY == CGFloat(b.overlap) && b.overlap >= 64)  // no gap, real overlap
      }
    }
    #expect(try #require(VisionOCR.strips(width: 8192, height: 8192, maxPixels: VisionOCR.defaultMaxPixels)).count <= 5)
    #expect(VisionOCR.strips(width: 20_000, height: 2_000, maxPixels: 1_000_000) == nil)  // strips too thin
  }

  @Test func imageOverTheTotalCapFailsFromItsHeader() async throws {
    let png = try #require(makeTextImage("Invoice number 4271"))
    #expect(await VisionOCR(maxTotalPixels: 1400 * 200 - 1).scan(png: png) == .failed)
    let big = makeImage(width: 8193, height: 8192, type: "public.png")
    #expect(VisionOCR.pixelCount(of: big) == 8193 * 8192)
    let start = Date()
    #expect(await VisionOCR().scan(png: big) == .failed)
    #expect(Date().timeIntervalSince(start) < 1)
  }

  @Test func unreadableDataFails() async {
    #expect(await VisionOCR().scan(png: Data()) == .failed)
    #expect(await VisionOCR().scan(png: Data("not an image".utf8)) == .failed)
    #expect(await VisionOCR().recognize(png: Data()) == nil)
  }

  @Test func timeBudgetIsEnforced() async throws {
    let png = try #require(makeTextImage("Invoice number 4271"))
    let start = Date()
    #expect(await VisionOCR(timeBudget: 0.001).scan(png: png) == .failed)
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(await VisionOCR(timeBudget: 0).scan(png: png) == .failed)
  }

  @Test func defaultCapIsWhatTheDetectorCanScan() {
    #expect(VisionOCR().maxTextLength == SecretDetector.maxScanLength)
  }

  /// Text that cannot be scanned whole is a failure, never a silently shortened clean result.
  @Test func textOverMaxTextLengthFails() async throws {
    let png = try #require(makeTextImage("Invoice number 4271"))
    #expect(await VisionOCR(maxTextLength: 4).scan(png: png) == .failed)
  }
}

@Suite struct OCRTextTests {
  let detector = SecretDetector()
  static let secret = "sk-proj-OCRFAKEOCRFAKEOCRFAKE1234"

  @Test func cleanTrimsAndDropsEmpty() {
    #expect(OCRText.clean("  \n ", maxUTF16: 10) == nil)
    #expect(OCRText.clean(" abc \n", maxUTF16: 10) == "abc")
    #expect(OCRText.clean("abcdef", maxUTF16: 3) == "abc")
    #expect(OCRText.clean("abc", maxUTF16: 0) == nil)
    // Never splits a Character: the flag emoji is 4 UTF-16 units.
    #expect(OCRText.clean("ab🇮🇳cd", maxUTF16: 5) == "ab")
    #expect(OCRText.clean("ab🇮🇳cd", maxUTF16: 6) == "ab🇮🇳")
    #expect(OCRText.clean("🇮🇳", maxUTF16: 2) == nil)
  }

  @Test func findingsReferToTheStoredText() {
    let raw = "token: \(Self.secret)"
    let (text, findings) = OCRText.process(raw, maxLength: 1000, detector: detector)
    #expect(text == raw)
    #expect(findings == detector.scan(raw))
    #expect(!findings.isEmpty)
  }

  @Test func secretStraddlingTheCutIsStillMasked() throws {
    let raw = "token: \(Self.secret)"
    let cut = 20  // inside the key
    let (text, findings) = OCRText.process(raw, maxLength: cut, detector: detector)
    let t = try #require(text)
    #expect(t.count == cut)
    #expect(!findings.isEmpty)
    #expect(findings.allSatisfy { $0.range.upperBound <= cut })
    #expect(!detector.mask(t, findings: findings).contains("OCRFAKE"))
  }

  @Test func secretPastTheCutKeepsTheEntryFlagged() throws {
    let raw = "a harmless first line\n\(Self.secret)"
    let (text, findings) = OCRText.process(raw, maxLength: 10, detector: detector)
    #expect(text == "a harmless")
    #expect(!findings.isEmpty)  // the image itself still shows the key
    #expect(findings.allSatisfy { $0.range == 10..<10 })
    #expect(detector.mask("a harmless", findings: findings) == "a harmless")
  }

  @Test func unscannableTextIsDropped() {
    let huge = String(repeating: "a", count: SecretDetector.maxScanLength + 1)
    let r = OCRText.process(huge, maxLength: 10, detector: detector)
    #expect(r.text == nil && r.findings.isEmpty)
    #expect(OCRText.process(nil, maxLength: 10, detector: detector).text == nil)
  }

  @Test func scanOutcomeDecidesWhetherTheImageCountsAsScanned() {
    let failed = OCRText.process(OCRScanResult.failed, maxLength: 10, detector: detector)
    #expect(failed.text == nil && failed.findings.isEmpty && !failed.scanned)
    let none = OCRText.process(OCRScanResult.noText, maxLength: 10, detector: detector)
    #expect(none.text == nil && none.scanned)
    let key = OCRText.process(OCRScanResult.text("token: \(Self.secret)"), maxLength: 1000, detector: detector)
    #expect(key.scanned && !key.findings.isEmpty)
    let huge = String(repeating: "a", count: SecretDetector.maxScanLength + 1)
    #expect(!OCRText.process(OCRScanResult.text(huge), maxLength: 10, detector: detector).scanned)
  }

  @Test func deadlineScanFailsClosed() async {
    let start = Date()
    #expect(await OCRDeadline.scan(FakeOCR(hang: true), png: tinyPNG, within: 0.2) == .failed)
    #expect(Date().timeIntervalSince(start) < 2)
    // A plain recogniser's nil may mean "skipped": not a scan.
    #expect(await OCRDeadline.scan(FakeOCR(), png: tinyPNG, within: 5) == .failed)
    #expect(await OCRDeadline.scan(FakeOCR(fallback: "hi"), png: tinyPNG, within: 5) == .text("hi"))
    #expect(await OCRDeadline.scan(FakeScanner(result: .noText), png: tinyPNG, within: 5) == .noText)
    #expect(await OCRDeadline.scan(FakeScanner(result: .noText), png: tinyPNG, within: 0) == .failed)
  }

  @Test func deadlineReturnsEvenIfTheRecogniserNeverDoes() async {
    let start = Date()
    let r = await OCRDeadline.recognize(FakeOCR(hang: true), png: tinyPNG, within: 0.2)
    #expect(r == nil)
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(await OCRDeadline.recognize(FakeOCR(fallback: "hi"), png: tinyPNG, within: 5) == "hi")
    #expect(await OCRDeadline.recognize(FakeOCR(fallback: "hi"), png: tinyPNG, within: 0) == nil)
  }
}
