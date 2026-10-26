import Foundation
import Testing
@testable import CopyHistoryCore

// Fake secrets only: none of these values is a real credential.
private let ocrSecret = "sk-proj-OCRFAKEOCRFAKEOCRFAKE1234"
private let png = Data([0x89, 0x50, 0x4E, 0x47])

/// Review R-M1: an image never checked for secrets is pasted from the popup as sensitive, decided
/// from the store at paste time rather than from the popup's snapshot.
@Suite struct UnscannedImagePasteTests {
  // MARK: PopupPolicy

  @Test func unscannedImageIsDeliveredAsSensitive() {
    let e = ClipboardEntry(kind: .image, imagePNG: png)
    #expect(PopupPolicy.decide(e, request: .entry, plainOnly: false, isRestoringVault: false, unscanned: true)
            == .deliver(.image(png), sensitive: true))
    // Scanned clean: unmarked, as before.
    #expect(PopupPolicy.decide(e, request: .entry, plainOnly: false, isRestoringVault: false, unscanned: false)
            == .deliver(.image(png), sensitive: nil))
  }

  @Test func recognisedTextOfAnUnscannedImageIsSensitive() {
    // E.g. a scan that ran out of text budget: some text, never fully checked.
    let e = ClipboardEntry(kind: .image, imagePNG: png, ocrText: "partial text")
    #expect(PopupPolicy.decide(e, request: .ocrText, plainOnly: false, isRestoringVault: false, unscanned: true)
            == .deliver(.text("partial text"), sensitive: true))
  }

  @Test func unscannedDoesNotOverrideRefusals() {
    let e = ClipboardEntry(kind: .image, imagePNG: png)
    #expect(PopupPolicy.decide(e, request: .entry, plainOnly: true, isRestoringVault: false, unscanned: true)
            == .refuse(PopupPolicy.plainOnlyImageMessage))
    #expect(PopupPolicy.decide(e, request: .ocrText, plainOnly: false, isRestoringVault: false, unscanned: true)
            == .refuse(PopupPolicy.noOCRTextMessage))
  }

  @Test func unscannedIsIgnoredForText() {
    let e = ClipboardEntry(kind: .text, text: "hello")
    #expect(PopupPolicy.decide(e, request: .entry, plainOnly: false, isRestoringVault: false, unscanned: true)
            == .deliver(.text("hello"), sensitive: nil))
  }

  // MARK: HistoryStore.pasteState

  @Test func pendingScanIsUnscanned() throws {
    let store = HistoryStore(fileURL: nil)
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    let state = try #require(store.pasteState(of: e.id))
    #expect(state.unscanned)
    #expect(state.entry.id == e.id)
  }

  @Test func imageAddedWithoutOCRIsUnscanned() throws {
    let store = HistoryStore(fileURL: nil)
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png))
    #expect(try #require(store.pasteState(of: e.id)).unscanned)
  }

  @Test func failedScanStaysUnscanned() throws {
    let store = HistoryStore(fileURL: nil)
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: e.id, imagePNG: png, scanned: false, ocrText: nil))
    #expect(try #require(store.pasteState(of: e.id)).unscanned)
  }

  @Test func cleanScanIsNotUnscanned() throws {
    let store = HistoryStore(fileURL: nil)
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: e.id, imagePNG: png, scanned: true, ocrText: "invoice"))
    let state = try #require(store.pasteState(of: e.id))
    #expect(!state.unscanned)
    #expect(PopupPolicy.decide(state.entry, request: .entry, plainOnly: false, isRestoringVault: false,
                               unscanned: state.unscanned) == .deliver(.image(png), sensitive: nil))
  }

  /// The popup listed the image before OCR flagged it; the paste must use the flagged state.
  @Test func staleSnapshotIsReplacedByTheFlaggedEntry() throws {
    let store = HistoryStore(fileURL: nil)
    let snapshot = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    let findings = [SecretFinding(category: .openAIKey, range: 0..<ocrSecret.count)]
    store.applyOCR(OCRUpdate(entryID: snapshot.id, imagePNG: png, scanned: true, ocrText: ocrSecret,
                             findings: findings, expiresAt: Date().addingTimeInterval(60)))
    #expect(snapshot.findings.isEmpty)
    let state = try #require(store.pasteState(of: snapshot.id))
    #expect(state.entry.findings == findings)
    #expect(!state.unscanned)  // flagged, which says sensitive on its own
    #expect(PopupPolicy.decide(state.entry, request: .entry, plainOnly: false, isRestoringVault: false,
                               unscanned: state.unscanned) == .deliver(.image(png), sensitive: true))
  }

  @Test func textIsNeverUnscanned() throws {
    let store = HistoryStore(fileURL: nil)
    let e = store.add(ClipboardEntry(kind: .text, text: "hello"))
    #expect(try #require(store.pasteState(of: e.id)).unscanned == false)
  }

  @Test func removedEntryHasNoPasteState() {
    let store = HistoryStore(fileURL: nil)
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png))
    store.remove(e.id)
    #expect(store.pasteState(of: e.id) == nil)
    #expect(store.pasteState(of: UUID()) == nil)
  }

  /// `pasteState` and `isUnscannedImage` agree.
  @Test func pasteStateMatchesIsUnscannedImage() throws {
    let store = HistoryStore(fileURL: nil)
    let pending = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    let clean = store.add(ClipboardEntry(kind: .image, imagePNG: Data([1, 2, 3])), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: clean.id, imagePNG: Data([1, 2, 3]), scanned: true, ocrText: nil))
    for id in [pending.id, clean.id] {
      #expect(try #require(store.pasteState(of: id)).unscanned == store.isUnscannedImage(id))
    }
  }
}
