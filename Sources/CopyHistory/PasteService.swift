import AppKit
import ApplicationServices
import CopyHistoryCore

/// Writes to the pasteboard and (when Accessibility is granted) synthesizes Cmd+V in the app that
/// was frontmost before the popup appeared.
@MainActor
final class PasteService {
  /// Marker type added to every pasteboard write we make, so the clipboard monitor can skip them.
  static let internalType = NSPasteboard.PasteboardType(SecretPasteboardWriter.internalType)
  /// After an auto-paste, a secret only needs to survive until the target app has read it.
  static let secretClearAfterPaste: TimeInterval = 2
  /// After copy-only (or paste without Accessibility) the user pastes by hand, so allow longer.
  static let secretClearAfterCopy: TimeInterval = 30
  /// Posted on the main thread after a paste's synthetic ⌘V has been queued, so the Paste Stack
  /// can put its head back (review L1). Delivery to the target app is asynchronous: observers must
  /// wait past the target's paste before rewriting the pasteboard. Not posted for copy-only.
  static let didPasteNotification = Notification.Name("PasteService.didPaste")

  private var previousApp: NSRunningApplication?
  private let writer = SecretPasteboardWriter()

  /// Remembers the app to paste into. When CopyHistory itself is frontmost (e.g. Settings was just
  /// used) the target is cleared, never kept from an earlier summon, so pastes fall back to copy-only.
  func captureFrontmost() {
    let ownPID = NSRunningApplication.current.processIdentifier
    previousApp = PastePolicy.captureTarget(frontmost: NSWorkspace.shared.frontmostApplication) {
      $0.processIdentifier == ownPID
    }
  }

  /// Whether `paste` would paste rather than only copy (Accessibility is checked without prompting).
  var hasPasteTarget: Bool { previousApp?.isTerminated == false }

  /// Writes to the pasteboard. Secrets (`sensitive`, or detected by scanning the text when nil) are
  /// marked Concealed/Transient, kept off Universal Clipboard and cleared after `secretClearAfterCopy`.
  /// Images are only marked when `sensitive` is true (an image flagged through its recognised text).
  func copy(_ content: PasteContent, sensitive: Bool? = nil) {
    write(content, sensitive: sensitive, clearAfter: Self.secretClearAfterCopy)
  }

  /// Copies, then pastes into the previous app. Falls back to copy-only without Accessibility or
  /// without a paste target; returns the route taken.
  @discardableResult
  func paste(_ content: PasteContent, sensitive: Bool? = nil) -> PasteRoute {
    let target = hasPasteTarget ? previousApp : nil
    let route = PastePolicy.route(hasTarget: target != nil,
                                  accessibilityTrusted: target != nil && ensureAccessibility())
    guard route == .paste, let target else {
      write(content, sensitive: sensitive, clearAfter: Self.secretClearAfterCopy)
      return .copyOnly
    }
    write(content, sensitive: sensitive, clearAfter: Self.secretClearAfterPaste)
    if !target.isActive { target.activate() }
    Task { @MainActor in
      // Post ⌘V only once the target is frontmost; if activation did not happen (the user switched
      // elsewhere, the app quit), the content stays on the pasteboard and nothing is typed.
      try? await Task.sleep(for: .milliseconds(90))  // lets focus settle after the panel orders out
      for attempt in 0..<10 {
        if attempt > 0 { try? await Task.sleep(for: .milliseconds(50)) }
        if PastePolicy.mayPostPaste(targetPID: target.processIdentifier,
                                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) {
          Self.postCommandV()
          NotificationCenter.default.post(name: Self.didPasteNotification, object: self)
          return
        }
      }
    }
    return .paste
  }

  private func write(_ content: PasteContent, sensitive: Bool?, clearAfter: TimeInterval) {
    switch content {
    case .text(let s): writer.write(text: s, sensitive: sensitive, clearAfter: clearAfter)
    case .image(let d): writer.write(png: d, sensitive: sensitive == true, clearAfter: clearAfter)
    }
  }

  @discardableResult
  func ensureAccessibility(prompt: Bool = true) -> Bool {
    if AXIsProcessTrusted() { return true }
    guard prompt else { return false }
    // kAXTrustedCheckOptionPrompt, spelled out to avoid the non-Sendable global under Swift 6.
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    return false
  }

  private static func postCommandV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    // The key that types "v" in the active layout (47 on Dvorak): keycode 9 would be ⌘K there.
    let vKey = CGKeyCode(KeyboardLayoutCharacter.currentCommandVKeyCode())
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
      event?.flags = .maskCommand
      event?.post(tap: .cghidEventTap)
    }
  }
}
