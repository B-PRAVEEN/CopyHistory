import Foundation
import Testing
@testable import CopyHistoryCore

// Review round 2, F2-L6: the popup's unscanned-paste follow-ups (stay open with a note on copy-only,
// HUD after an auto-paste, entry-gone handling) now live in `PopupPolicy`, so they are testable; and
// the F2-L2 status line.

@Suite struct PopupFollowUpTests {
  private static let png = Data([0x89, 0x50, 0x4E, 0x47])

  @Test func copyOnlyStaysOpenOnlyForAnUnscannedImage() {
    #expect(PopupPolicy.followUpAfterCopy(unscanned: true) == .stay(PopupPolicy.unscannedImageMessage))
    #expect(PopupPolicy.followUpAfterCopy(unscanned: false) == .close)
  }

  @Test func withoutATargetTheCopyIsExplained() {
    #expect(PopupPolicy.followUpWithoutTarget(unscanned: false) == .stay(PopupPolicy.copiedWithoutTargetMessage))
    #expect(PopupPolicy.followUpWithoutTarget(unscanned: true) == .stay(PopupPolicy.unscannedImageMessage))
  }

  @Test func afterAPasteOnlyAnUnscannedImageGetsAHUD() {
    #expect(PopupPolicy.followUpAfterPaste(route: .paste, unscanned: true)
            == .closeWithHUD(PopupPolicy.unscannedImagePastedMessage, seconds: 3))
    // Copy-only because Accessibility is missing: the user pastes by hand within the longer clear.
    #expect(PopupPolicy.followUpAfterPaste(route: .copyOnly, unscanned: true)
            == .closeWithHUD(PopupPolicy.unscannedImageMessage, seconds: 4))
    #expect(PopupPolicy.followUpAfterPaste(route: .paste, unscanned: false) == .close)
    #expect(PopupPolicy.followUpAfterPaste(route: .copyOnly, unscanned: false) == .close)
  }

  @Test func actionTargetIsTheLiveEntry() {
    let snapshot = ClipboardEntry(kind: .image, imagePNG: Self.png)
    var live = snapshot
    live.findings = [SecretFinding(category: .genericSecret, range: 0..<1)]
    #expect(PopupPolicy.actionTarget(snapshot: snapshot, storeKnowsScans: true, live: (live, false))
            == .entry(live, unscanned: false))
    #expect(PopupPolicy.actionTarget(snapshot: snapshot, storeKnowsScans: true, live: nil) == .gone)
  }

  /// A store that cannot say whether an image was scanned: every image is unscanned, text is not.
  @Test func otherStoresFailClosedForImages() {
    let image = ClipboardEntry(kind: .image, imagePNG: Self.png)
    let text = ClipboardEntry(kind: .text, text: "hello")
    #expect(PopupPolicy.actionTarget(snapshot: image, storeKnowsScans: false, live: nil) == .entry(image, unscanned: true))
    #expect(PopupPolicy.actionTarget(snapshot: text, storeKnowsScans: false, live: nil) == .entry(text, unscanned: false))
  }

  /// End to end with a real store: an entry removed after the list was loaded is gone.
  @Test func removedEntryIsGone() {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let e = store.add(ClipboardEntry(kind: .text, text: "soon gone"))
    store.remove(e.id)
    #expect(PopupPolicy.actionTarget(snapshot: e, storeKnowsScans: true, live: store.pasteState(of: e.id)) == .gone)
  }
}

@Suite struct UnsavedFlaggedImageStatusTests {
  @Test func countsAndMessages() {
    #expect(VaultStatus().unsavedFlaggedImageCount == 0)
    let one = VaultStatus(unsavedFlaggedImageCount: 1)
    #expect(!one.isHealthy)
    #expect(!one.canRetry)  // the Keychain retry button is not for this; the next write retries
    #expect(one.messages.count == 1)
    #expect(one.messages[0].hasPrefix("1 pinned image with sensitive text was not saved"))
    #expect(VaultStatus(unsavedFlaggedImageCount: 3).messages[0].hasPrefix("3 pinned images with sensitive text were not saved"))
  }

  @Test func healthyStoreReportsNone() {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    #expect(VaultStatus(store).unsavedFlaggedImageCount == 0)
    #expect(store.flaggedPinsNotSaved.isEmpty)
  }
}
