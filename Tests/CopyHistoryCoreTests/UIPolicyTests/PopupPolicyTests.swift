import Foundation
import Testing
@testable import CopyHistoryCore

@Suite struct PopupPolicyTests {
  static let fakeKey = "ghp_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE1234"  // fake fixture, not a real token
  static let png = Data([0x89, 0x50, 0x4E, 0x47])
  let detector = SecretDetector()

  func image(ocr: String?, flagged: Bool = false, pinned: Bool = false) -> ClipboardEntry {
    let findings = flagged ? (ocr.map { detector.scan($0) } ?? []) : []
    return ClipboardEntry(kind: .image, imagePNG: Self.png, pinned: pinned, findings: findings, ocrText: ocr)
  }

  // MARK: Snippets

  @Test func snippetShowsUnflaggedOCRTextOnOneLine() {
    let e = image(ocr: "Invoice 42\nTotal: $10")
    #expect(PopupPolicy.ocrSnippet(for: e, detector: detector) == "Invoice 42 ⏎ Total: $10")
  }

  @Test func noSnippetWithoutText() {
    #expect(PopupPolicy.ocrSnippet(for: image(ocr: nil), detector: detector) == nil)
    #expect(PopupPolicy.ocrSnippet(for: image(ocr: " \n\t"), detector: detector) == nil)
    let text = ClipboardEntry(kind: .text, text: "hello", ocrText: "stray")
    #expect(PopupPolicy.ocrSnippet(for: text, detector: detector) == nil)
  }

  @Test func flaggedSnippetIsMasked() throws {
    let e = image(ocr: "token: \(Self.fakeKey)", flagged: true)
    #expect(!e.findings.isEmpty)
    let snippet = try #require(PopupPolicy.ocrSnippet(for: e, detector: detector))
    #expect(!snippet.contains("FAKEFAKE"))
    #expect(snippet.contains("••"))
  }

  /// A secret straddling the snippet cut is masked up to the cut, never shown partially in clear.
  @Test func findingCutByTheSnippetPrefixIsStillMasked() throws {
    let lead = String(repeating: "a ", count: (PopupPolicy.ocrSnippetLength - 10) / 2)
    let e = image(ocr: lead + Self.fakeKey + " trailing", flagged: true)
    #expect(!e.findings.isEmpty)
    let snippet = try #require(PopupPolicy.ocrSnippet(for: e, detector: detector))
    #expect(!snippet.contains("FAKE"))
    #expect(snippet.hasSuffix("…"))
  }

  /// Fail closed: a flagged entry whose findings do not line up with its OCR text is still masked.
  @Test func misalignedFindingsStillMaskByRescanning() throws {
    var e = image(ocr: "key \(Self.fakeKey)")
    e.findings = [SecretFinding(category: .genericSecret, range: 900..<950)]
    let snippet = try #require(PopupPolicy.ocrSnippet(for: e, detector: detector))
    #expect(!snippet.contains("FAKEFAKE"))
  }

  @Test func hugeOCRTextIsBoundedInTheSnippet() throws {
    let e = image(ocr: String(repeating: "word ", count: 200_000))
    let snippet = try #require(PopupPolicy.ocrSnippet(for: e, detector: detector))
    #expect(snippet.count <= PopupPolicy.ocrSnippetLength + 1)
  }

  // MARK: ⇧⌘↩ (OCR text only)

  @Test func ocrPasteDeliversOnlyTheText() {
    let d = PopupPolicy.decide(image(ocr: "hello world"), request: .ocrText, plainOnly: false, isRestoringVault: false)
    #expect(d == .deliver(.text("hello world"), sensitive: nil))
  }

  @Test func flaggedOCRPasteIsSensitive() {
    let e = image(ocr: "token: \(Self.fakeKey)", flagged: true)
    let d = PopupPolicy.decide(e, request: .ocrText, plainOnly: true, isRestoringVault: false)
    #expect(d == .deliver(.text("token: \(Self.fakeKey)"), sensitive: true))
  }

