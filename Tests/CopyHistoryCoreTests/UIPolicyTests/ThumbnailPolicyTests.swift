import Foundation
import Testing
@testable import CopyHistoryCore

// Review R-L7: a flagged or never-scanned image does not show its pixels as a row thumbnail.

@Suite struct ThumbnailPolicyTests {
  private let png = Data([0x89, 0x50, 0x4E, 0x47])
  private var clean: ClipboardEntry { ClipboardEntry(kind: .image, imagePNG: png) }
  private var flagged: ClipboardEntry {
    ClipboardEntry(kind: .image, imagePNG: png, findings: [SecretFinding(category: .openAIKey, range: 0..<3)],
                   ocrText: "sk-…")
  }

  @Test func cleanScannedImageShowsItsThumbnail() {
    #expect(PopupPolicy.showsThumbnail(of: clean, unscanned: false))
    #expect(PopupPolicy.hiddenThumbnailHelp(for: clean, unscanned: false) == nil)
  }

  @Test func flaggedImageIsHidden() {
    #expect(!PopupPolicy.showsThumbnail(of: flagged, unscanned: false))
    #expect(PopupPolicy.hiddenThumbnailHelp(for: flagged, unscanned: false) == PopupPolicy.hiddenFlaggedThumbnailHelp)
    #expect(PopupPolicy.hiddenThumbnailHelp(for: flagged, unscanned: true) == PopupPolicy.hiddenFlaggedThumbnailHelp)
  }

  @Test func unscannedImageIsHidden() {
    #expect(!PopupPolicy.showsThumbnail(of: clean, unscanned: true))
    #expect(PopupPolicy.hiddenThumbnailHelp(for: clean, unscanned: true) == PopupPolicy.hiddenUnscannedThumbnailHelp)
  }

  @Test func textRowsHaveNoThumbnail() {
    let text = ClipboardEntry(kind: .text, text: "hello")
    #expect(!PopupPolicy.showsThumbnail(of: text, unscanned: false))
    #expect(PopupPolicy.hiddenThumbnailHelp(for: text, unscanned: true) == nil)
  }

  /// Driven by the store: hidden while the scan is pending, shown once a clean scan arrives.
  @Test func followsTheStoreScanState() {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    #expect(!PopupPolicy.showsThumbnail(of: e, unscanned: store.isUnscannedImage(e.id)))
    store.applyOCR(OCRUpdate(entryID: e.id, imagePNG: png, scanned: true, ocrText: nil))
    #expect(PopupPolicy.showsThumbnail(of: e, unscanned: store.isUnscannedImage(e.id)))
  }
}
