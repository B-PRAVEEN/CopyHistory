import Foundation
import Testing
@testable import CopyHistoryCore

/// Records every request; answers with `reply`, or (when `hang`) waits until cancelled. Never touches
/// the network.
final class FakeUpdateFetcher: UpdateFetching, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [URLRequest] = []
  private let reply: @Sendable () throws -> (Data, URLResponse)
  private let hang: Bool

  init(hang: Bool = false, reply: @escaping @Sendable () throws -> (Data, URLResponse) = { throw URLError(.notConnectedToInternet) }) {
    self.hang = hang; self.reply = reply
  }

  var requests: [URLRequest] { lock.withLock { _requests } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lock.withLock { _requests.append(request) }
    if hang { try await Task.sleep(for: .seconds(3600)) }
    return try reply()
  }
}

final class MemoryUpdateCheckTimeStore: UpdateCheckTimeStoring {
  var lastCheck: Date?
}

@MainActor final class TestClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

enum UpdateFixtures {
  static func response(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: UpdateChecker.releasesURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
  }

  static func release(tag: String = "v1.2.0",
                      url: String = "https://github.com/B-PRAVEEN/CopyHistory/releases/tag/v1.2.0",
                      draft: Bool = false, prerelease: Bool = false) -> Data {
    let object: [String: Any] = ["tag_name": tag, "html_url": url, "draft": draft, "prerelease": prerelease,
                                 "name": "Release", "body": "notes"]
    return try! JSONSerialization.data(withJSONObject: object)
  }

  static func ok(_ data: Data = release()) -> @Sendable () throws -> (Data, URLResponse) {
    { (data, response(200)) }
  }
}

@MainActor @Suite struct UpdateCheckerTests {
  let clock = TestClock()
  let store = MemoryUpdateCheckTimeStore()

  func make(version: String? = "1.1.0", fetcher: FakeUpdateFetcher) -> UpdateChecker {
    let clock = clock
    // The loop's sleep never wakes on its own within a test; disabling cancels it.
    return UpdateChecker(currentVersion: version, fetcher: fetcher, store: store, now: { clock.now },
                         sleep: { try await Task.sleep(for: .seconds($0 * 1000)) })
  }

  /// Waits (bounded) for the background loop to reach a state.
  func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  // MARK: Off by default / off means nothing runs

  @Test func settingIsOffByDefault() throws {
    let suite = "UpdateCheckerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!UpdateChecker.isEnabled(in: defaults))
    defaults.set(true, forKey: UpdateChecker.enabledKey)
    #expect(UpdateChecker.isEnabled(in: defaults))
    defaults.set(false, forKey: UpdateChecker.enabledKey)
    #expect(!UpdateChecker.isEnabled(in: defaults))
  }

  @Test func newCheckerIsDisabledAndNeverFetches() async {
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    #expect(!checker.isEnabled)
    #expect(checker.loop == nil)
    checker.isEnabled = false  // a repeated "off" starts nothing
    #expect(await checker.checkIfDue() == nil)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fetcher.requests.isEmpty)
    #expect(store.lastCheck == nil)
  }

