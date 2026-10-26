import Foundation

/// What a key press in the popup asks for.
public enum PopupCommand: Equatable, Sendable {
  case close
  case leaveTransforms
  case move(Int)
  case applyTransform
  case copyOnly
  case paste(flipPlain: Bool)
  case pasteOCRText
  case openTransforms
  case togglePin
  case delete
  case pasteItem(index: Int, flipPlain: Bool)
}

/// The popup's key table, kept out of AppKit so it can be tested.
public enum PopupKeyMap {
  public enum Mode: Equatable, Sendable { case list, transforms }
  /// Only ⌘⇧⌥⌃; callers drop caps lock, fn and device bits.
  public typealias Modifiers = PasteStackKeyPress.Modifiers

  /// The command for a key press, or nil when the popup does not consume it.
  public static func command(keyCode: UInt16, modifiers mods: Modifiers, characters: String?,
                             mode: Mode) -> PopupCommand? {
    let cmd = mods == .command
    switch Int(keyCode) {
    case 53:  // Escape
      return mode == .transforms ? .leaveTransforms : .close
    case 125:  // Down
      return .move(1)
    case 126:  // Up
      return .move(-1)
    case 36, 76:  // Return / Enter
      if mode == .transforms { return .applyTransform }
      if mods == .option { return .copyOnly }
      if mods.isEmpty { return .paste(flipPlain: false) }
      if mods == .shift { return .paste(flipPlain: true) }
      if mods == [.command, .shift] { return .pasteOCRText }
      return nil
    case 48 where mods.isEmpty:  // Tab
      return mode == .transforms ? .leaveTransforms : .openTransforms
    case 35 where cmd && mode == .list:  // Cmd+P
      return .togglePin
    case 51 where cmd && mode == .list:  // Cmd+Delete
      return .delete
    default:
      break
    }
    if mode == .list, mods == .command || mods == [.command, .option],
       let ch = characters, let n = Int(ch), (1...9).contains(n) {
      return .pasteItem(index: n - 1, flipPlain: mods.contains(.option))
    }
    return nil
  }
}