  @Test func ocrPasteWithoutTextIsRefused() {
    let none = PopupPolicy.decide(image(ocr: nil), request: .ocrText, plainOnly: false, isRestoringVault: false)
    #expect(none == .refuse(PopupPolicy.noOCRTextMessage))
    let text = ClipboardEntry(kind: .text, text: "hello")
    #expect(PopupPolicy.decide(text, request: .ocrText, plainOnly: false, isRestoringVault: false)
            == .refuse(PopupPolicy.noOCRTextMessage))
  }

  // MARK: ↩ (the entry itself)

  @Test func plainReturnStillPastesTheImage() {
    let d = PopupPolicy.decide(image(ocr: "hello"), request: .entry, plainOnly: false, isRestoringVault: false)
    #expect(d == .deliver(.image(Self.png), sensitive: nil))
  }

  @Test func flaggedImageIsPastedAsSensitive() {
    let e = image(ocr: "token: \(Self.fakeKey)", flagged: true)
    #expect(PopupPolicy.decide(e, request: .entry, plainOnly: false, isRestoringVault: false)
            == .deliver(.image(Self.png), sensitive: true))
  }

  @Test func plainOnlySkipsImagesAndPointsAtOCRText() {
    #expect(PopupPolicy.decide(image(ocr: "hello"), request: .entry, plainOnly: true, isRestoringVault: false)
            == .refuse(PopupPolicy.plainOnlyImageWithTextMessage))
    #expect(PopupPolicy.decide(image(ocr: nil), request: .entry, plainOnly: true, isRestoringVault: false)
            == .refuse(PopupPolicy.plainOnlyImageMessage))
  }

  @Test func textEntriesKeepTheirSensitivity() {
    let flagged = ClipboardEntry(kind: .text, text: Self.fakeKey, findings: detector.scan(Self.fakeKey))
    #expect(PopupPolicy.decide(flagged, request: .entry, plainOnly: true, isRestoringVault: false)
            == .deliver(.text(Self.fakeKey), sensitive: true))
    let plain = ClipboardEntry(kind: .text, text: "hello")
    #expect(PopupPolicy.decide(plain, request: .entry, plainOnly: false, isRestoringVault: false)
            == .deliver(.text("hello"), sensitive: nil))
  }

  // MARK: Vault restore

  /// During the restore a vaulted pin holds its masked placeholder and no findings yet.
  @Test func pinnedTextIsRefusedWhileTheVaultRestores() {
    let placeholder = ClipboardEntry(kind: .text, text: "ghp_••••••••", pinned: true)
    #expect(PopupPolicy.decide(placeholder, request: .entry, plainOnly: false, isRestoringVault: true)
            == .refuse(PopupPolicy.restoringVaultMessage))
    #expect(PopupPolicy.isBlockedByVaultRestore(placeholder, request: .entry, isRestoringVault: true))
    #expect(PopupPolicy.decide(placeholder, request: .entry, plainOnly: false, isRestoringVault: false)
            == .deliver(.text("ghp_••••••••"), sensitive: nil))
  }

  @Test func unpinnedEntriesArePastableWhileRestoring() {
    let unpinned = ClipboardEntry(kind: .text, text: "hello")
    #expect(PopupPolicy.decide(unpinned, request: .entry, plainOnly: false, isRestoringVault: true)
            == .deliver(.text("hello"), sensitive: nil))
    #expect(PopupPolicy.decide(image(ocr: "hello"), request: .entry, plainOnly: false, isRestoringVault: true)
            == .deliver(.image(Self.png), sensitive: nil))
  }

  /// A pinned image flagged through its text loads with a masked `ocrText` and no findings until the
  /// restore re-flags it: its pixels must not be pasted unmarked meanwhile.
  @Test func pinnedImagesWithTextAreRefusedWhileRestoring() {
    let pinned = image(ocr: "token: ghp_••••••••", pinned: true)
    #expect(PopupPolicy.decide(pinned, request: .entry, plainOnly: false, isRestoringVault: true)
            == .refuse(PopupPolicy.restoringVaultMessage))
    #expect(PopupPolicy.decide(pinned, request: .ocrText, plainOnly: false, isRestoringVault: true)
            == .refuse(PopupPolicy.restoringVaultMessage))
    let noText = image(ocr: nil, pinned: true)
    #expect(PopupPolicy.decide(noText, request: .entry, plainOnly: false, isRestoringVault: true)
            == .deliver(.image(Self.png), sensitive: nil))
  }

  // MARK: Settings status

  @Test func vaultStatusMessages() {
    #expect(VaultStatus().isHealthy)
    #expect(VaultStatus().messages.isEmpty)
    let readOnly = VaultStatus(isReadOnly: true)
    #expect(!readOnly.isHealthy && !readOnly.canRetry)
    #expect(readOnly.messages.first?.contains("read-only") == true)
    let unsaved = VaultStatus(unsavedPinCount: 2)
    #expect(unsaved.canRetry)
    #expect(unsaved.messages == [unsaved.messages[0]] && unsaved.messages[0].hasPrefix("2 pinned"))
  }

  @Test func vaultStatusReadsTheStore() {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    #expect(!VaultStatus(store).isReadOnly)
    #expect(VaultStatus(store).unsavedPinCount == 0)
  }
}
