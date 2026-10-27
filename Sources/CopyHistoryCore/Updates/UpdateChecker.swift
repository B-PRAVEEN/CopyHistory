import Foundation

/// A plain `major.minor.patch` release version. A leading `v`/`V` is accepted; anything else
/// (missing or extra components, pre-release or build suffixes, signs, overflow) is rejected, so a
/// tag that is not a plain release never counts as an update.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major; self.minor = minor; self.patch = patch
  }

  public init?(_ string: String) {
    var s = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
    if s.first == "v" || s.first == "V" { s = s.dropFirst() }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var numbers: [Int] = []
    for part in parts {
      // ASCII digits only: Int("+1") and non-ASCII digits must not sneak through.
      guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
            let n = Int(part) else { return nil }
      numbers.append(n)
    }
    self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
  }

  public var description: String { "\(major).\(minor).\(patch)" }

  public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
    (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
  }
}

public enum UpdateCheckResult: Equatable, Sendable {
  case upToDate
  case available(version: ReleaseVersion, url: URL)
  /// Network error, unexpected response, or no usable running version. Never surfaced as an alert.
  case failed
}

/// Fetch seam; the app passes `URLSessionUpdateFetcher`, tests a fake.
public protocol UpdateFetching: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Where the time of the last check is kept, so the once-a-day limit survives relaunches.
public protocol UpdateCheckTimeStoring: AnyObject {
  var lastCheck: Date? { get set }
}

public final class UserDefaultsUpdateCheckTimeStore: UpdateCheckTimeStoring {
  public static let key = "updateCheckLastAttempt"
  private let defaults: UserDefaults
  public init(defaults: UserDefaults) { self.defaults = defaults }
  public var lastCheck: Date? {
    get { defaults.object(forKey: Self.key) as? Date }
    set { defaults.set(newValue, forKey: Self.key) }
  }
}

/// An ephemeral session (no cookies, cache or credentials) that refuses redirects, so the one
/// GitHub URL is the only thing ever requested.
public final class URLSessionUpdateFetcher: NSObject, UpdateFetching, URLSessionTaskDelegate, @unchecked Sendable {
  private let session: URLSession

  public override init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = UpdateChecker.timeout
    config.timeoutIntervalForResource = UpdateChecker.timeout
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: config)
    super.init()
  }

  deinit { session.invalidateAndCancel() }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request, delegate: self)
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask,
                         willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest) async -> URLRequest? {
    nil  // the 3xx response itself is returned, and treated as a failure
  }
}

/// Opt-in check for a newer GitHub release. It only ever sends one anonymous GET to
/// `releasesURL` (headers: Accept and `User-Agent: CopyHistory/<version>`), at most once per
/// `minimumInterval` while enabled, and never downloads or installs anything. Failures are silent
/// and count as a check, so there is no retrying until the next interval. While disabled nothing
/// runs; disabling cancels the periodic loop and any request in flight.
@MainActor
public final class UpdateChecker {
  /// The settings key; absent means off.
  public nonisolated static let enabledKey = "checkForUpdates"
  public nonisolated static let releasesURL = URL(string: "https://api.github.com/repos/B-PRAVEEN/CopyHistory/releases/latest")!
  /// Release pages must live under this path to be offered (and opened in the browser).
  public nonisolated static let releasePagePrefix = "/B-PRAVEEN/CopyHistory/"
  public nonisolated static let minimumInterval: TimeInterval = 24 * 60 * 60
  /// How often the enabled loop wakes to see whether a check is due (no request unless it is).
  public nonisolated static let pollInterval: TimeInterval = 60 * 60
  public nonisolated static let timeout: TimeInterval = 10
  /// Larger responses are not parsed.
  public nonisolated static let maxResponseBytes = 1 << 20

  public nonisolated static func isEnabled(in defaults: UserDefaults) -> Bool {
    defaults.object(forKey: enabledKey) as? Bool ?? false
  }

  public let currentVersion: ReleaseVersion?
  /// Called on the main actor with each completed (not cancelled) check.
  public var onResult: (@MainActor (UpdateCheckResult) -> Void)?
  public private(set) var lastResult: UpdateCheckResult?

