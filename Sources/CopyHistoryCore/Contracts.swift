import Foundation

// Shared contracts. Workers A (Clipboard/Redaction), B (Transforms) and C (UI) all build against
// these types; change them only through the coordinator.

public struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case text, image }

  public let id: UUID
  public var kind: Kind
  public var text: String?        // text entries
  public var imagePNG: Data?      // image entries
  public var sourceApp: String?   // bundle identifier of the frontmost app at copy time
  public var pinned: Bool
  public var copyCount: Int
  public var firstCopiedAt: Date
  public var lastCopiedAt: Date
  public var findings: [SecretFinding]  // non-empty => entry is masked in the UI
  public var expiresAt: Date?     // set for entries with findings when auto-expire is enabled
  public var ocrText: String?     // image entries: text recognised in the image (nil = not run / none found)

  public init(id: UUID = UUID(), kind: Kind, text: String? = nil, imagePNG: Data? = nil,
              sourceApp: String? = nil, pinned: Bool = false, copyCount: Int = 1,
              now: Date = Date(), findings: [SecretFinding] = [], expiresAt: Date? = nil,
              ocrText: String? = nil) {
    self.id = id; self.kind = kind; self.text = text; self.imagePNG = imagePNG
    self.sourceApp = sourceApp; self.pinned = pinned; self.copyCount = copyCount
    self.firstCopiedAt = now; self.lastCopiedAt = now
    self.findings = findings; self.expiresAt = expiresAt; self.ocrText = ocrText
  }
}

public struct SecretFinding: Codable, Equatable, Sendable {
  public enum Category: String, Codable, Sendable {
    case openAIKey, awsAccessKey, awsSecretKey, githubToken, slackToken, jwt, privateKey, creditCard, genericSecret
  }
  public var category: Category
  public var range: Range<Int>  // character offsets into the scanned string

  public init(category: Category, range: Range<Int>) {
    self.category = category; self.range = range
  }
}

/// Worker A implements this. Pure and synchronous: no I/O.
public protocol SecretDetecting: Sendable {
  func scan(_ text: String) -> [SecretFinding]
  /// Replaces every finding with a mask, e.g. `sk-••••••••`. Keeps a short prefix for recognisability.
  func mask(_ text: String, findings: [SecretFinding]) -> String
}

/// Worker B implements one type per transform. Pure and synchronous.
public protocol Transform: Sendable {
  var id: String { get }      // stable identifier, e.g. "json-to-typescript"
  var title: String { get }   // menu title, e.g. "JSON → TypeScript interface"
  func canApply(to text: String) -> Bool   // cheap check used to decide whether to offer the transform
  func apply(to text: String) throws -> String
}

/// Worker B provides the registry; Worker C reads it to build the Tab picker.
public enum TransformRegistry {
  public nonisolated(unsafe) static var all: [any Transform] = []
}

/// Worker A implements; Worker C consumes.
public protocol ClipboardHistoryStore: AnyObject {
  func entries(matching query: String) -> [ClipboardEntry]  // pinned first, then newest; fuzzy on text
  func add(_ entry: ClipboardEntry) -> ClipboardEntry       // dedupes by content, bumps copyCount/lastCopiedAt
  func togglePin(_ id: UUID)
  func remove(_ id: UUID)
  func removeExpired(now: Date)
  func clearUnpinned()
}

/// Phase 2 (OCR shelf). Implemented in `CopyHistoryCore/OCR` on top of Vision; tests use a fake.
/// Must be safe to call from any thread, never touch the network, and return nil when no text is
/// found or the image is skipped (too large, time budget exceeded).
public protocol OCRRecognizing: Sendable {
  func recognize(png: Data) async -> String?
}
