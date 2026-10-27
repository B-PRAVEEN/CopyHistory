import AppKit
import Combine
import CopyHistoryCore

/// Owns the opt-in update check: follows the setting, publishes what it found for Settings and the
/// menu bar, and opens release pages. Never downloads or installs anything.
@MainActor
final class UpdateController: ObservableObject {
  static let upgradeHint = "brew upgrade --cask copyhistory"

  /// The newer release last seen; kept across later failed checks, cleared once up to date.
  @Published private(set) var available: (version: ReleaseVersion, url: URL)?
  @Published private(set) var lastResult: UpdateCheckResult?
  @Published private(set) var isChecking = false

  private let checker: UpdateChecker
  private var settingObserver: AnyCancellable?

  init(settings: AppSettings) {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    checker = UpdateChecker(currentVersion: version, fetcher: URLSessionUpdateFetcher(),
                            store: UserDefaultsUpdateCheckTimeStore(defaults: .standard))
    checker.onResult = { [weak self] in self?.record($0) }
    // Fires right away with the stored value; UpdateChecker ignores repeats.
    settingObserver = settings.$checkForUpdates.sink { [weak self] enabled in
      MainActor.assumeIsolated { self?.checker.isEnabled = enabled }
    }
  }

  var hasVersion: Bool { checker.currentVersion != nil }

  /// User-initiated; works whether or not automatic checks are on.
  func checkNow() {
    guard !isChecking else { return }
    isChecking = true
    Task {
      await checker.checkNow()
      isChecking = false
    }
  }

  func openReleasePage() {
    guard let url = available?.url else { return }
    NSWorkspace.shared.open(url)
  }

  private func record(_ result: UpdateCheckResult) {
    lastResult = result
    switch result {
    case let .available(version, url): available = (version, url)
    case .upToDate: available = nil
    case .failed: break
    }
  }
}
