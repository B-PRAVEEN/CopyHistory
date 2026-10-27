import AppKit
import Combine
import CopyHistoryCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var services: AppServices!
  private var settings: AppSettings!
  private var updates: UpdateController!
  private var popup: PopupController!
  private var hotKey: GlobalHotKey?
  private var activeHotKeySpec: HotKeySpec?
  private var statusItem: NSStatusItem!
  private var settingsWindow: NSWindow?
  private var expiryTimer: Timer?
  private var updateItems: [NSMenuItem] = []
  private var updateObserver: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    services = AppServices.make()
    settings = AppSettings()
    updates = UpdateController(settings: settings)
    let pasteService = PasteService()
    let viewModel = PopupViewModel(services: services, settings: settings, pasteService: pasteService)
    popup = PopupController(viewModel: viewModel, pasteService: pasteService)
    buildMainMenu()
    buildStatusItem()
    updateObserver = updates.$available.sink { [weak self] available in
      MainActor.assumeIsolated { self?.showUpdate(available?.version) }
    }
    installHotKey()
    // @MainActor function values are Sendable, so the observer block can hold one safely.
    let reinstall: @MainActor () -> Void = { [weak self] in self?.reinstallHotKeyIfChanged() }
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { reinstall() } }
    startExpiryTimer()
    services.start()
    services.pasteStack.registerAndReport()
    services.pasteStack.onChange = { [weak self] in self?.updateStatusBadge() }
  }

  // MARK: Hotkey (L1)

  private func installHotKey() {
    let key = GlobalHotKey.fromPreferences { [weak self] in
      guard !GlobalHotKey.isRecording else { return }
      self?.togglePopup()
    }
    hotKey = key
    activeHotKeySpec = HotKeyPreferences.current()
    if let message = key.installFailureMessage() {
      let alert = NSAlert()
      alert.messageText = "CopyHistory shortcut unavailable"
      alert.informativeText = message
      alert.alertStyle = .warning
      alert.runModal()
    }
  }

  private func reinstallHotKeyIfChanged() {
    let spec = HotKeyPreferences.current()
    guard spec != activeHotKeySpec else { return }
    installHotKey()  // the old instance's deinit unregisters its Carbon handler
  }

  private func togglePopup() {
    // M1: never leave Settings visible under the popup; a misdirected ⌘V could
    // otherwise land in one of its text fields.
    if !popup.isVisible { settingsWindow?.orderOut(nil) }
    popup.toggle()
  }

  // MARK: Expiry (L5)

  /// Expiry otherwise runs only when the popup reloads, so flagged items would stay
  /// visible and pasteable while the popup is open, and their plaintext would linger
  /// in history.json until the next summon — even across a quit.
  private func startExpiryTimer() {
    let expire: @MainActor () -> Void = { [weak self] in
      guard let self else { return }
      self.services.store.removeExpired(now: Date())
      if self.popup.isVisible { self.popup.viewModel.reloadKeepingSelection() }
    }
    let timer = Timer(timeInterval: 60, repeats: true) { _ in
      MainActor.assumeIsolated { expire() }
    }
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }

  // MARK: Menus

  /// Shows the Paste Stack queue length next to the menu bar icon while stack mode is on.
  private func updateStatusBadge() {
    let stack = services.pasteStack
    statusItem.button?.title = stack.isActive ? " \(stack.count)" : ""
  }

  private func buildStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "CopyHistory")
    let menu = NSMenu()
    // Hidden until an update check finds a newer release.
    let update = NSMenuItem(title: "", action: #selector(openReleasePage), keyEquivalent: "")
    update.target = self
    let hint = NSMenuItem(title: UpdateController.upgradeHint, action: nil, keyEquivalent: "")
    hint.isEnabled = false
    updateItems = [update, hint, .separator()]
    for item in updateItems {
      item.isHidden = true
      menu.addItem(item)
    }
    menu.addItem(withTitle: "Show History  ⌥V", action: #selector(showHistory), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Clear Unpinned", action: #selector(clearUnpinned), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit CopyHistory", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
  }

  private func showUpdate(_ version: ReleaseVersion?) {
    if let version { updateItems.first?.title = "Update available: v\(version)" }
    for item in updateItems { item.isHidden = version == nil }
  }

  @objc private func openReleasePage() { updates.openReleasePage() }

  /// Accessory apps have no visible menu bar, but an Edit menu is still needed for ⌘C/⌘V/⌘A in text fields.
  private func buildMainMenu() {
    let main = NSMenu()
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
  }

  @objc private func showHistory() {
    settingsWindow?.orderOut(nil)  // M1: keep a misdirected ⌘V out of Settings fields
    popup.show()
  }

  @objc private func clearUnpinned() {
    services.store.clearUnpinned()
    popup.viewModel.reload(resetSelection: true)
  }

  @objc private func showSettings() {
    popup.hide()
    if settingsWindow == nil {
      let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, updates: updates)))
      window.title = "CopyHistory Settings"
      window.styleMask = [.titled, .closable]
      window.isReleasedWhenClosed = false
      settingsWindow = window
    }
    settingsWindow?.center()
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)
  }
}
