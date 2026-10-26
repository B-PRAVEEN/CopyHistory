import AppKit
import Carbon.HIToolbox
import CoreGraphics
import CopyHistoryCore

/// Paste Stack (⌥⇧⌘C): copies made while the mode is on queue up, and each ⌘V pastes the next one.
///
/// Wiring (AppDelegate/AppServices):
/// - call `registerAndReport()` after launch (it tells the user when the shortcut is taken), or
///   `register(_:)` and pass a non-nil message to `reportShortcutProblem(_:)`;
/// - from the clipboard monitor callback, call `handleCopied(_:awaitingOCR:capturedChangeCount:)` for
///   every captured entry (it returns false when stack mode is off) and
///   `applyOCR(entryID:scanned:ocrText:findings:)` for every OCR update;
/// - observe `onChange` for the menu-bar badge (`isActive`, `count`).
///
/// The ⌘V monitor is a listen-only session `CGEventTap`, installed only while the mode is on. It
/// needs Input Monitoring, requested on first activation; without it the stack advances via ⌥⌘V,
/// a hotkey registered only while the mode is on.
@MainActor
final class PasteStackController {
  static let toggleHotKey = HotKeySpec(keyCode: UInt32(kVK_ANSI_C),
                                       modifiers: UInt32(optionKey | shiftKey | cmdKey), display: "⌥⇧⌘C")
  static let fallbackAdvanceHotKey = HotKeySpec(keyCode: UInt32(kVK_ANSI_V),
                                                modifiers: UInt32(optionKey | cmdKey), display: "⌥⌘V")
  private static let askedForInputMonitoringKey = "pasteStackAskedForInputMonitoring"
  /// The shortcut (display string) whose conflict has already been shown in an alert.
  private static let reportedShortcutConflictKey = "pasteStackReportedShortcutConflict"

  /// Called after every state change (mode on/off, queue changed).
  var onChange: (@MainActor () -> Void)?

  var isActive: Bool { engine.isActive }
  var count: Int { engine.count }

  private let engine: PasteStackEngine
  private let panel = PasteStackPanel()
  private let hud = PasteStackHUD()
  private var toggleKey: GlobalHotKey?
  /// The toggle shortcut in effect (shown in hints); `toggleHotKey` until `register(_:)` changes it.
  private(set) var toggleSpec = PasteStackController.toggleHotKey
  private var fallbackKey: GlobalHotKey?
  /// Set while the explanatory alert is up, so a second toggle cannot stack alerts.
  private var isPreparing = false

  init(writer: PasteStackWriting = PasteStackPasteboardWriter()) {
    engine = PasteStackEngine(writer: writer, keyMonitor: CommandVEventTap())
    engine.onEvent = { [weak self] event in self?.handle(event) }
  }

  /// Registers the toggle shortcut (default ⌥⇧⌘C), replacing any earlier registration. Returns a
  /// message for an alert when the shortcut is unavailable; the old shortcut is then gone too.
  @discardableResult
  func register(_ spec: HotKeySpec = PasteStackController.toggleHotKey) -> String? {
    toggleKey = nil  // unregister first, or re-registering the same combination fails
    let key = GlobalHotKey(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
      guard !GlobalHotKey.isRecording else { return }
      self?.toggle()
    }
    guard key.installError == nil else {
      return "The Paste Stack shortcut \(spec.display) is already used by another application."
    }
    toggleKey = key
    toggleSpec = spec
    return nil
  }

  /// `register(_:)`, then `reportShortcutProblem(_:)` for a failure. Returns the message, if any.
  @discardableResult
  func registerAndReport(_ spec: HotKeySpec = PasteStackController.toggleHotKey) -> String? {
    let problem = register(spec)
    if let problem { reportShortcutProblem(problem, shortcut: spec.display) }
    return problem
  }

  /// Tells the user the Paste Stack shortcut could not be registered: an alert the first time for a
  /// given shortcut, a brief HUD on later launches, so a lasting conflict does not nag at every start.
  func reportShortcutProblem(_ message: String, shortcut: String? = nil) {
    let key = shortcut ?? toggleSpec.display
    let defaults = UserDefaults.standard
    guard defaults.string(forKey: Self.reportedShortcutConflictKey) != key else {
      hud.show("\(message) Paste Stack is unavailable.", duration: 4)
      return
    }
    defaults.set(key, forKey: Self.reportedShortcutConflictKey)
    let alert = NSAlert()
    alert.messageText = "Paste Stack shortcut unavailable"
    alert.informativeText = """
      \(message)

      Paste Stack cannot be turned on until that application releases \(key). Quit or reconfigure it, \
      then relaunch CopyHistory.
      """
    alert.addButton(withTitle: "OK")
    NSApp.activate()
    alert.runModal()
  }

