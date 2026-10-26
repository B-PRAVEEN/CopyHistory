import Foundation
import Testing
@testable import CopyHistoryCore

// Fixtures are obviously fake and assembled by concatenation so secret scanners don't flag this file.
private let fake40 = "FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfak1"
private let stripeLive = "sk" + "_live_" + "FAKE1234FAKE5678FAKE"
private let stripeRestricted = "rk" + "_live_" + "FAKE1234FAKE5678FAKE"
private let googleKey = "AI" + "za" + "SyFAKE-FAKE_FAKEFAKEFAKEFAKEFAKE123"
private let slackHook = "https://hooks.slack" + ".com/services/T00FAKE00/B00FAKE00/FAKEfakeFAKEfake1234"

@Suite struct SecretDetectorUnicodeTests {
  let d = SecretDetector()

  // H0: non-ASCII decimal digit runs used to trap in scan().
  @Test(arguments: [
    "١٢٣٤٥٦٧٨٩٠١٢٣٤",                       // Arabic-Indic
    "۱۲۳۴۵۶۷۸۹۰۱۲۳۴۵۶",                     // Persian
    "१२३४५६७८९०१२३४५",                       // Devanagari
    "４１１１１１１１１１１１１１１１",       // fullwidth 4111…
    "Total: ١٢٣٤٥٦٧٨٩٠١٢٣ ريال",
  ])
  func nonASCIIDigitsDoNotCrash(_ text: String) {
    #expect(d.scan(text).isEmpty)
  }

  @Test func asciiCardNextToNonASCIIDigits() {
    let text = "٤١١١ 4111111111111111 ٤١١١"
    let f = d.scan(text)
    #expect(f.map(\.category) == [.creditCard])
    #expect(d.mask(text, findings: f) == "٤١١١ ••••••••1111 ٤١١١")
  }

  @Test func combiningMarkAfterKeyIsCovered() {
    let text = "k=sk-proj-FAKEFAKEFAKEFAKEFAKE1234\u{301} tail"
    let f = d.scan(text)
    #expect(f.count == 1)
    let masked = d.mask(text, findings: f)
    #expect(masked == "k=sk-•••••••• tail")
  }

  @Test func flagsAndEmojiAroundKeys() {
    let text = "🇺🇸" + stripeLive + "🇺🇸 👨‍👩‍👧 ghp_" + String(repeating: "F", count: 36) + " é"
    let f = d.scan(text)
    #expect(f.map(\.category) == [.genericSecret, .githubToken])
    #expect(d.mask(text, findings: f) == "🇺🇸sk_live_••••••••🇺🇸 👨‍👩‍👧 ghp_•••••••• é")
  }
}

@Suite struct SecretDetectorCorpusTests {
  let d = SecretDetector()

