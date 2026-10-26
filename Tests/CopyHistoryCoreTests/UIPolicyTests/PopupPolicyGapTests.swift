import Foundation
import Testing
@testable import CopyHistoryCore

/// Behaviour of `PopupPolicy` and `VaultStatus` not pinned down by `PopupPolicyTests`.
@Suite struct PopupPolicyGapTests {
  static let png = Data([0x89, 0x50, 0x4E, 0x47])

  // MARK: oneLine

  @Test func oneLineLeavesSingleLineTextAlone() {
    #expect(PopupPolicy.oneLine("hello world") == "hello world")
    #expect(PopupPolicy.oneLine("") == "")
  }

  @Test func oneLineJoinsLinesWithAMarker() {
    #expect(PopupPolicy.oneLine("a\nb\nc") == "a ⏎ b ⏎ c")
    // CRLF is one Character, so it is one break, not two.
    #expect(PopupPolicy.oneLine("a\r\nb") == "a ⏎ b")
    #expect(PopupPolicy.oneLine("a\rb") == "a ⏎ b")
    #expect(PopupPolicy.oneLine("a\u{2028}b") == "a ⏎ b")  // Unicode line separator
  }

  /// Blank lines and leading/trailing breaks produce no empty segments.
  @Test func oneLineCollapsesBlankLines() {
    #expect(PopupPolicy.oneLine("a\n\n\nb") == "a ⏎ b")
    #expect(PopupPolicy.oneLine("\nfirst\n") == "first")
    #expect(PopupPolicy.oneLine("\n\n") == "")
  }

  @Test func oneLineKeepsOtherWhitespace() {
    #expect(PopupPolicy.oneLine("  a\tb  \n c") == "  a\tb   ⏎  c")
  }

  // MARK: Decisions without data

  @Test func entriesWithoutDataDecideNone() {
    let noText = ClipboardEntry(kind: .text, text: nil)
    #expect(PopupPolicy.decide(noText, request: .entry, plainOnly: false, isRestoringVault: false) == .none)
    let noImage = ClipboardEntry(kind: .image, imagePNG: nil)
    #expect(PopupPolicy.decide(noImage, request: .entry, plainOnly: false, isRestoringVault: false) == .none)
    // No data wins over the plain-text-only refusal: there is nothing to skip.
    #expect(PopupPolicy.decide(noImage, request: .entry, plainOnly: true, isRestoringVault: false) == .none)
  }

  @Test func whitespaceOnlyOCRTextIsRefusedAsNoText() {
    let e = ClipboardEntry(kind: .image, imagePNG: Self.png, ocrText: " \n\t ")
    #expect(PopupPolicy.decide(e, request: .ocrText, plainOnly: false, isRestoringVault: false)
            == .refuse(PopupPolicy.noOCRTextMessage))
    #expect(PopupPolicy.decide(e, request: .entry, plainOnly: true, isRestoringVault: false)
            == .refuse(PopupPolicy.plainOnlyImageMessage))
  }

  // MARK: Vault restore

  @Test(arguments: [PasteRequest.entry, .ocrText])
  func restoreBlocksOnlyPinnedTextAndPinnedImagesWithText(request: PasteRequest) {
    let pinnedText = ClipboardEntry(kind: .text, text: "x", pinned: true)
    let unpinnedText = ClipboardEntry(kind: .text, text: "x")
    let pinnedImageWithText = ClipboardEntry(kind: .image, imagePNG: Self.png, pinned: true, ocrText: "x")
    let pinnedImage = ClipboardEntry(kind: .image, imagePNG: Self.png, pinned: true)
    let blocked = { (e: ClipboardEntry, restoring: Bool) in
      PopupPolicy.isBlockedByVaultRestore(e, request: request, isRestoringVault: restoring)
    }
    #expect(blocked(pinnedText, true))
    #expect(blocked(pinnedImageWithText, true))
    #expect(!blocked(unpinnedText, true))
    #expect(!blocked(pinnedImage, true))
    for e in [pinnedText, unpinnedText, pinnedImageWithText, pinnedImage] { #expect(!blocked(e, false)) }
  }

  /// The restore refusal comes first: plain-text-only must not leak a different message for a pin.
  @Test func restoreRefusalTakesPrecedenceOverPlainOnly() {
    let pin = ClipboardEntry(kind: .image, imagePNG: Self.png, pinned: true, ocrText: "x")
    #expect(PopupPolicy.decide(pin, request: .entry, plainOnly: true, isRestoringVault: true)
            == .refuse(PopupPolicy.restoringVaultMessage))
  }

  // MARK: VaultStatus.isRestoring

  @Test func restoringIsNotHealthyAndCannotBeRetried() {
    let s = VaultStatus(isRestoring: true)
    #expect(!s.isHealthy)
    #expect(!s.canRetry)
    #expect(s.messages.count == 1)
    #expect(s.messages[0].hasPrefix("Unlocking pinned sensitive items"))
  }

  @Test func messagesAreOrderedMostSeriousFirst() {
    let s = VaultStatus(isReadOnly: true, isRestoring: true, unsavedPinCount: 1)
    #expect(s.messages.count == 3)
    #expect(s.messages[0].contains("read-only"))
    #expect(s.messages[1].hasPrefix("1 pinned sensitive item was"))
    #expect(s.messages[2].hasPrefix("Unlocking"))
  }
}