  /// Asks for Input Monitoring again (after "Use ⌥⌘V Instead" or a denial): the next activation shows
  /// the explanation, and System Settings opens at the Input Monitoring pane.
  func requestInputMonitoringAgain() {
    UserDefaults.standard.set(false, forKey: Self.askedForInputMonitoringKey)
    if !CGPreflightListenEventAccess(), !CGRequestListenEventAccess(),
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
      NSWorkspace.shared.open(url)
    }
  }

  /// Starts stack mode, or cancels it when it is on. Safe to call from a hotkey handler: the work
  /// runs in a later main-actor turn, so a handler is never unregistered while it is running.
  func toggle() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if self.engine.isActive { self.engine.cancel() } else { self.activate() }
    }
  }

  /// Offer a copy captured by the clipboard monitor. Returns true when it joined the stack.
  @discardableResult
  func handleCopied(_ entry: ClipboardEntry, awaitingOCR: Bool = false, capturedChangeCount: Int? = nil) -> Bool {
    guard engine.isActive else { return false }
    if engine.enqueue(entry, awaitingOCR: awaitingOCR, capturedChangeCount: capturedChangeCount) { return true }
    switch engine.lastRejection {
    case .full?:
      hud.show("Paste Stack is full (\(engine.stack.capacity) items): that copy was not added")
    case .tooLarge?:
      hud.show("Paste Stack is full (\(engine.stack.maxBytes / 1_000_000) MB): that copy was not added")
    case .empty?, .inactive?, nil:
      break
    }
    return false
  }

  /// Forward every OCR update from the clipboard monitor; ignored unless the entry is queued.
  func applyOCR(entryID: UUID, scanned: Bool, ocrText: String?, findings: [SecretFinding]) {
    engine.applyOCR(entryID: entryID, scanned: scanned, ocrText: ocrText, findings: findings)
  }

  // MARK: Activation

  private func activate() {
    guard !engine.isActive, !isPreparing else { return }
    isPreparing = true
    defer { isPreparing = false }
    engine.start(useKeyMonitor: prepareInputMonitoring())
  }

  /// Whether Input Monitoring is granted. The first time it is not, explains why it is needed and
  /// asks macOS for it; the alert takes focus once, so the previously frontmost app is reactivated.
  private func prepareInputMonitoring() -> Bool {
    if CGPreflightListenEventAccess() { return true }
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.askedForInputMonitoringKey) else { return false }
    defaults.set(true, forKey: Self.askedForInputMonitoringKey)

    let previous = NSWorkspace.shared.frontmostApplication
    let alert = NSAlert()
    alert.messageText = "Allow CopyHistory to see when you press ⌘V?"
    alert.informativeText = """
      Paste Stack advances to the next item each time you press ⌘V. To notice that keystroke, \
      CopyHistory needs Input Monitoring permission. It only listens while Paste Stack is on, only \
      reacts to ⌘V, and never records or sends what you type.

      Without it, press \(Self.fallbackAdvanceHotKey.display) after each paste to move to the next item.
      """
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Use \(Self.fallbackAdvanceHotKey.display) Instead")
    NSApp.activate()
    let response = alert.runModal()
    if let previous, previous.processIdentifier != NSRunningApplication.current.processIdentifier {
      previous.activate()
    }
    guard response == .alertFirstButtonReturn else { return false }
    // Shows the system prompt once; a grant made in System Settings often applies only after relaunch.
    return CGRequestListenEventAccess()
  }

  // MARK: Engine events

  private func handle(_ event: PasteStackEngine.Event) {
    switch event {
    case .started(let mode):
      if mode == .fallbackHotKey { installFallbackKey() }
      hud.show(mode == .commandV
        ? "Paste Stack on: copy items, then ⌘V pastes them in order"
        : "Paste Stack on without Input Monitoring: ⌘V pastes, \(Self.fallbackAdvanceHotKey.display) moves to the next item")
      refreshPanel()
    case .changed:
      refreshPanel()
    case .ended(let reason):
      fallbackKey = nil  // deinit unregisters; ⌥⌘V is free again system-wide
      panel.hide()
      hud.show(reason == .finished ? "Paste Stack finished" : "Paste Stack cancelled")
    }
    onChange?()
  }

  private func installFallbackKey() {
    let spec = Self.fallbackAdvanceHotKey
    let key = GlobalHotKey(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
      // Deferred: advancing past the last item ends the mode, which releases this very hotkey.
      Task { @MainActor [weak self] in self?.engine.advanceNow() }
    }
    fallbackKey = key.installError == nil ? key : nil
  }

  private func refreshPanel() {
    guard engine.isActive else { return }
    let hint: String
    if engine.advanceMode == .commandV {
      hint = "⌘V pastes the highlighted item · \(toggleSpec.display) stops"
    } else if fallbackKey != nil {
      hint = "⌘V pastes · \(Self.fallbackAdvanceHotKey.display) next item · \(toggleSpec.display) stops"
    } else {
      hint = "\(Self.fallbackAdvanceHotKey.display) is taken by another app, so the stack cannot advance · \(toggleSpec.display) stops"
    }
    panel.show(entries: engine.stack.items, hint: hint)
  }
}

