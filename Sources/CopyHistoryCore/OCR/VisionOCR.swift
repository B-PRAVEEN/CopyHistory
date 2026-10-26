import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `OCRScanning` on top of Vision's `VNRecognizeTextRequest` (accurate level, language
/// correction on). Vision runs on-device; nothing touches the network.
///
/// Large images are scanned, not skipped: an image over `maxPixels` (one Vision pass) is cut into
/// full-width horizontal strips of at most `maxPixels` each, at full resolution so small text
/// stays readable, that overlap by a fifth of a strip so every text line is whole in at least one
/// strip (lines wholly inside an overlap are read once). A 6K screenshot or a tall scrolling
/// capture (up to the normalizer's 8192 px a side, about 67 MP) takes at most five passes.
///
/// Bounded work: images over `maxTotalPixels` are rejected from their header alone (nothing is
/// decoded), recognition runs on a private serial queue (never on the main thread or the Swift
/// concurrency pool, one image decoded at a time) and is cancelled after `timeBudget` for the whole
/// image. Anything not read completely, including text longer than `maxTextLength` UTF-16 units
/// (by default exactly what the secret detector can scan), is `.failed`, never partial text, so a
/// caller never mistakes an unchecked image for a clean one.
public struct VisionOCR: OCRScanning {
  /// Pixels per Vision pass; larger images are read in strips.
  public static let defaultMaxPixels = 16_000_000
  /// The largest image `ImageNormalizer` produces by default (8192 × 8192).
  public static let defaultMaxTotalPixels = ImageNormalizer.defaultMaxPixelSide * ImageNormalizer.defaultMaxPixelSide
  public static let defaultTimeBudget: TimeInterval = 10
  public static let defaultMaxTextLength = SecretDetector.maxScanLength
  /// Strips thinner than this cannot hold a line of text and its overlap: such an image fails.
  static let minStripHeight = 100

  public var maxPixels: Int
  public var maxTotalPixels: Int
  public var timeBudget: TimeInterval
  public var maxTextLength: Int

  /// One recognition at a time: a burst of screenshots queues instead of decoding all at once.
  private static let queue = DispatchQueue(label: "CopyHistory.VisionOCR", qos: .utility)

  public init(maxPixels: Int = VisionOCR.defaultMaxPixels,
              maxTotalPixels: Int = VisionOCR.defaultMaxTotalPixels,
              timeBudget: TimeInterval = VisionOCR.defaultTimeBudget,
              maxTextLength: Int = VisionOCR.defaultMaxTextLength) {
    self.maxPixels = maxPixels; self.maxTotalPixels = maxTotalPixels
    self.timeBudget = timeBudget; self.maxTextLength = maxTextLength
  }

  /// The image's size from its header, or nil when it is unreadable.
  static func dimensions(of png: Data) -> (width: Int, height: Int)? {
    guard !png.isEmpty, let source = CGImageSourceCreateWithData(png as CFData, nil),
          CGImageSourceGetCount(source) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0 else { return nil }
    return (w, h)
  }

  /// The image's pixel count from its header, or nil when it is unreadable.
  static func pixelCount(of png: Data) -> Int? {
    guard let (w, h) = dimensions(of: png) else { return nil }
    let (count, overflow) = w.multipliedReportingOverflow(by: h)
    return overflow ? Int.max : count
  }

  /// One Vision pass: `rect` in image pixels (origin top-left), and how many rows at its top are
  /// shared with the previous strip.
  struct Strip: Equatable {
    var rect: CGRect
    var overlap: Int
  }

  /// Full-width strips covering the image top to bottom, each at most `maxPixels`; nil when a
  /// strip would be thinner than `minStripHeight`.
  static func strips(width: Int, height: Int, maxPixels: Int) -> [Strip]? {
    guard width > 0, height > 0, maxPixels > 0 else { return nil }
    if height <= maxPixels / width {
      return [Strip(rect: CGRect(x: 0, y: 0, width: width, height: height), overlap: 0)]
    }
    let stripHeight = maxPixels / width
    guard stripHeight >= minStripHeight else { return nil }
    let overlap = stripHeight / 5
    let step = stripHeight - overlap
    var out: [Strip] = []
    var top = 0
    while true {
      let h = min(stripHeight, height - top)
      out.append(Strip(rect: CGRect(x: 0, y: top, width: width, height: h), overlap: out.isEmpty ? 0 : overlap))
      if top + h >= height { break }
      top += step
    }
    return out
  }

  public func scan(png: Data) async -> OCRScanResult {
    guard timeBudget > 0, let (width, height) = Self.dimensions(of: png),
          let pixels = Self.pixelCount(of: png), pixels <= maxTotalPixels,
          let strips = Self.strips(width: width, height: height, maxPixels: maxPixels) else { return .failed }
    let once = ResumeOnce()
    let maxLength = maxTextLength
    let budget = timeBudget
    return await withCheckedContinuation { (cont: CheckedContinuation<OCRScanResult, Never>) in
      once.set(cont)
      Self.queue.async {
        // Waited too long in the queue behind other images: give up rather than overrun the budget.
        guard !once.isDone else { return }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == width, image.height == height else { once.resume(.failed); return }
        var lines: [String] = []
        for strip in strips {
          guard let tile = strips.count == 1 ? image : image.cropping(to: strip.rect) else { once.resume(.failed); return }
          let request = VNRecognizeTextRequest()
          request.recognitionLevel = .accurate
          request.usesLanguageCorrection = true
          guard once.install(cancel: { request.cancel() }) else { return }
          let handler = VNImageRequestHandler(cgImage: tile, options: [:])
          do { try handler.perform([request]) } catch { once.resume(.failed); return }
          guard !once.isDone else { return }
          // Vision boxes are normalised with the origin at the bottom left: the shared band is at the top.
          let band = 1 - CGFloat(strip.overlap) / CGFloat(tile.height)
          for observation in request.results ?? [] {
            if strip.overlap > 0, observation.boundingBox.minY >= band { continue }  // read in the previous strip
            if let line = observation.topCandidates(1).first?.string { lines.append(line) }
          }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { once.resume(.noText) }
        else if text.utf16.count > maxLength { once.resume(.failed) }
        else { once.resume(.text(text)) }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget) { once.timeOut() }
    }
  }
}

/// Resumes a continuation exactly once, from whichever of recognition or the timer gets there first.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var cont: CheckedContinuation<OCRScanResult, Never>?
  private var done = false
  private var cancel: (() -> Void)?

  var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }

  /// Called from the recognition queue before each request runs; false when the timer already fired.
  func install(cancel c: @escaping () -> Void) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !done else { return false }
    cancel = c
    return true
  }

  func set(_ c: CheckedContinuation<OCRScanResult, Never>) { lock.lock(); cont = c; lock.unlock() }

  func resume(_ value: OCRScanResult) {
    lock.lock()
    guard !done else { lock.unlock(); return }
    done = true
    let c = cont; cont = nil; cancel = nil
    lock.unlock()
    c?.resume(returning: value)
  }

  func timeOut() {
    lock.lock()
    let c = done ? nil : cancel
    lock.unlock()
    c?()
    resume(.failed)
  }
}
