import Carbon.HIToolbox
import Foundation

/// Which character a physical key types in a keyboard layout, so ⌘V is recognised by what it types
/// rather than by QWERTY keycode 9 (on Dvorak keycode 9 types "k"). Translation runs with ⌘ held, so
/// layouts that switch to QWERTY under ⌘ ("Dvorak - QWERTY ⌘") give the ⌘ character.
public enum KeyboardLayoutCharacter {
  /// The character `keyCode` types in `layout` (the input source's 'uchr' data), or nil.
  public static func character(forKeyCode keyCode: UInt16, commandDown: Bool = true, layout: Data,
                               keyboardType: UInt32 = UInt32(LMGetKbdType())) -> String? {
    let modifierState: UInt32 = commandDown ? UInt32((cmdKey >> 8) & 0xFF) : 0
    var deadKeyState: UInt32 = 0
    var length = 0
    var chars = [UniChar](repeating: 0, count: 4)
    let status = layout.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return OSStatus(paramErr) }
      return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
                            UInt16(kUCKeyActionDown), modifierState, keyboardType,
                            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                            chars.count, &length, &chars)
    }
    guard status == noErr, length > 0 else { return nil }
    return String(utf16CodeUnits: chars, count: length)
  }

  /// The character `keyCode` types with ⌘ in the active layout. Input methods without layout data
  /// (Japanese, Chinese, …) use the ASCII-capable layout macOS falls back to for shortcuts, and so
  /// does a layout whose ⌘ character is not ASCII (e.g. "м" in some third-party Cyrillic layouts),
  /// as AppKit does for key equivalents. Call on the main thread (Text Input Sources requirement).
  public static func currentCommandCharacter(forKeyCode keyCode: UInt16) -> String? {
    commandCharacter(primary: currentLayoutData().flatMap { character(forKeyCode: keyCode, layout: $0) },
                     asciiCapable: { asciiCapableLayoutData().flatMap { character(forKeyCode: keyCode, layout: $0) } })
  }

  /// `primary` if it is ASCII, else the ASCII-capable layout's character if that is, else nil (the
  /// caller then falls back to the QWERTY keycode).
  static func commandCharacter(primary: String?, asciiCapable: () -> String?) -> String? {
    if let primary, isASCII(primary) { return primary }
    if let ascii = asciiCapable(), isASCII(ascii) { return ascii }
    return nil
  }

  static func isASCII(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy(\.isASCII) }

  /// The keycode that types "v" with ⌘ in `layout` (9 on QWERTY, 47 on Dvorak), or nil. Keycode 9
  /// is tried first, so layouts that keep ⌘V there are never moved to a duplicate key.
  public static func commandVKeyCode(layout: Data, keyboardType: UInt32 = UInt32(LMGetKbdType())) -> UInt16? {
    let isV = { (keyCode: UInt16) in
      character(forKeyCode: keyCode, layout: layout, keyboardType: keyboardType)?.lowercased() == "v"
    }
    if isV(PasteStackKeyPress.vKeyCode) { return PasteStackKeyPress.vKeyCode }
    return (0...127).first(where: isV)
  }

  /// The keycode to post for a synthetic ⌘V in the active layout, so the target app reads "v" (and
  /// the Paste Stack's tap, which classifies by the same layout, sees ⌘V). Falls back to keycode 9.
  /// Call on the main thread (Text Input Sources requirement).
  public static func currentCommandVKeyCode() -> UInt16 {
    currentLayoutData().flatMap { commandVKeyCode(layout: $0) } ?? PasteStackKeyPress.vKeyCode
  }

  static func currentLayoutData() -> Data? {
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
       let data = layoutData(of: source) {
      return data
    }
    return asciiCapableLayoutData()
  }

  static func asciiCapableLayoutData() -> Data? {
    TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap { layoutData(of: $0.takeRetainedValue()) }
  }

  /// Layout data of an installed input source, e.g. "com.apple.keylayout.Dvorak"; nil if absent.
  public static func layoutData(inputSourceID: String) -> Data? {
    let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
          let source = list.first else { return nil }
    return layoutData(of: source)
  }

  private static func layoutData(of source: TISInputSource) -> Data? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    return data.isEmpty ? nil : data
  }
}