  /// Every listed secret must be gone from the masked text.
  func expectMasked(_ text: String, hiding secrets: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    let masked = d.mask(text, findings: d.scan(text))
    for s in secrets { #expect(!masked.contains(s), "\(s) visible in \(masked)", sourceLocation: sourceLocation) }
  }

  @Test func stsJSON() {
    let token = "FwoGZXIvYXdzEFAKEfakeFAKEfake//FAKEfakeFAKE+fake=="
    let json = #"{"AccessKeyId":"ASIAFAKEFAKEFAKEFAKE","SecretAccessKey":""# + fake40 + #"","SessionToken":""# + token + #""}"#
    let f = d.scan(json)
    #expect(f.map(\.category) == [.awsAccessKey, .awsSecretKey, .genericSecret])
    expectMasked(json, hiding: ["FAKEFAKEFAKEFAKE", fake40, token])
  }

  @Test func dotEnv() {
    let env = """
    DATABASE_URL=postgres://admin:hunter2pass@db.internal:5432/app
    PASSWORD=Sup3rS3cret!
    API_KEY=0123456789abcdef0123456789abcdef
    SECRET_KEY=dGhpcyBpcyBGQUtFIGZha2UgRkFLRQ==
    SIGNING_SECRET=/FAKE+fake/FAKE+fake/1234==
    export GITHUB_TOKEN="fake_tok_8f3k2j5h7g"
    db.password: 'Fake#Pass9'
    """
    #expect(d.scan(env).allSatisfy { $0.category == .genericSecret })
    expectMasked(env, hiding: ["hunter2pass", "Sup3rS3cret", "0123456789abcdef", "dGhpcyBp", "FAKE+fake", "fake_tok", "Fake#Pass9"])
    #expect(d.mask(env, findings: d.scan(env)).contains("postgres://admin:••••••••@db.internal"))
  }

  @Test func bearer() {
    let text = "Authorization: Bearer FAKEopaque1234tokenFAKE5678"
    #expect(d.scan(text).map(\.category) == [.genericSecret])
    #expect(d.mask(text, findings: d.scan(text)) == "Authorization: Bearer ••••••••")
    // A JWT bearer stays a JWT.
    #expect(d.scan("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.FAKEsig").map(\.category) == [.jwt])
  }

  @Test func vendorKeys() {
    #expect(d.scan(stripeLive).map(\.category) == [.genericSecret])
    #expect(d.scan(stripeRestricted).map(\.category) == [.genericSecret])
    #expect(d.scan("key: " + googleKey).map(\.category) == [.genericSecret])
    #expect(d.scan(slackHook).map(\.category) == [.slackToken])
    #expect(d.scan("xapp-1-A0FAKE-1234-FAKEfakeFAKE").map(\.category) == [.slackToken])
    #expect(d.mask(stripeLive, findings: d.scan(stripeLive)) == "sk_live_••••••••")
    #expect(d.mask(slackHook, findings: d.scan(slackHook)) == "https://hooks.slack.com/••••••••")
    expectMasked("url=" + slackHook, hiding: ["T00FAKE00", "FAKEfakeFAKEfake1234"])
    #expect(d.scan("sk-proj-FAKE_fake-FAKE_fake-FAKE_1234").map(\.category) == [.openAIKey])
  }

  @Test func underscorePrefixedKeys() {
    #expect(d.scan("key_AKIAFAKEFAKEFAKEFAKE").map(\.category) == [.awsAccessKey])
    #expect(d.scan("my_ghp_" + String(repeating: "F", count: 36)).map(\.category) == [.githubToken])
  }

  @Test func pgpAndTruncatedKeys() {
    let pgp = "-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nFAKEFAKE\n=FAKE\n-----END PGP PRIVATE KEY BLOCK-----"
    let f = d.scan("a\n" + pgp + "\nb")
    #expect(f.map(\.category) == [.privateKey])
    #expect(f[0].range == 2..<(2 + pgp.count))

    let truncated = "here:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEFAKEFAKE\nFAKEFAKEFAKE"
    let t = d.scan(truncated)
    #expect(t.map(\.category) == [.privateKey])
    #expect(t[0].range.upperBound == truncated.count)
    expectMasked(truncated, hiding: ["b3BlbnNzaC1rZXktdjEFAKEFAKE", "FAKEFAKEFAKE"])

    let noDashes = "-----BEGIN RSA PRIVATE KEY\nMIIFAKEFAKE"
    #expect(d.scan(noDashes).map(\.category) == [.privateKey])

    // Two keys stay two findings.
    let two = "-----BEGIN PRIVATE KEY-----\nA\n-----END PRIVATE KEY-----\nmid\n-----BEGIN EC PRIVATE KEY-----\nB\n-----END EC PRIVATE KEY-----"
    #expect(d.mask(two, findings: d.scan(two)).components(separatedBy: "••••••••").count == 3)
    #expect(d.mask(two, findings: d.scan(two)).contains("mid"))
  }

  @Test func overlappingHitsLeaveNoTail() {
    // The JWT ends at the space; the generic assignment covers the same start. Nothing may leak.
    let text = "token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.FAKEsig_tail"
    expectMasked(text, hiding: ["FAKEsig", "tail", "eyJzdWIi"])
  }

  @Test(arguments: [
    "password: String",
    "let password: String = \"\"",
    "token = getToken()",
    "max_tokens: 4096",
    "PASSWORD=${DB_PASSWORD}",
    "password=<your-password>",
    "\"password\": \"********\"",
    "api_key: YOUR_API_KEY_HERE",
    "token: CancellationToken",
    "self.password = this.password",
    "the bearer of bad news arrived",
    "Bearer authentication is required",
    "see https://example.com:8080/x and ssh://git@github.com/x.git",
    "postgres://user:password@localhost/db",
    "Order number 1234567890123",
    "secretary: Alice Smith",
    "sk_live_ (prefix only)",
    "PWD=/Users/alice/projects2",
    "OLDPWD=/home/u/src",
    "secret_file: /etc/secrets/app.yaml",
    "private_key_path: ~/.ssh/id_ed25519",
  ])
  func falsePositives(_ text: String) {
    #expect(d.scan(text).isEmpty, "\(d.scan(text))")
  }
}

/// M1: every rule must run in linear time on attacker-controlled clipboard text.
@Suite(.serialized) struct SecretDetectorPerformanceTests {
  let d = SecretDetector()

  static let adversarial: [String] = [
    "eyJ-", "eyJ", "eyJaaaaa.", "-----BEGIN PRIVATE KEY-----\n", "-----BEGIN ", "aws secret ", "password=",
    "password", "Bearer ", "a://b:", "a://", "AIza", "sk-", "sk_live_", "xoxb-", "1 ", "1-", "SecretAccessKey:",
    "-----END PRIVATE KEY-----", "ghp_", "_",
  ]

  @Test(.timeLimit(.minutes(2)), arguments: adversarial)
  func linearOnOneMegabyte(_ unit: String) {
    let text = String(repeating: unit, count: (1 << 20) / unit.utf8.count)
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = d.scan(text) }
    #expect(elapsed < .seconds(3), "\(unit.debugDescription) x1MB took \(elapsed)")
  }
}