  @Test func enablingChecksOnceThenDisablingStopsTheLoop() async {
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    var results: [UpdateCheckResult] = []
    checker.onResult = { results.append($0) }
    checker.isEnabled = true
    checker.isEnabled = true  // idempotent: no second loop, no second request
    await waitUntil { !results.isEmpty }
    #expect(fetcher.requests.count == 1)
    #expect(results == [.available(version: ReleaseVersion(major: 1, minor: 2, patch: 0),
                                   url: URL(string: "https://github.com/B-PRAVEEN/CopyHistory/releases/tag/v1.2.0")!)])
    let loop = checker.loop
    checker.isEnabled = false
    #expect(checker.loop == nil)
    await loop?.value  // the loop actually ends
    #expect(fetcher.requests.count == 1)
  }

  @Test func disablingCancelsARequestInFlight() async {
    let fetcher = FakeUpdateFetcher(hang: true, reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    var results: [UpdateCheckResult] = []
    checker.onResult = { results.append($0) }
    checker.isEnabled = true
    await waitUntil { checker.inFlight != nil }
    let inFlight = checker.inFlight
    let loop = checker.loop
    #expect(inFlight != nil)
    checker.isEnabled = false
    #expect(await inFlight?.value == .failed)
    await loop?.value
    #expect(results.isEmpty)  // a cancelled check is not reported
    #expect(checker.lastResult == nil)
    #expect(checker.inFlight == nil)
  }

  // MARK: Throttling

  @Test func checksAtMostOncePerDay() async {
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    checker.isEnabled = true
    await waitUntil { checker.lastResult != nil }
    #expect(fetcher.requests.count == 1)
    #expect(store.lastCheck == clock.now)
    #expect(await checker.checkIfDue() == nil)
    clock.now += UpdateChecker.minimumInterval - 1
    #expect(await checker.checkIfDue() == nil)
    #expect(fetcher.requests.count == 1)
    clock.now += 1
    #expect(await checker.checkIfDue() != nil)
    #expect(fetcher.requests.count == 2)
    checker.isEnabled = false
  }

  @Test func persistedRecentCheckSuppressesTheCheckOnEnable() async {
    store.lastCheck = clock.now - 60 * 60
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    checker.isEnabled = true
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fetcher.requests.isEmpty)
    checker.isEnabled = false
  }

  @Test func clockMovedBackwardsCountsAsDue() {
    store.lastCheck = clock.now + 3 * UpdateChecker.minimumInterval
    let checker = make(fetcher: FakeUpdateFetcher())
    #expect(checker.isDue)
  }

  @Test func failureCountsAsACheckSoThereIsNoRetryStorm() async {
    let fetcher = FakeUpdateFetcher()  // network error
    let checker = make(fetcher: fetcher)
    checker.isEnabled = true
    await waitUntil { checker.lastResult != nil }
    #expect(checker.lastResult == .failed)
    #expect(await checker.checkIfDue() == nil)
    clock.now += 60 * 60
    #expect(await checker.checkIfDue() == nil)
    #expect(fetcher.requests.count == 1)
    checker.isEnabled = false
  }

  @Test func checkNowRunsWhenDisabledAndNotDue() async {
    store.lastCheck = clock.now
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    #expect(await checker.checkNow() != .failed)
    #expect(fetcher.requests.count == 1)
    #expect(checker.loop == nil)  // a manual check does not turn the schedule on
  }

  @Test func concurrentChecksShareOneRequest() async {
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    async let a = checker.checkNow()
    async let b = checker.checkNow()
    let (ra, rb) = await (a, b)
    #expect(ra == rb)
    #expect(fetcher.requests.count == 1)
  }

  @Test(arguments: [nil, "", "1.0", "dev", "1.2.3-beta"] as [String?])
  func unknownRunningVersionNeverFetches(version: String?) async {
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(version: version, fetcher: fetcher)
    #expect(checker.currentVersion == nil)
    #expect(await checker.checkNow() == .failed)
    checker.isEnabled = true
    try? await Task.sleep(for: .milliseconds(20))
    checker.isEnabled = false
    #expect(fetcher.requests.isEmpty)
  }

  // MARK: The request

  @Test func onlyTheReleasesURLIsEverRequested() async {
    let fetcher = FakeUpdateFetcher(reply: UpdateFixtures.ok())
    let checker = make(fetcher: fetcher)
    await checker.checkNow()
    clock.now += UpdateChecker.minimumInterval
    checker.isEnabled = true
    await waitUntil { fetcher.requests.count == 2 }
    checker.isEnabled = false
    #expect(fetcher.requests.count == 2)
    for request in fetcher.requests {
      #expect(request.url?.absoluteString == "https://api.github.com/repos/B-PRAVEEN/CopyHistory/releases/latest")
      #expect(request.url?.query == nil)
      #expect(request.httpMethod == "GET")
      #expect(request.httpBody == nil && request.httpBodyStream == nil)
      #expect(Set((request.allHTTPHeaderFields ?? [:]).keys) == ["Accept", "User-Agent"])
      #expect(request.value(forHTTPHeaderField: "User-Agent") == "CopyHistory/1.1.0")
      #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
      #expect(!request.httpShouldHandleCookies)
      #expect(request.timeoutInterval == UpdateChecker.timeout)
    }
  }

  @Test func userStoreRoundTripsTheLastCheck() throws {
    let suite = "UpdateCheckerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsUpdateCheckTimeStore(defaults: defaults)
    #expect(store.lastCheck == nil)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    store.lastCheck = date
    #expect(UserDefaultsUpdateCheckTimeStore(defaults: defaults).lastCheck == date)
  }

  @Test func realFetcherRefusesRedirects() async throws {
    let fetcher = URLSessionUpdateFetcher()
    // Created but never resumed, so nothing is sent.
    let task = URLSession(configuration: .ephemeral).dataTask(with: UpdateChecker.releasesURL)
    defer { task.cancel() }
    let redirect = try #require(HTTPURLResponse(url: UpdateChecker.releasesURL, statusCode: 302, httpVersion: nil,
                                                headerFields: ["Location": "https://example.com/"]))
    let next = await fetcher.urlSession(.shared, task: task, willPerformHTTPRedirection: redirect,
                                        newRequest: URLRequest(url: URL(string: "https://example.com/")!))
    #expect(next == nil)
  }
}
