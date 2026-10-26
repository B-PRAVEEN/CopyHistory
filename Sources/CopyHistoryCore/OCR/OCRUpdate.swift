import Foundation

/// The outcome of one recognition, telling "nothing to read" apart from "could not read it": only a
/// completed scan may let an image reach disk (see `HistoryStore`).
public enum OCRScanResult: Sendable, Equatable {
  /// The whole image was read; the text is trimmed and non-empty.
  case text(String)
  /// The whole image was read and holds no text.
  case noText
  /// Not (fully) scanned: unreadable, too large, out of time, recognition error, or too much text
  /// to scan for secrets.
  case failed
}

/// An `OCRRecognizing` that reports why it returned no text. `ClipboardMonitor` prefers `scan`;
/// for a plain `OCRRecognizing`, whose nil means either "no text" or "skipped", nil counts as
/// `.failed`, so an ambiguous answer never lets an image be persisted.
public protocol OCRScanning: OCRRecognizing {
  func scan(png: Data) async -> OCRScanResult
}

extension OCRScanning {
  public func recognize(png: Data) async -> String? {
    if case .text(let text) = await scan(png: png) { return text }
    return nil
  }
}

/// The outcome of recognising text in one image entry, delivered by `ClipboardMonitor.onOCR` after
/// the entry itself; apply it with `HistoryStore.applyOCR(_:)`.
///
/// `findings` index into `ocrText` (Character offsets), exactly like a text entry's findings index
/// into `text`. Non-empty findings mean the image shows a secret: the entry must be treated as
/// flagged (masked, memory-only, auto-expiring), pixels included. `scanned` false means the image
/// was not (fully) checked: it must be treated as possibly holding a secret and kept off disk.
public struct OCRUpdate: Sendable, Equatable {
  /// The id of the entry as the monitor delivered it.
  public var entryID: UUID
  /// The image the text came from: finds the entry when the store folded the copy into an older one.
  public var imagePNG: Data
  /// True only when recognition completed and all its text was scanned for secrets.
  public var scanned: Bool
  /// nil when no text was found or the image was not scanned (see `scanned`).
  public var ocrText: String?
  public var findings: [SecretFinding]
  public var expiresAt: Date?

  public init(entryID: UUID, imagePNG: Data, scanned: Bool, ocrText: String?, findings: [SecretFinding] = [],
              expiresAt: Date? = nil) {
    self.entryID = entryID; self.imagePNG = imagePNG; self.scanned = scanned; self.ocrText = ocrText
    self.findings = findings; self.expiresAt = expiresAt
  }
}

enum OCRText {
  /// Trims, drops empty results, and cuts to at most `maxUTF16` UTF-16 units on a Character boundary.
  static func clean(_ raw: String, maxUTF16: Int) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, maxUTF16 > 0 else { return nil }
    guard trimmed.utf16.count > maxUTF16 else { return trimmed }
    var units = 0
    var end = trimmed.startIndex
    for i in trimmed.indices {
      units += trimmed[i].utf16.count
      if units > maxUTF16 { break }
      end = trimmed.index(after: i)
    }
    let cut = String(trimmed[..<end])
    return cut.isEmpty ? nil : cut
  }

  /// Scans the full recognised text before cutting it to `maxLength`, so a secret straddling the
  /// cut is still found: its visible part stays masked, and a secret entirely past the cut keeps
  /// the entry flagged through an empty finding at the end (the pixels still show it).
  /// Text the detector cannot scan in bounded time is dropped entirely (nil, no findings).
  static func process(_ raw: String?, maxLength: Int, detector: SecretDetecting)
    -> (text: String?, findings: [SecretFinding]) {
    guard let raw, raw.utf16.count <= SecretDetector.maxScanLength,
          let full = clean(raw, maxUTF16: SecretDetector.maxScanLength) else { return (nil, []) }
    let found = detector.scan(full)
    let text = String(full.prefix(maxLength))
    let count = text.count
    guard count < full.count else { return (text, found) }
    let clamped = found.map { f -> SecretFinding in
      let lo = min(f.range.lowerBound, count)
      return SecretFinding(category: f.category, range: lo..<min(max(f.range.upperBound, lo), count))
    }
    return (text, clamped)
  }

  /// `process` for a recognition outcome, plus whether the image counts as scanned: a failed
  /// recognition, or text too long to scan for secrets, does not.
  static func process(_ result: OCRScanResult, maxLength: Int, detector: SecretDetecting)
    -> (text: String?, findings: [SecretFinding], scanned: Bool) {
    switch result {
    case .failed: return (nil, [], false)
    case .noText: return (nil, [], true)
    case .text(let raw):
      guard raw.utf16.count <= SecretDetector.maxScanLength else { return (nil, [], false) }
      let (text, findings) = process(raw, maxLength: maxLength, detector: detector)
      return (text, findings, true)
    }
  }
}

/// Runs a recogniser with a hard deadline that does not depend on it cooperating: the caller gets
/// `.failed` once `seconds` have passed, even if the recogniser never returns. Budgets over
/// `maxSeconds` are clamped; zero, negative and NaN budgets fail at once.
enum OCRDeadline {
  static let maxSeconds: TimeInterval = 3600

  static func scan(_ ocr: any OCRRecognizing, png: Data, within seconds: TimeInterval) async -> OCRScanResult {
    guard seconds > 0 else { return .failed }  // also false for NaN
    let budget = min(seconds, maxSeconds)
    let gate = Gate()
    return await withCheckedContinuation { (cont: CheckedContinuation<OCRScanResult, Never>) in
      gate.set(cont)
      let work = Task.detached(priority: .utility) {
        let result: OCRScanResult
        if let scanner = ocr as? any OCRScanning {
          result = await scanner.scan(png: png)
        } else {
          // A plain recogniser's nil is ambiguous ("no text" or "skipped"): fail closed.
          result = await ocr.recognize(png: png).map(OCRScanResult.text) ?? .failed
        }
        gate.resume(result)
      }
      let timer = Task.detached(priority: .utility) {
        try? await Task.sleep(for: .seconds(budget))
        work.cancel()
        gate.resume(.failed)
      }
      gate.onResume = { timer.cancel() }
    }
  }

  /// The recognised text, or nil when there is none or the scan failed.
  static func recognize(_ ocr: any OCRRecognizing, png: Data, within seconds: TimeInterval) async -> String? {
    if case .text(let text) = await scan(ocr, png: png, within: seconds) { return text }
    return nil
  }

  private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<OCRScanResult, Never>?
    private var done = false
    private var after: (@Sendable () -> Void)?

    func set(_ c: CheckedContinuation<OCRScanResult, Never>) { lock.lock(); cont = c; lock.unlock() }

    var onResume: (@Sendable () -> Void)? {
      get { lock.lock(); defer { lock.unlock() }; return after }
      set {
        lock.lock()
        if done { lock.unlock(); newValue?(); return }
        after = newValue
        lock.unlock()
      }
    }

    func resume(_ value: OCRScanResult) {
      lock.lock()
      guard !done else { lock.unlock(); return }
      done = true
      let c = cont, a = after
      cont = nil; after = nil
      lock.unlock()
      a?()
      c?.resume(returning: value)
    }
  }
}
