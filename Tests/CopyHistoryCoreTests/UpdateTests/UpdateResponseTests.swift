import Foundation
import Testing
@testable import CopyHistoryCore

@Suite struct ReleaseVersionTests {
  @Test(arguments: [
    ("1.2.3", ReleaseVersion(major: 1, minor: 2, patch: 3)),
    ("v1.2.3", ReleaseVersion(major: 1, minor: 2, patch: 3)),
    ("V1.2.3", ReleaseVersion(major: 1, minor: 2, patch: 3)),
    (" v0.10.0\n", ReleaseVersion(major: 0, minor: 10, patch: 0)),
    ("01.002.0003", ReleaseVersion(major: 1, minor: 2, patch: 3)),
  ])
  func parsesPlainVersions(input: String, expected: ReleaseVersion) {
    #expect(ReleaseVersion(input) == expected)
  }

  @Test(arguments: ["", "   ", "v", "1", "1.2", "1.2.3.4", "1.2.", ".1.2", "1..2", "vv1.2.3", "v 1.2.3",
                    "1.2.3-beta", "1.2.3-rc.1", "1.2.3+build.5", "+1.2.3", "-1.2.3", "1.-2.3", "1.2.x",
                    "１.２.３", "99999999999999999999.0.0", "release-1.2.3"])
  func rejectsEverythingElse(input: String) {
    #expect(ReleaseVersion(input) == nil)
  }

  @Test func comparesNumerically() throws {
    func v(_ s: String) throws -> ReleaseVersion { try #require(ReleaseVersion(s)) }
    #expect(try v("1.10.0") > v("1.9.0"))
    #expect(try v("1.0.10") > v("1.0.9"))
    #expect(try v("2.0.0") > v("1.99.99"))
    #expect(try v("v1.2.3") == v("1.2.3"))
    #expect(try !(v("1.2.3") < v("1.2.3")))
    #expect(try v("0.9.0") < v("0.10.0"))
  }
}

@Suite struct UpdateResponseTests {
  let current = ReleaseVersion(major: 1, minor: 1, patch: 0)
  let page = "https://github.com/B-PRAVEEN/CopyHistory/releases/tag/v1.2.0"

  func parse(_ data: Data, status: Int = 200) -> UpdateCheckResult {
    UpdateChecker.parse(data: data, response: UpdateFixtures.response(status), currentVersion: current)
  }

  @Test func newerReleaseIsAvailable() {
    #expect(parse(UpdateFixtures.release(tag: "v1.2.0"))
            == .available(version: ReleaseVersion(major: 1, minor: 2, patch: 0), url: URL(string: page)!))
    #expect(parse(UpdateFixtures.release(tag: "1.1.1")) != .upToDate)
  }

  @Test(arguments: ["v1.1.0", "1.1.0", "1.0.9", "0.9.0"])
  func sameOrOlderIsUpToDate(tag: String) {
    #expect(parse(UpdateFixtures.release(tag: tag)) == .upToDate)
  }

  @Test func draftsAndPrereleasesAreIgnored() {
    #expect(parse(UpdateFixtures.release(tag: "v9.0.0", draft: true)) == .upToDate)
    #expect(parse(UpdateFixtures.release(tag: "v9.0.0", prerelease: true)) == .upToDate)
    #expect(parse(UpdateFixtures.release(tag: "v9.0.0-beta.1")) == .upToDate)
    #expect(parse(UpdateFixtures.release(tag: "nightly")) == .upToDate)
  }

  @Test(arguments: [301, 302, 304, 400, 401, 403, 404, 429, 500, 502, 503])
  func nonOKStatusFails(status: Int) {
    #expect(parse(UpdateFixtures.release(tag: "v9.0.0"), status: status) == .failed)
  }

  @Test func rateLimitBodyFails() {
    let body = Data(#"{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com"}"#.utf8)
    #expect(parse(body, status: 403) == .failed)
    #expect(parse(body, status: 200) == .failed)  // missing tag_name / html_url
  }

  @Test(arguments: ["", "not json", "[]", "null", #"{"tag_name": 2, "html_url": "x"}"#, #"{"tag_name": "v9.0.0"}"#,
                    #"{"html_url": "https://github.com/B-PRAVEEN/CopyHistory/releases/tag/v9.0.0"}"#])
  func badJSONFails(body: String) {
    #expect(parse(Data(body.utf8)) == .failed)
  }

  @Test func oversizedBodyFails() {
    var data = UpdateFixtures.release(tag: "v9.0.0")
    data.append(Data(repeating: 0x20, count: UpdateChecker.maxResponseBytes))
    #expect(parse(data) == .failed)
  }

  @Test(arguments: [
    "http://github.com/B-PRAVEEN/CopyHistory/releases/tag/v9.0.0",
    "https://evil.example/B-PRAVEEN/CopyHistory/releases/tag/v9.0.0",
    "https://github.com.evil.example/B-PRAVEEN/CopyHistory/releases/tag/v9.0.0",
    "https://github.com/someone-else/CopyHistory/releases/tag/v9.0.0",
    "https://user@github.com/B-PRAVEEN/CopyHistory/releases/tag/v9.0.0",
    "https://github.com:8443/B-PRAVEEN/CopyHistory/releases/tag/v9.0.0",
    "javascript:alert(1)",
    "",
  ])
  func untrustedReleasePageFails(url: String) {
    #expect(parse(UpdateFixtures.release(tag: "v9.0.0", url: url)) == .failed)
  }

  @Test func nonHTTPResponseFails() {
    let response = URLResponse(url: UpdateChecker.releasesURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    #expect(UpdateChecker.parse(data: UpdateFixtures.release(tag: "v9.0.0"), response: response,
                                currentVersion: current) == .failed)
  }

  @Test(arguments: [403, 404, 429])
  @MainActor func httpErrorsThroughTheCheckerAreSilentFailures(status: Int) async {
    let fetcher = FakeUpdateFetcher(reply: { (UpdateFixtures.release(tag: "v9.0.0"), UpdateFixtures.response(status)) })
    let checker = UpdateChecker(currentVersion: "1.1.0", fetcher: fetcher, store: MemoryUpdateCheckTimeStore())
    var results: [UpdateCheckResult] = []
    checker.onResult = { results.append($0) }
    #expect(await checker.checkNow() == .failed)
    #expect(results == [.failed])
    #expect(fetcher.requests.count == 1)
  }

  @MainActor @Test func badJSONThroughTheCheckerFails() async {
    let fetcher = FakeUpdateFetcher(reply: { (Data("<html>".utf8), UpdateFixtures.response(200)) })
    let checker = UpdateChecker(currentVersion: "1.1.0", fetcher: fetcher, store: MemoryUpdateCheckTimeStore())
    #expect(await checker.checkNow() == .failed)
  }
}