/// Listen-only keyboard tap (session level) for ⌘V. Installed only while stack mode is on.
/// The callback runs on the main run loop and only classifies the key; the engine schedules any work.
@MainActor
final class CommandVEventTap: PasteKeyMonitoring {
  // CF objects, main-thread confined; nonisolated so deinit can tear them down.
  nonisolated(unsafe) private var port: CFMachPort?
  nonisolated(unsafe) private var source: CFRunLoopSource?
  private var onKey: (@MainActor (PasteStackKeyPress) -> Void)?
  /// Keycode of the last ⌘V press reported; its release is reported too (with whatever modifiers).
  private var pendingKeyUp: UInt16?

  /// The engine advances after the ⌘V key is released, not when it goes down.
  var reportsKeyUp: Bool { true }

  func start(onKey: @escaping @MainActor (PasteStackKeyPress) -> Void) -> Bool {
    stop()
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
    // Unretained: the controller owns this tap for the app's lifetime, and stop()/deinit remove it.
    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                       options: .listenOnly, eventsOfInterest: mask,
                                       callback: { _, type, event, userInfo in
                                         if let userInfo {
                                           let tap = Unmanaged<CommandVEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                                           MainActor.assumeIsolated { tap.received(type: type, event: event) }
                                         }
                                         return Unmanaged.passUnretained(event)
                                       },
                                       userInfo: userInfo)
    else { return false }  // Input Monitoring missing (or revoked by a re-sign)
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      CFMachPortInvalidate(port)
      return false
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    self.port = port
    self.source = source
    self.onKey = onKey
    return true
  }

  func stop() {
    onKey = nil
    pendingKeyUp = nil
    Self.tearDown(port: port, source: source)
    port = nil
    source = nil
  }

  deinit { Self.tearDown(port: port, source: source) }

  private nonisolated static func tearDown(port: CFMachPort?, source: CFRunLoopSource?) {
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
  }

  private func received(type: CGEventType, event: CGEvent) {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      // macOS disables a tap whose callback was slow or on secure input; turn it back on.
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
    case .keyDown:
      guard onKey != nil, let press = Self.keyPress(from: event), press.action != .ignore else { return }
      if press.action == .paste { pendingKeyUp = press.keyCode }
      // Deferred: work that ends the mode tears this tap down; never do that inside its callout.
      Task { @MainActor [weak self] in self?.onKey?(press) }
    case .keyUp:
      // Only the release of the reported ⌘V key, by keycode alone: ⌘ is often released first.
      let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
      guard onKey != nil, let pending = pendingKeyUp, keyCode == pending,
            event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
      pendingKeyUp = nil
      let release = PasteStackKeyPress(keyCode: keyCode, modifiers: [], isKeyUp: true)
      Task { @MainActor [weak self] in self?.onKey?(release) }
    default:
      break
    }
  }

  /// nil for anything but a plain ⌘ chord, before any layout lookup, so ordinary typing costs nothing.
  private static func keyPress(from event: CGEvent) -> PasteStackKeyPress? {
    let flags = event.flags
    guard flags.contains(.maskCommand),
          flags.intersection([.maskShift, .maskAlternate, .maskControl]).isEmpty else { return nil }
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
    // What the key types with ⌘ in the active layout: ⌘V is keycode 47 on Dvorak, 9 on QWERTY.
    let character = KeyboardLayoutCharacter.currentCommandCharacter(forKeyCode: keyCode)
    return PasteStackKeyPress(keyCode: keyCode, modifiers: .command, character: character,
                              isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                              fromOwnProcess: sourcePID == Int64(getpid()))
  }
}
