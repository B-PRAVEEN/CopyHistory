import Testing
@testable import CopyHistoryCore

@Suite struct SecretDetectorTests {
  let d = SecretDetector()
  func cats(_ s: String) -> [SecretFinding.Category] { d.scan(s).map(\.category) }

  @Test func openAI() { #expect(cats("key=sk-proj-FAKEFAKEFAKEFAKEFAKE1234") == [.openAIKey]) }
  @Test func awsAccess() { #expect(cats("id AKIAFAKEFAKEFAKEFAKE ok") == [.awsAccessKey]) }
  @Test func awsSecret() {
    let f = d.scan("aws_secret_access_key = FAKEfakeFAKEfakeFAKEfakeFAKEfakeFAKEfake")
    #expect(f.map(\.category) == [.awsSecretKey])
    #expect(f[0].range.count == 40)
  }
  @Test func github() {
    #expect(cats("ghp_" + String(repeating: "a", count: 36)) == [.githubToken])
    #expect(cats("github_pat_" + String(repeating: "A1", count: 15)) == [.githubToken])
  }
  @Test func slack() { #expect(cats("xoxb-1234567890-FAKEFAKEFAKE") == [.slackToken]) }
  @Test func jwt() { #expect(cats("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.FAKEsig_-x") == [.jwt]) }
  @Test func pem() {
    let pem = "-----BEGIN RSA PRIVATE KEY-----\nFAKEFAKE\nFAKE\n-----END RSA PRIVATE KEY-----"
    let f = d.scan("x\n" + pem + "\ny")
    #expect(f.map(\.category) == [.privateKey])
    #expect(f[0].range == 2..<(2 + pem.count))
  }
  @Test func creditCards() {
    #expect(cats("4111111111111111") == [.creditCard])
    #expect(cats("card 4111 1111 1111 1111.") == [.creditCard])
    #expect(cats("4111-1111-1111-1111") == [.creditCard])
  }

  @Test func falsePositives() {
    #expect(d.scan("Order number 1234567890123").isEmpty)  // 13 digits, non-Luhn
    #expect(d.scan("Call +1 (415) 555-0132 or 415-555-0132").isEmpty)
    #expect(d.scan("4111111111111112").isEmpty)
    #expect(d.scan("0000000000000000").isEmpty)
    #expect(d.scan("sk-short and AKIA123 and just some prose").isEmpty)
    #expect(d.scan("").isEmpty)
  }

  @Test func offsetsAreCharacterBased() {
    let text = "🙂é sk-proj-FAKEFAKEFAKEFAKEFAKE1234"
    let f = d.scan(text)
    #expect(f.count == 1)
    #expect(f[0].range.lowerBound == 3)
    #expect(f[0].range.upperBound == text.count)
  }

  @Test func mask() {
    let text = "k=sk-proj-FAKEFAKEFAKEFAKEFAKE1234 c=4111 1111 1111 1111 end"
    let masked = d.mask(text, findings: d.scan(text))
    #expect(masked == "k=sk-•••••••• c=••••••••1111 end")
    #expect(!masked.contains("FAKE"))
  }

  // MARK: - False positives that used to cost user data (review F5)

  @Test(arguments: [
    "token: v1.2.3-beta4",
    "version_token=2.10.0",
    "private_key_path=id_rsa2048.pem",
    "PRIVATE_KEY_FILE=certs/server2.key",
    "privateKeyPath: deploy01.pem",
    "passwordless=enabled123",
    "PASSWORDLESS=enabled123",
    "tokenizer=bert2base",
    "password_hint=first pet + 1999",
    "IMEI 490154203237518",
    "IMEI: 49-015420-323751-8",
    "imei_number=490154203237518",
    // Placeholders and versions that must stay clean after the round-3 narrowing (review R3).
    "DB_PASSWORD=$DB_PASSWORD_FROM_ENV",
    "password: ${DB_PASSWORD}",
    "api_key: your_api_key_here1",
    "API_KEY=YOUR-API-KEY-123",
    "token: yourtoken123",
    "postgres://app:$PGPASSWORD@db.internal:5432/x",
    "release_token=1.4.2-rc.1",
    "version_token=v2.0.0-beta.3+20240101",
    "secret_file=certs/prod2.pem",
  ])
  func ordinaryDataIsNotFlagged(_ text: String) {
    #expect(cats(text).isEmpty, "\(text)")
  }

  @Test(arguments: [
    "secret_key=Fk8sQ2vLx9Pz",
    "clientSecret: Fk8sQ2vLx9Pz",
    "secretKey=Fk8sQ2vLx9Pz",
    "DB_PASSWORD=Fk8sQ2vLx9Pz",
    "passwords=Fk8sQ2vLx9Pz",
    "api_key: \"Fk8sQ2vLx9Pz\"",
    "access_token=Fk8sQ2vLx9Pz.v2",
    "password=1.2.3abcXYZ!",
    "card 4111 1111 1111 1111 (IMEI field left blank)",
    // Round-3 false negatives (review R3): realistic secrets the false-positive guards let through.
    "api_token=1.0-Xk29fLq8ZpWm3NvB7rTy",
    "SECRET_KEY=1.2.AbCdEf9GhIjKlMnOp",
    "AUTH_TOKEN=2.0.8f7e6d5c4b3a29181716",
    "IMEI field, card 4111111111111111",
    "password = hunter2.txt",
    "password: Summer2024.json",
    "DB_PASSWORD=$uperS3cret9",
    "postgres://app:$tr0ngPass@db.internal:5432/x",
    "password: Yours3cret!2024",
    "api_key: your9Kx2mPq7Lz",
  ])
  func realSecretsStillFlagged(_ text: String) {
    #expect(!cats(text).isEmpty, "\(text)")
  }

  /// The secret value is masked as a whole, not only up to an `&` inside it (review R13); a query
  /// string's next parameter is still not part of the value.
  @Test func ampersandInsidePasswordIsMasked() {
    let text = "PASSWORD=Tr0ub4dor&3"
    #expect(SecretDetector().mask(text, findings: SecretDetector().scan(text)) == "PASSWORD=••••••••")
    let query = "https://x.example/cb?access_token=Fk8sQ2vLx9Pz&user=bob"
    #expect(SecretDetector().mask(query, findings: SecretDetector().scan(query)).hasSuffix("&user=bob"))
  }
}
