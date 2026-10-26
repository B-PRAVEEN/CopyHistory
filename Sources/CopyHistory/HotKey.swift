import AppKit
import Carbon.HIToolbox

/// A global shortcut: Carbon key code + modifiers plus a display string (e.g. "⇧⌘V").
struct HotKeySpec: Equatable, Sendable {
  var keyCode: UInt32
  var modifiers: UInt32
  var display: String
}

/// Loads/saves the global shortcut from UserDefaults (L1: the shortcut is configurable
/// so it need not steal ⇧⌘V system-wide). Plain UserDefaults access; safe from any thread.
enum HotKeyPreferences {
  private static let codeKey = "hotKeyCode"
  private static let modifiersKey = "hotKeyModifiers"
  private static let displayKey = "hotKeyDisplay"

  static let fallback = HotKeySpec(keyCode: UInt32(kVK_ANSI_V),
                                   modifiers: UInt32(cmdKey | shiftKey),
                                   display: "⇧⌘V")

  static func current(defaults: UserDefaults = .standard) -> HotKeySpec {
    guard let code = defaults.object(forKey: codeKey) as? Int,
          let mods = defaults.object(forKey: modifiersKey) as? Int
    else { return fallback }
    let display = defaults.string(forKey: displayKey) ?? fallback.display
    return HotKeySpec(keyCode: UInt32(code), modifiers: UInt32(mods), display: display)
  }

  static func save(_ spec: HotKeySpec, defaults: UserDefaults = .standard) {
    defaults.set(Int(spec.keyCode), forKey: codeKey)
    defaults.set(Int(spec.modifiers), forKey: modifiersKey)
    defaults.set(spec.display, forKey: displayKey)
  }

  /// Maps Cocoa modifiers to Carbon hotkey modifiers.
  static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    if flags.contains(.shift) { mods |= UInt32(shiftKey) }
    if flags.contains(.option) { mods |= UInt32(optionKey) }
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    return mods
  }

  /// A new shortcut must include Command or Control, otherwise it would steal plain typing.
  static func isValid(flags: NSEvent.ModifierFlags) -> Bool {
    flags.contains(.command) || flags.contains(.control)
  }

  static func displayString(characters: String?, flags: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
    var s = ""
    if flags.contains(.control) { s += "⌃" }
    if flags.contains(.option) { s += "⌥" }
    if flags.contains(.shift) { s += "⇧" }
    if flags.contains(.command) { s += "⌘" }
    if let ch = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !ch.isEmpty {
      s += ch
    } else {
      s += "key \(keyCode)"
    }
    return s
  }
}

/// Global hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed).
///
/// Each instance installs its own Carbon handler and fires only its own action for its own
/// hotkey ID, so creating a second instance can never double-toggle (L1).
@MainActor
final class GlobalHotKey {
  private static let signature = OSType(0x4348_4B59)  // 'CHKY'
  private static var nextID: UInt32 = 1

  /// Set while Settings is recording a replacement shortcut; the app ignores hotkey
  /// presses meanwhile so re-pressing the current shortcut doesn't toggle the popup.
  /// Main-thread confined.
  nonisolated(unsafe) static var isRecording = false

  private let action: (@MainActor () -> Void)
  private let hotKeyID: UInt32
  // Plain Carbon refs, main-thread confined; nonisolated so deinit can unregister them.
  nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
  nonisolated(unsafe) private var handlerRef: EventHandlerRef?
  /// Non-nil when registration failed (e.g. `eventHotKeyExistsErr` when another app
  /// already took the shortcut). Check after init and surface it — L1.
  private(set) var installError: OSStatus?

  init(keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
    self.action = action
    hotKeyID = Self.nextID
    Self.nextID += 1

    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    var installedHandler: EventHandlerRef?
    let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
      guard let event, let userData else { return OSStatus(eventNotHandledErr) }
      var pressedID = EventHotKeyID()
      let paramStatus = GetEventParameter(event,
                                          EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID),
                                          nil,
                                          MemoryLayout<EventHotKeyID>.size,
                                          nil,
                                          &pressedID)
      guard paramStatus == noErr else { return OSStatus(eventNotHandledErr) }
      let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
      let handled = MainActor.assumeIsolated { instance.fireIfMatches(pressedID) }
      return handled ? noErr : OSStatus(eventNotHandledErr)
    }, 1, &spec, selfPtr, &installedHandler)
    guard handlerStatus == noErr else {
      installError = handlerStatus
      return
    }
    handlerRef = installedHandler

    let carbonID = EventHotKeyID(signature: Self.signature, id: hotKeyID)
    var registeredRef: EventHotKeyRef?
    let hotKeyStatus = RegisterEventHotKey(keyCode, modifiers, carbonID,
                                            GetApplicationEventTarget(), 0, &registeredRef)
    guard hotKeyStatus == noErr else {
      installError = hotKeyStatus
      if let installedHandler { RemoveEventHandler(installedHandler) }
      handlerRef = nil
      return
    }
    hotKeyRef = registeredRef
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let handlerRef { RemoveEventHandler(handlerRef) }
  }

  /// Builds the hotkey from the user's configured shortcut (default ⇧⌘V).
  static func fromPreferences(action: @escaping @MainActor () -> Void) -> GlobalHotKey {
    let spec = HotKeyPreferences.current()
    return GlobalHotKey(keyCode: spec.keyCode, modifiers: spec.modifiers, action: action)
  }

  /// Human-readable failure for an alert, or nil when registration succeeded.
  func installFailureMessage() -> String? {
    guard let installError else { return nil }
    if installError == eventHotKeyExistsErr {
      return "The shortcut \(HotKeyPreferences.current().display) is already used by another application. Pick a different one in CopyHistory Settings."
    }
    return "Could not register the global shortcut (error \(installError))."
  }

  /// Carbon delivers every hotkey press to every installed handler, so verify the ID.
  /// Returns false for IDs this instance doesn't own so the handler can return
  /// `eventNotHandledErr` and let other handlers in the chain run (F16).
  private func fireIfMatches(_ pressedID: EventHotKeyID) -> Bool {
    guard pressedID.signature == Self.signature, pressedID.id == hotKeyID else { return false }
    action()
    return true
  }
}
