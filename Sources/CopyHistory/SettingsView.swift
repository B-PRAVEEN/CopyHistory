import AppKit
import SwiftUI
import CopyHistoryCore

/// Records a replacement global shortcut (L1). A class because the NSEvent monitor
/// closure escapes and must mutate recording state.
@MainActor
final class ShortcutRecorder: ObservableObject {
  @Published var isRecording = false
  @Published private(set) var display = HotKeyPreferences.current().display
  // Main-thread confined; nonisolated so deinit can always remove them.
  nonisolated(unsafe) private var monitor: Any?
  nonisolated(unsafe) private var closeObserver: NSObjectProtocol?
  nonisolated(unsafe) private var resignKeyObserver: NSObjectProtocol?

  init() {
    // F9: the Settings window is cached (isReleasedWhenClosed = false), so
    // deinit never runs when it closes. Cancel recording explicitly instead,
    // or isRecording sticks and the global hotkey stays dead.
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelIfRecording() } }
    // Showing the popup orderOuts Settings, which resigns key, so this also
    // covers recording left on while Settings is hidden.
    resignKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelIfRecording() } }
  }

  deinit {
    if let monitor { NSEvent.removeMonitor(monitor) }
    if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    GlobalHotKey.isRecording = false
  }

  func toggle() { isRecording ? cancel() : start() }

  func cancel() { finish(display: nil) }

  /// No-op unless recording, so window notifications don't spam @Published updates.
  private func cancelIfRecording() {
    guard isRecording else { return }
    cancel()
  }

  private func start() {
    guard !isRecording else { return }
    isRecording = true
    GlobalHotKey.isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {  // Escape cancels
        MainActor.assumeIsolated { self?.cancel() }
        return nil
      }
      guard HotKeyPreferences.isValid(flags: event.modifierFlags) else { return event }
      let spec = HotKeySpec(keyCode: UInt32(event.keyCode),
                            modifiers: HotKeyPreferences.carbonModifiers(from: event.modifierFlags),
                            display: HotKeyPreferences.displayString(
                              characters: event.charactersIgnoringModifiers,
                              flags: event.modifierFlags,
                              keyCode: event.keyCode))
      HotKeyPreferences.save(spec)
      MainActor.assumeIsolated { self?.finish(display: spec.display) }
      return nil
    }
  }

  private func finish(display: String?) {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    GlobalHotKey.isRecording = false
    if let display { self.display = display }
    isRecording = false
  }
}

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  @State private var newApp = ""
  @StateObject private var recorder = ShortcutRecorder()

  var body: some View {
    Form {
      if !settings.vaultStatus.isHealthy {
        Section("History storage") {
          ForEach(settings.vaultStatus.messages, id: \.self) { line in
            Label(line, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
          if settings.vaultStatus.canRetry {
            HStack {
              if settings.vaultStatus.unsavedPinCount > 0 {
                Text("Allow Keychain access when asked, then retry.")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Retry saving") { settings.retryVaultWrites() }
            }
          }
        }
      }
      Section("Keyboard shortcut") {
        HStack {
          Text("Show history")
          Spacer()
          Text(recorder.display).foregroundStyle(.secondary)
          Button(recorder.isRecording ? "Press keys…" : "Change…") { recorder.toggle() }
          if recorder.isRecording {
            Button("Cancel") { recorder.cancel() }
          }
        }
        Text("Must include ⌘ or ⌃ so normal typing keeps working.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Paste") {
        Toggle("Paste as plain text by default", isOn: $settings.plainTextDefault)
        Text("Hold Shift with Return (or Option when clicking) to flip this for one paste.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Sensitive data") {
        Stepper(value: $settings.redactionExpirySeconds, in: 0...86_400, step: 30) {
          Text(settings.redactionExpirySeconds == 0
               ? "Auto-expire flagged items: never"
               : "Auto-expire flagged items after \(settings.redactionExpirySeconds) s")
        }
      }
      Section("Ignored apps") {
        if settings.ignoredApps.isEmpty {
          Text("No ignored apps").foregroundStyle(.secondary)
        }
        ForEach(settings.ignoredApps, id: \.self) { id in
          HStack {
            Text(id)
            Spacer()
            Button("Remove") { settings.ignoredApps.removeAll { $0 == id } }
          }
        }
        HStack {
          TextField("Bundle identifier", text: $newApp).onSubmit(add)
          Button("Add", action: add).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
          Menu("Running apps") {
            ForEach(runningApps(), id: \.self) { id in Button(id) { settings.addIgnoredApp(id) } }
          }
          .fixedSize()
        }
      }
      Section("General") {
        Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                set: { settings.setLaunchAtLogin($0) }))
        if let error = settings.launchAtLoginError {
          Text(error).font(.caption).foregroundStyle(.orange)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460, height: 460)
    .onDisappear { recorder.cancel() }
    // The Settings window is cached, so onAppear may not run again; refresh whenever it is shown.
    // Refreshing is cheap and idempotent, so any window becoming key is fine as a trigger.
    .onAppear { settings.refreshVaultStatus() }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
      settings.refreshVaultStatus()
    }
  }

  private func add() {
    settings.addIgnoredApp(newApp)
    newApp = ""
  }

  private func runningApps() -> [String] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap(\.bundleIdentifier)
      .filter { $0 != Bundle.main.bundleIdentifier }
      .sorted()
  }
}
