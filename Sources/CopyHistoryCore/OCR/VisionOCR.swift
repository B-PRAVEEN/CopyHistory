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
/// strip; each line is kept from exactly one strip that holds it whole (see `keeps`). A 6K screenshot or a tall scrolling
/// capture (up to the normalizer's 8192 px a side, about 67 MP) takes at most five passes.
///
/// Bounded work: images over `maxTotalPixels` are rejected from their header alone (nothing is
/// decoded), recognition runs on a private serial queue (never on the main thread or the Swift
/// concurrency pool, one image decoded at a time) and is cancelled after `timeBudget` for the whole
/// image, or as soon as the calling task is cancelled. Anything not read completely, including text longer than `maxTextLength` UTF-16 units
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
    let budget = min(timeBudget, OCRDeadline.maxSeconds)
    // Cancelling the calling task (e.g. `OCRDeadline` giving up) stops the Vision request at once,
    // so the serial queue is free for the next image and its full budget.
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (cont: CheckedContinuation<OCRScanResult, Never>) in
        guard once.set(cont) else { return }
        Self.queue.async {
          // Waited too long in the queue behind other images: give up rather than overrun the budget.
          guard !once.isDone else { return }
          guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                image.width == width, image.height == height else { once.resume(.failed); return }
          var lines: [String] = []
          for (i, strip) in strips.enumerated() {
            guard let tile = strips.count == 1 ? image : image.cropping(to: strip.rect) else { once.resume(.failed); return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            guard once.install(cancel: { request.cancel() }) else { return }
            let handler = VNImageRequestHandler(cgImage: tile, options: [:])
            do { try handler.perform([request]) } catch { once.resume(.failed); return }
            guard !once.isDone else { return }
            let below = i + 1 < strips.count ? strips[i + 1].overlap : 0
            for observation in request.results ?? []
            where Self.keeps(observation.boundingBox, tileHeight: tile.height, overlapAbove: strip.overlap, overlapBelow: below) {
              if let line = observation.topCandidates(1).first?.string { lines.append(line) }
            }
          }
          let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { once.resume(.noText) }
          else if text.utf16.count > maxLength { once.resume(.failed) }
          else { once.resume(.text(text)) }
        }
        let timer = DispatchWorkItem { once.timeOut() }
        once.setTimer(timer)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget, execute: timer)
      }
    } onCancel: {
      once.timeOut()
    }
  }

  /// Whether a strip's reading of a line is the one kept. Each overlap band is split at its middle
  /// row: a line belongs to the strip on the side of its centre, where (if no taller than the
  /// overlap) it is whole, so it is read exactly once and never from a strip that cuts it.
  /// `box` is Vision's normalised box (origin bottom left) in a tile `tileHeight` pixels high;
  /// `overlapAbove`/`overlapBelow` are the rows shared with the previous/next strip.
  static func keeps(_ box: CGRect, tileHeight: Int, overlapAbove: Int, overlapBelow: Int) -> Bool {
    let height = CGFloat(tileHeight)
    // Snapped to 1/1024 px so both strips agree on a line centred exactly on the band's middle.
    let centreFromTop = ((1 - box.midY) * height * 1024).rounded() / 1024
    if overlapAbove > 0, centreFromTop <= CGFloat(overlapAbove) / 2 { return false }  // the previous strip's
    if overlapBelow > 0, centreFromTop > height - CGFloat(overlapBelow) / 2 { return false }  // the next strip's
    return true
  }
}

/// Resumes a continuation exactly once, from whichever of recognition, the timer or task
/// cancellation gets there first, and then cancels the timer.
final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var cont: CheckedContinuation<OCRScanResult, Never>?
  private var result: OCRScanResult?
  private var cancel: (() -> Void)?
  private var timer: DispatchWorkItem?

  var isDone: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }

  /// Called from the recognition queue before each request runs; false when the timer already fired.
  func install(cancel c: @escaping () -> Void) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard result == nil else { return false }
    cancel = c
    return true
  }

  /// False, with `c` resumed at once, when it is already over (the task was cancelled first).
  func set(_ c: CheckedContinuation<OCRScanResult, Never>) -> Bool {
    lock.lock()
    guard let result else { cont = c; lock.unlock(); return true }
    lock.unlock()
    c.resume(returning: result)
    return false
  }

  /// The deadline timer; cancelled when the result is in (at once if it already is).
  func setTimer(_ t: DispatchWorkItem) {
    lock.lock()
    guard result == nil else { lock.unlock(); t.cancel(); return }
    timer = t
    lock.unlock()
  }

  func resume(_ value: OCRScanResult) {
    lock.lock()
    guard result == nil else { lock.unlock(); return }
    result = value
    let c = cont, t = timer
    cont = nil; cancel = nil; timer = nil
    lock.unlock()
    t?.cancel()
    c?.resume(returning: value)
  }

  func timeOut() {
    lock.lock()
    let c = result == nil ? cancel : nil
    lock.unlock()
    c?()
    resume(.failed)
  }
}