  private let fetcher: UpdateFetching
  private let store: UpdateCheckTimeStoring
  private let now: @MainActor () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  /// The enabled loop (awaited by tests).
  private(set) var loop: Task<Void, Never>?
  /// The request in flight, shared by concurrent callers.
  private(set) var inFlight: Task<UpdateCheckResult, Never>?

  /// - Parameter currentVersion: the running app's `CFBundleShortVersionString`; when it is
  ///   missing or not a plain release version, no request is ever made.
  public init(currentVersion: String?,
              fetcher: UpdateFetching,
              store: UpdateCheckTimeStoring,
              now: @escaping @MainActor () -> Date = { Date() },
              sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
    self.currentVersion = currentVersion.flatMap(ReleaseVersion.init)
    self.fetcher = fetcher; self.store = store; self.now = now; self.sleep = sleep
  }

  /// Starts (checking right away if due) or stops the periodic check. Setting the same value again
  /// does nothing.
  public var isEnabled = false {
    didSet {
      guard isEnabled != oldValue else { return }
      if isEnabled {
        let sleep = sleep
        loop = Task { [weak self] in
          // Ends once the checker is gone; otherwise disabling cancels it.
          while !Task.isCancelled, let checker = self {
            await checker.checkIfDue()
            do { try await sleep(Self.pollInterval) } catch { return }
          }
        }
      } else {
        loop?.cancel(); loop = nil
        inFlight?.cancel(); inFlight = nil
      }
    }
  }

  /// Whether `minimumInterval` has passed since the last check (or the clock went backwards).
  public var isDue: Bool {
    guard let last = store.lastCheck else { return true }
    let elapsed = now().timeIntervalSince(last)
    return elapsed < 0 || elapsed >= Self.minimumInterval
  }

  /// Checks only if enabled and due; returns nil when skipped.
  @discardableResult
  public func checkIfDue() async -> UpdateCheckResult? {
    guard isEnabled, isDue else { return nil }
    return await check()
  }

  /// A user-initiated check: runs whether or not automatic checks are enabled or due.
  @discardableResult
  public func checkNow() async -> UpdateCheckResult { await check() }

  private func check() async -> UpdateCheckResult {
    guard let currentVersion else { return publish(.failed) }
    if let inFlight { return await inFlight.value }
    store.lastCheck = now()  // stamped up front so failures don't cause retries
    let request = Self.makeRequest(currentVersion: currentVersion)
    let fetcher = fetcher
    let task = Task<UpdateCheckResult, Never> {
      do {
        let (data, response) = try await fetcher.data(for: request)
        return Self.parse(data: data, response: response, currentVersion: currentVersion)
      } catch {
        return .failed
      }
    }
    inFlight = task
    let result = await task.value
    if inFlight == task { inFlight = nil }
    // A check cancelled by disabling is dropped rather than reported.
    if task.isCancelled { return .failed }
    return publish(result)
  }

  private func publish(_ result: UpdateCheckResult) -> UpdateCheckResult {
    lastResult = result
    onResult?(result)
    return result
  }

  public nonisolated static func makeRequest(currentVersion: ReleaseVersion) -> URLRequest {
    var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("CopyHistory/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    return request
  }

  private struct Release: Decodable {
    let tag_name: String
    let html_url: String
    let draft: Bool?
    let prerelease: Bool?
  }

  /// Turns a `releases/latest` response into a result. Only HTTP 200 with a sane body counts;
  /// drafts, pre-releases and non-plain tags are ignored (reported as up to date).
  public nonisolated static func parse(data: Data, response: URLResponse,
                                       currentVersion: ReleaseVersion) -> UpdateCheckResult {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
          data.count <= maxResponseBytes,
          let release = try? JSONDecoder().decode(Release.self, from: data) else { return .failed }
    if release.draft == true || release.prerelease == true { return .upToDate }
    guard let version = ReleaseVersion(release.tag_name) else { return .upToDate }
    guard version > currentVersion else { return .upToDate }
    guard let url = URL(string: release.html_url), url.scheme == "https", url.host == "github.com",
          url.user == nil, url.password == nil, url.port == nil,
          url.path.hasPrefix(releasePagePrefix) else { return .failed }
    return .available(version: version, url: url)
  }
}
