import AppKit
import SwiftUI

final class PopupPanel: NSPanel {
  var onResignKey: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
}

/// Owns the persistent panel. Created once at launch; `show()`/`hide()` only toggle visibility.
@MainActor
final class PopupController {
  let viewModel: PopupViewModel
  private let panel: PopupPanel
  private let pasteService: PasteService
  private var keyMonitor: Any?

  init(viewModel: PopupViewModel, pasteService: PasteService) {
    self.viewModel = viewModel
    self.pasteService = pasteService
    panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                       styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: PopupView(vm: viewModel, settings: viewModel.settings))
    panel.onResignKey = { [weak self] in self?.hide() }
    viewModel.onClose = { [weak self] in self?.hide() }
  }

  var isVisible: Bool { panel.isVisible }

  func toggle() { isVisible ? hide() : show() }

  func show() {
    // M1: capture before ordering the panel front. When we are already frontmost
    // (e.g. the Settings window was just used) there is no valid paste target, so
    // capture drops any stale target and the paste falls back to copy-only.
    pasteService.captureFrontmost()
    viewModel.prepareForShow()
    position()
    panel.orderFrontRegardless()
    panel.makeKey()
    installKeyMonitor()
  }

  func hide() {
    guard panel.isVisible else { return }
    removeKeyMonitor()
    panel.orderOut(nil)
    viewModel.didHide()  // cancels a running transform so it can't paste after dismissal
  }

  private func position() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = panel.frame.size
    panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2))
  }

  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let keyCode = event.keyCode
      let flags = event.modifierFlags
      let chars = event.charactersIgnoringModifiers
      let consumed = MainActor.assumeIsolated {
        guard let self, self.panel.isKeyWindow else { return false }
        // M9: while the search field holds uncommitted IME text, Return commits the
        // candidate and Escape/arrows drive the candidate window — let those reach the
        // field editor instead of pasting or closing. Command shortcuts still work.
        if !flags.contains(.command), self.isComposing { return false }
        return self.viewModel.handleKey(keyCode: keyCode, flags: flags, characters: chars)
      }
      return consumed ? nil : event
    }
  }

  /// True while the search field's input context holds uncommitted (marked) text.
  private var isComposing: Bool {
    (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
  }

  private func removeKeyMonitor() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
  }
}
