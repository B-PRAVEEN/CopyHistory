import Foundation

/// What the popup writes to the pasteboard for one action.
public enum PasteContent: Equatable, Sendable {
  case text(String)
  case image(Data)
}

/// Which part of an entry a paste action asks for.
public enum PasteRequest: Equatable, Sendable {
  case entry    // the entry itself: its text, or its image (↩)
  case ocrText  // only the text recognised in an image entry (⇧⌘↩)
}

/// The outcome of a paste, copy or transform request in the popup.
public enum PasteDecision: Equatable, Sendable {
  /// Write `content`; `sensitive` goes to the pasteboard writer (see `PastePolicy.sensitivity`).
  case deliver(PasteContent, sensitive: Bool?)
  /// Do nothing and show `message`, keeping the popup open.
  case refuse(String)
  /// Nothing to do (no data); stay silent.
  case none
}

/// Pure decisions behind the popup's rows and paste actions, kept out of SwiftUI so they can be tested.
public enum PopupPolicy {
  /// Characters of recognised text shown in a row; masking runs on this prefix only, so a huge
  /// OCR result never costs more than this on the main thread.
  public static let ocrSnippetLength = 200

  public static let restoringVaultMessage = "Pinned items are still being unlocked from the Keychain — try again in a moment"
  public static let plainOnlyImageMessage = "Plain-text-only paste is on — images are skipped"
  public static let plainOnlyImageWithTextMessage = "Plain-text-only paste is on — images are skipped (⇧⌘↩ pastes its text)"
  public static let noOCRTextMessage = "No text was recognised in this item"

  /// The recognised text of an image entry, if any (whitespace-only counts as none).
  public static func ocrText(of entry: ClipboardEntry) -> String? {
    guard entry.kind == .image, let text = entry.ocrText,
          text.contains(where: { !$0.isWhitespace }) else { return nil }
    return text
  }

  /// One-line snippet of an image's recognised text for its row, or nil when there is none.
  /// A flagged entry's snippet is masked: its findings index into `ocrText`, and the prefix is also
  /// rescanned so a secret is hidden even if a finding does not line up (fail closed).
  public static func ocrSnippet(for entry: ClipboardEntry, detector: any SecretDetecting) -> String? {
    guard let full = ocrText(of: entry) else { return nil }
    var shown = String(full.prefix(ocrSnippetLength))
    if !entry.findings.isEmpty {
      // `mask` clamps ranges, so a finding cut by the prefix is still masked up to the cut.
      shown = detector.mask(shown, findings: entry.findings)
      let missed = detector.scan(shown)
      if !missed.isEmpty { shown = detector.mask(shown, findings: missed) }
    }
    let truncated = full.prefix(ocrSnippetLength + 1).count > ocrSnippetLength  // O(1), not O(n)
    return oneLine(shown) + (truncated ? "…" : "")
  }

  /// Collapses line breaks for a one-line row.
  public static func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
  }

  /// While the vault restore runs, vaulted pins still hold their masked placeholder and carry no
  /// findings yet, so any pinned text could be bullets (pasting, copying or transforming it would
  /// deliver `ghp_••••••••`), and a pinned image with recognised text could be a screenshot of a
  /// secret that is not flagged yet (it would be pasted unmarked). Fail closed for both until the
  /// restore finishes; pinned images without recognised text are never vaulted.
  public static func isBlockedByVaultRestore(_ entry: ClipboardEntry, request: PasteRequest,
                                             isRestoringVault: Bool) -> Bool {
    guard isRestoringVault, entry.pinned else { return false }
    return entry.kind == .text || entry.ocrText != nil
  }

  /// Decides what a paste or copy of `entry` writes. `plainOnly` is the effective plain-text-only
  /// setting for this action (it skips images). Flagged entries, including images flagged through
  /// their recognised text, are always written as sensitive.
  public static func decide(_ entry: ClipboardEntry, request: PasteRequest, plainOnly: Bool,
                            isRestoringVault: Bool) -> PasteDecision {
    if isBlockedByVaultRestore(entry, request: request, isRestoringVault: isRestoringVault) {
      return .refuse(restoringVaultMessage)
    }
    let sensitive = PastePolicy.sensitivity(of: entry)
    switch (request, entry.kind) {
    case (.ocrText, _):
      guard let text = ocrText(of: entry) else { return .refuse(noOCRTextMessage) }
      return .deliver(.text(text), sensitive: sensitive)
    case (.entry, .text):
      guard let text = entry.text else { return .none }
      return .deliver(.text(text), sensitive: sensitive)
    case (.entry, .image):
      guard let png = entry.imagePNG else { return .none }
      if plainOnly {
        return .refuse(ocrText(of: entry) == nil ? plainOnlyImageMessage : plainOnlyImageWithTextMessage)
      }
      return .deliver(.image(png), sensitive: sensitive)
    }
  }
}

/// Vault and history-file state shown in Settings.
public struct VaultStatus: Equatable, Sendable {
  public var isReadOnly: Bool
  public var isRestoring: Bool
  public var unsavedPinCount: Int

  public init(isReadOnly: Bool = false, isRestoring: Bool = false, unsavedPinCount: Int = 0) {
    self.isReadOnly = isReadOnly; self.isRestoring = isRestoring; self.unsavedPinCount = unsavedPinCount
  }

  public init(_ store: HistoryStore) {
    self.init(isReadOnly: store.isReadOnly, isRestoring: store.isRestoringVault,
              unsavedPinCount: store.pinsNotSavedToVault.count)
  }

  public var isHealthy: Bool { !isReadOnly && !isRestoring && unsavedPinCount == 0 }
  /// Retry only helps pins the vault refused; a read-only history is never written this session.
  public var canRetry: Bool { unsavedPinCount > 0 }

  /// User-facing lines, most serious first. Empty when all is well.
  public var messages: [String] {
    var out: [String] = []
    if isReadOnly {
      out.append("The history file could not be read, so CopyHistory is running read-only: new items are kept in memory only and nothing is saved until the file is readable and the app is relaunched.")
    }
    if unsavedPinCount > 0 {
      let pins = unsavedPinCount == 1 ? "1 pinned sensitive item was" : "\(unsavedPinCount) pinned sensitive items were"
      out.append("\(pins) not saved to the Keychain. Until saved, the exact text lives in memory only and is lost on quit (the saved copy is masked).")
    }
    if isRestoring {
      out.append("Unlocking pinned sensitive items from the Keychain…")
    }
    return out
  }
}
