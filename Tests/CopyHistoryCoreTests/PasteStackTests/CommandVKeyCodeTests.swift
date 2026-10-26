import Foundation
import Testing
@testable import CopyHistoryCore

/// Review R-M4: the synthetic ⌘V uses the key that types "v" in the active layout.
@MainActor @Suite struct CommandVKeyCodeTests {
  private func keyCode(_ sourceID: String) throws -> UInt16? {
    KeyboardLayoutCharacter.commandVKeyCode(layout: try #require(KeyboardLayoutCharacter.layoutData(inputSourceID: sourceID)))
  }

  @Test func qwertyIsKeycode9() throws {
    #expect(try keyCode("com.apple.keylayout.US") == 9)
  }

  @Test func dvorakIsKeycode47() throws {
    #expect(try keyCode("com.apple.keylayout.Dvorak") == 47)
  }

  @Test func layoutsThatKeepCommandVOnKeycode9() throws {
    #expect(try keyCode("com.apple.keylayout.DVORAK-QWERTYCMD") == 9)  // switches to QWERTY under ⌘
    #expect(try keyCode("com.apple.keylayout.Russian") == 9)           // Latin key under ⌘
  }

  /// What is posted is classified as ⌘V by the Paste Stack's tap in the same layout.
  @Test func postedKeyIsRecognisedAsCommandV() throws {
    let layout = try #require(KeyboardLayoutCharacter.layoutData(inputSourceID: "com.apple.keylayout.Dvorak"))
    let code = try #require(KeyboardLayoutCharacter.commandVKeyCode(layout: layout))
    let press = PasteStackKeyPress(keyCode: code, modifiers: .command,
                                   character: KeyboardLayoutCharacter.character(forKeyCode: code, layout: layout))
    #expect(press.action == .paste)
  }

  @Test func unusableLayoutDataGivesNil() {
    #expect(KeyboardLayoutCharacter.commandVKeyCode(layout: Data()) == nil)
  }

  @Test func currentLayoutResolvesToAKeyThatTypesV() throws {
    let code = KeyboardLayoutCharacter.currentCommandVKeyCode()
    #expect(code <= 127)
    if let ch = KeyboardLayoutCharacter.currentCommandCharacter(forKeyCode: code) {
      #expect(ch.lowercased() == "v")
    }
  }
}
