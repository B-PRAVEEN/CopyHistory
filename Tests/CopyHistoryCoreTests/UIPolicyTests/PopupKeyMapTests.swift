import Foundation
import Testing
@testable import CopyHistoryCore

// The popup's key table and paste-write routing, moved out of the app target (PopupViewModel,
// PasteService) unchanged. The expected table is the one `handleKey` implemented before the move.

@Suite struct PopupKeyMapTests {
  private typealias M = PopupKeyMap.Modifiers
  private func cmd(_ keyCode: UInt16, _ mods: M = [], _ chars: String? = nil,
                   _ mode: PopupKeyMap.Mode = .list) -> PopupCommand? {
    PopupKeyMap.command(keyCode: keyCode, modifiers: mods, characters: chars, mode: mode)
  }

  @Test func escape() {
    #expect(cmd(53) == .close)
    #expect(cmd(53, .command) == .close)
    #expect(cmd(53, [], nil, .transforms) == .leaveTransforms)
  }

  @Test func arrowsMoveWithAnyModifiers() {
    #expect(cmd(125) == .move(1))
    #expect(cmd(126) == .move(-1))
    #expect(cmd(125, [.command, .shift], nil, .transforms) == .move(1))
  }

  @Test(arguments: [UInt16(36), 76]) func returnAndEnter(key: UInt16) {
    #expect(cmd(key) == .paste(flipPlain: false))
    #expect(cmd(key, .shift) == .paste(flipPlain: true))
    #expect(cmd(key, .option) == .copyOnly)
    #expect(cmd(key, [.command, .shift]) == .pasteOCRText)
    #expect(cmd(key, .command) == nil)             // not consumed
    #expect(cmd(key, .control) == nil)
    #expect(cmd(key, [.option, .shift]) == nil)
    #expect(cmd(key, .command, nil, .transforms) == .applyTransform)  // any modifiers in the picker
  }

  @Test func tabOnlyWithoutModifiers() {
    #expect(cmd(48) == .openTransforms)
    #expect(cmd(48, [], nil, .transforms) == .leaveTransforms)
    #expect(cmd(48, .shift, "\t") == nil)
  }

  @Test func pinAndDeleteOnlyInTheList() {
    #expect(cmd(35, .command, "p") == .togglePin)
    #expect(cmd(51, .command) == .delete)
    #expect(cmd(35, .command, "p", .transforms) == nil)
    #expect(cmd(51, .command, nil, .transforms) == nil)
    #expect(cmd(35, [], "p") == nil)
    #expect(cmd(51, [.command, .shift]) == nil)
  }

  @Test func commandDigitsPasteByPosition() {
    #expect(cmd(18, .command, "1") == .pasteItem(index: 0, flipPlain: false))
    #expect(cmd(25, .command, "9") == .pasteItem(index: 8, flipPlain: false))
    #expect(cmd(18, [.command, .option], "1") == .pasteItem(index: 0, flipPlain: true))
    #expect(cmd(29, .command, "0") == nil)
    #expect(cmd(18, [], "1") == nil)
    #expect(cmd(18, [.command, .shift], "1") == nil)
    #expect(cmd(18, .command, "1", .transforms) == nil)
    #expect(cmd(18, .command, nil) == nil)
    #expect(cmd(0, .command, "a") == nil)
  }
}

@Suite struct PasteWriteRoutingTests {
  @Test func clearDelayFollowsTheRoute() {
    #expect(PastePolicy.clearAfter(.paste) == 2)
    #expect(PastePolicy.clearAfter(.copyOnly) == 30)
  }

  @Test func textPassesSensitivityThrough() {
    #expect(PastePolicy.writerSensitivity(for: .text("x"), sensitive: nil) == nil)  // the writer scans
    #expect(PastePolicy.writerSensitivity(for: .text("x"), sensitive: true) == true)
    #expect(PastePolicy.writerSensitivity(for: .text("x"), sensitive: false) == false)
  }

  @Test func imagesAreMarkedOnlyWhenKnownSensitive() {
    let png = Data([1])
    #expect(PastePolicy.writerSensitivity(for: .image(png), sensitive: true) == true)
    #expect(PastePolicy.writerSensitivity(for: .image(png), sensitive: nil) == false)
    #expect(PastePolicy.writerSensitivity(for: .image(png), sensitive: false) == false)
  }

  /// End to end with the popup's decision: an unscanned image is always written marked.
  @Test func unscannedImageDecisionIsWrittenMarked() {
    let e = ClipboardEntry(kind: .image, imagePNG: Data([1]))
    guard case .deliver(let content, let sensitive) = PopupPolicy.decide(e, request: .entry, plainOnly: false,
                                                                          isRestoringVault: false, unscanned: true)
    else { Issue.record("not delivered"); return }
    #expect(PastePolicy.writerSensitivity(for: content, sensitive: sensitive) == true)
  }
}
