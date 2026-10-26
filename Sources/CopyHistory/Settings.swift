import Foundation
import ServiceManagement
import CopyHistoryCore

/// User-facing settings, persisted in UserDefaults. Keys are public constants so the clipboard
/// monitor (ignored apps, auto-expire) can read the same values.
@MainActor
final class AppSettings: ObservableObject {
  enum Key {
    static let ignoredApps = "ignoredApps"
    static let plainTextDefault = "plainTextDefault"
    static let redactionExpirySeconds = "redactionExpirySeconds"
  }

  private let defaults: UserDefaults

  @Published var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: Key.ignoredApps) } }
  @Published var plainTextDefault: Bool { didSet { defaults.set(plainTextDefault, forKey: Key.plainTextDefault) } }
  /// 0 disables auto-expiry of flagged entries.
  @Published var redactionExpirySeconds: Int {
    didSet { defaults.set(redactionExpirySeconds, forKey: Key.redactionExpirySeconds) }
  }
  @Published private(set) var launchAtLogin: Bool
  @Published var launchAtLoginError: String?
  /// History file and vault state; refreshed by `refreshVaultStatus()` (the store does not publish changes).
  @Published private(set) var vaultStatus = VaultStatus()

  /// The concrete store, for vault state and retries. Attached by `PopupViewModel` (AppServices only
  /// exposes the protocol); nil for other stores, which have no vault.
  private weak var historyStore: HistoryStore?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    ignoredApps = defaults.stringArray(forKey: Key.ignoredApps) ?? []
    plainTextDefault = defaults.object(forKey: Key.plainTextDefault) as? Bool ?? false
    redactionExpirySeconds = defaults.object(forKey: Key.redactionExpirySeconds) as? Int ?? 60
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      launchAtLoginError = nil
    } catch {
      launchAtLoginError = "Could not change login item (run from CopyHistory.app): \(error.localizedDescription)"
    }
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  func attach(store: HistoryStore?) {
    historyStore = store
    refreshVaultStatus()
  }

  /// Cheap (three lock reads), safe to call on the main thread.
  func refreshVaultStatus() {
    guard let historyStore else { return }
    let status = VaultStatus(historyStore)
    if status != vaultStatus { vaultStatus = status }
  }

  /// Asks the store to store unsaved pins again. The store writes on its own queue after its save
  /// delay (a Keychain write may block on a prompt), so the status is refreshed a little later.
  func retryVaultWrites() {
    guard let historyStore else { return }
    historyStore.retryVaultWrites()
    Task { @MainActor [weak self] in
      for delay in [1.0, 3.0] {
        try? await Task.sleep(for: .seconds(delay))
        self?.refreshVaultStatus()
      }
    }
  }

  func addIgnoredApp(_ bundleID: String) {
    let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, !ignoredApps.contains(id) else { return }
    ignoredApps.append(id)
  }
}
