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
  /// (Japanese, Chinese, …) use the ASCII-capable layout macOS falls back to for shortcuts.
  /// Call on the main thread (Text Input Sources requirement).
  public static func currentCommandCharacter(forKeyCode keyCode: UInt16) -> String? {
    guard let layout = currentLayoutData() else { return nil }
    return character(forKeyCode: keyCode, layout: layout)
  }

  static func currentLayoutData() -> Data? {
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
       let data = layoutData(of: source) {
      return data
    }
    return TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap { layoutData(of: $0.takeRetainedValue()) }
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
