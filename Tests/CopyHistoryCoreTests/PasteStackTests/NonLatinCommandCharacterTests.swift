import Foundation
import Testing
@testable import CopyHistoryCore

// Review R-L1: a layout whose ⌘ character is not Latin (some third-party Cyrillic, Greek or Hebrew
// layouts type "м" for ⌘V) must not stop ⌘V detection.

@Suite struct NonLatinCommandCharacterTests {
  @Test func asciiPrimaryIsUsedAsIs() {
    var askedFallback = false
    #expect(KeyboardLayoutCharacter.commandCharacter(primary: "v", asciiCapable: { askedFallback = true; return "x" }) == "v")
    #expect(!askedFallback)
  }

  @Test func nonASCIIPrimaryFallsBackToTheASCIICapableLayout() {
    #expect(KeyboardLayoutCharacter.commandCharacter(primary: "м", asciiCapable: { "v" }) == "v")
    #expect(KeyboardLayoutCharacter.commandCharacter(primary: nil, asciiCapable: { "v" }) == "v")
  }

  @Test func noASCIICharacterAnywhereMeansUnknown() {
    #expect(KeyboardLayoutCharacter.commandCharacter(primary: "м", asciiCapable: { "ש" }) == nil)
    #expect(KeyboardLayoutCharacter.commandCharacter(primary: "м", asciiCapable: { nil }) == nil)
  }

  /// A non-ASCII character says nothing about ⌘V, so the QWERTY keycode decides and the stack advances.
  @Test func nonASCIICharacterFallsBackToTheKeycode() {
    #expect(PasteStackKeyPress(keyCode: 9, modifiers: .command, character: "м").action == .paste)
    #expect(PasteStackKeyPress(keyCode: 9, modifiers: .command, character: "м", fromOwnProcess: true).action == .ownPaste)
    #expect(PasteStackKeyPress(keyCode: 47, modifiers: .command, character: "м").action == .ignore)
    // ASCII characters still decide: ⌘K on Dvorak (keycode 9) is not a paste.
    #expect(PasteStackKeyPress(keyCode: 9, modifiers: .command, character: "k").action == .ignore)
  }

  @MainActor @Test func currentLayoutGivesASCIIOrNothing() {
    for keyCode: UInt16 in [0, 9, 11, 47] {
      if let ch = KeyboardLayoutCharacter.currentCommandCharacter(forKeyCode: keyCode) {
        #expect(KeyboardLayoutCharacter.isASCII(ch))
      }
    }
  }
}
