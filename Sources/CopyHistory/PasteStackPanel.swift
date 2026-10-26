import AppKit
import SwiftUI
import CopyHistoryCore

/// A panel that can never become key or main, so showing it never takes focus from the app the
/// user is pasting into. It ignores the mouse as well; it is display-only.
private final class PassivePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(size: NSSize) {
    super.init(contentRect: NSRect(origin: .zero, size: size),
               styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: true)
    level = .floating
    isFloatingPanel = true
    hidesOnDeactivate = false  // an accessory app is never active; the panel must stay visible
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
  }
}

/// Floating preview of the Paste Stack queue (top-right of the screen): the next entry highlighted,
/// the count, and how to advance. Labels come from `PasteStackPreview`, so flagged entries never
/// show their text.
@MainActor
final class PasteStackPanel {
  /// Rows shown; the rest are summarised as "+N more".
  static let maxRows = 8

  private let panel = PassivePanel(size: NSSize(width: 300, height: 120))
  private let hosting = NSHostingView(rootView: PasteStackPanelView(titles: [], total: 0, hint: ""))

  init() {
    panel.contentView = hosting
  }

  var isVisible: Bool { panel.isVisible }

  /// Shows or refreshes the panel. `hint` is the one-line instruction under the list.
  func show(entries: [ClipboardEntry], hint: String) {
    let titles = entries.prefix(Self.maxRows).map { PasteStackPreview.title(for: $0, maxLength: 44) }
    hosting.rootView = PasteStackPanelView(titles: titles, total: entries.count, hint: hint)
    let size = hosting.fittingSize
    panel.setContentSize(size)
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12))
    }
    panel.orderFrontRegardless()  // never makeKey: the paste target keeps focus
  }

  func hide() { panel.orderOut(nil) }
}

private struct PasteStackPanelView: View {
  let titles: [String]
  let total: Int
  let hint: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: "square.stack.3d.up")
        Text("Paste Stack").font(.headline)
        Spacer()
        Text("\(total)")
          .font(.caption.monospacedDigit().bold())
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(Capsule().fill(Color.accentColor.opacity(0.25)))
      }
      if titles.isEmpty {
        Text("Copy items to add them to the stack.")
          .font(.callout).foregroundStyle(.secondary)
      } else {
        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
          HStack(spacing: 6) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              .frame(width: 16, alignment: .trailing)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 6).padding(.vertical, 3)
          .background(RoundedRectangle(cornerRadius: 5)
            .fill(index == 0 ? Color.accentColor.opacity(0.3) : Color.clear))
          .fontWeight(index == 0 ? .semibold : .regular)
        }
        if total > titles.count {
          Text("+\(total - titles.count) more").font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
  }
}

/// Brief centred message (e.g. "Paste Stack finished"), faded out after a moment. Never takes focus.
@MainActor
final class PasteStackHUD {
  private let panel = PassivePanel(size: NSSize(width: 320, height: 60))
  private let hosting = NSHostingView(rootView: PasteStackHUDView(message: ""))
  /// Bumped per message so an older message's hide timer cannot hide a newer one.
  private var generation = 0

  init() {
    panel.contentView = hosting
  }

  func show(_ message: String, duration: TimeInterval = 1.6) {
    generation += 1
    let current = generation
    hosting.rootView = PasteStackHUDView(message: message)
    let size = hosting.fittingSize
    panel.setContentSize(size)
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.2))
    }
    panel.orderFrontRegardless()
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(duration))
      guard let self, current == self.generation else { return }
      self.panel.orderOut(nil)
    }
  }
}

private struct PasteStackHUDView: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.callout)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 320)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16).padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
  }
}
