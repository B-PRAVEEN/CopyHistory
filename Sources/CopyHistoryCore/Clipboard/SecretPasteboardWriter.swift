import AppKit
import Foundation

/// Small seam over NSPasteboard writes so secret handling is unit-testable.
public protocol PasteboardWriting: AnyObject {
  var changeCount: Int { get }
  /// Clears the pasteboard. `currentHostOnly` keeps the new contents off Universal Clipboard.
  func clearContents(currentHostOnly: Bool)
  func setString(_ string: String, forType type: String)
  func setData(_ data: Data, forType type: String)
}

public final class SystemPasteboardWriter: PasteboardWriting {
  private let pb: NSPasteboard
  public init(_ pb: NSPasteboard = .general) { self.pb = pb }
  public var changeCount: Int { pb.changeCount }
  public func clearContents(currentHostOnly: Bool) {
    // prepareForNewContents clears too; calling clearContents() afterwards would drop the option.
    if currentHostOnly { pb.prepareForNewContents(with: .currentHostOnly) } else { pb.clearContents() }
  }
  public func setString(_ string: String, forType type: String) {
    pb.setString(string, forType: NSPasteboard.PasteboardType(type))
  }
  public func setData(_ data: Data, forType type: String) {
    pb.setData(data, forType: NSPasteboard.PasteboardType(type))
  }
}

/// Writes clipboard content for the app. Secrets are marked with the nspasteboard.org Concealed and
/// Transient types (so other clipboard managers skip them), kept off Universal Clipboard, and
/// cleared after a delay if nobody has replaced them in the meantime.
@MainActor
public final class SecretPasteboardWriter {
  public static let internalType = "io.github.b-praveen.copyhistory.internal"
  public static let concealedType = "org.nspasteboard.ConcealedType"
  public static let transientType = "org.nspasteboard.TransientType"

  private let pasteboard: PasteboardWriting
  private let detector: SecretDetecting
  private let schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
  /// The background scan of the last oversized write, if any (awaited by tests).
  private(set) var largeScan: Task<Void, Never>?

  /// - Parameter schedule: runs a closure after a delay; injectable for tests.
  public init(pasteboard: PasteboardWriting = SystemPasteboardWriter(),
              detector: SecretDetecting = SecretDetector(),
              schedule: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
                Task { @MainActor in
                  try? await Task.sleep(for: .seconds(delay))
                  work()
                }
              }) {
    self.pasteboard = pasteboard; self.detector = detector; self.schedule = schedule
  }

  /// Writes text. `sensitive` nil means "scan the text"; pass true for content derived from a
  /// flagged entry. Text too long to scan on the main thread (`SecretDetector.maxScanLength`) is
  /// first written as sensitive (fail closed) and scanned in the background; if that scan finds
  /// nothing before the clear delay runs out and nobody has copied since, it is rewritten as
  /// ordinary text and not cleared. Returns whether the write was (initially) treated as sensitive.
  @discardableResult
  public func write(text: String, sensitive: Bool? = nil, clearAfter: TimeInterval) -> Bool {
    largeScan?.cancel()
    largeScan = nil
    let oversized = sensitive == nil && text.utf16.count > SecretDetector.maxScanLength
    let secret = sensitive ?? (oversized || !detector.scan(text).isEmpty)
    write(secret: secret, clearAfter: clearAfter) { $0.setString(text, forType: "public.utf8-plain-text") }
    if oversized {
      let written = pasteboard.changeCount
      let detector = detector
      largeScan = Task { [weak self] in
        let clean = await Task.detached(priority: .userInitiated) { detector.scan(text).isEmpty }.value
        guard clean, !Task.isCancelled, let self, self.pasteboard.changeCount == written else { return }
        // Rewriting bumps changeCount, so the pending clear of the secret write no longer applies.
        self.write(secret: false, clearAfter: 0) { $0.setString(text, forType: "public.utf8-plain-text") }
      }
    }
    return secret
  }

  /// Writes an image. Pass `sensitive: true` for an image whose recognised text was flagged: it is
  /// then marked Concealed/Transient, kept off Universal Clipboard and cleared after `clearAfter`.
  public func write(png: Data, sensitive: Bool = false, clearAfter: TimeInterval = 0) {
    write(secret: sensitive, clearAfter: clearAfter) { $0.setData(png, forType: "public.png") }
  }

  private func write(secret: Bool, clearAfter: TimeInterval, _ body: (PasteboardWriting) -> Void) {
    pasteboard.clearContents(currentHostOnly: secret)
    // Markers go first: changeCount only bumps on clear, so another clipboard manager polling
    // mid-write must never see the payload without them.
    pasteboard.setData(Data([1]), forType: Self.internalType)
    if secret {
      pasteboard.setData(Data(), forType: Self.concealedType)
      pasteboard.setData(Data(), forType: Self.transientType)
    }
    body(pasteboard)
    guard secret else { return }
    let written = pasteboard.changeCount
    guard clearAfter > 0 else { return }
    schedule(clearAfter) { [pasteboard] in
      // Only clear our own secret; if the user copied something else since, leave it alone.
      if pasteboard.changeCount == written { pasteboard.clearContents(currentHostOnly: false) }
    }
  }
}
