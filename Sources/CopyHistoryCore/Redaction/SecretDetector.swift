import Foundation

public struct SecretDetector: SecretDetecting {
  private struct Rule: Sendable {
    let category: SecretFinding.Category
    let regex: NSRegularExpression
    let group: Int
    /// Extra check on the captured text; keeps the generic rules' false-positive rate low.
    let accept: @Sendable (String) -> Bool
    /// Optional capture group holding the key name of an assignment, and a check on it.
    let keyGroup: Int?
    let acceptKey: @Sendable (String) -> Bool
  }

  private static func rule(_ category: SecretFinding.Category, _ pattern: String, group: Int = 0,
                           keyGroup: Int? = nil,
                           acceptKey: @escaping @Sendable (String) -> Bool = { _ in true },
                           accept: @escaping @Sendable (String) -> Bool = { _ in true }) -> Rule {
    // Patterns are compile-time constants; a failure here is a programmer error.
    Rule(category: category, regex: try! NSRegularExpression(pattern: pattern), group: group, accept: accept,
         keyGroup: keyGroup, acceptKey: acceptKey)
  }

  // Every pattern must stay linear in the input length (clipboard text is attacker-controlled):
  // a leading lookbehind gives each run of token characters a single start, and quantifiers that
  // are followed by a character outside their class are possessive or bounded.
  // Order matters: when two rules hit the same range, the earlier rule wins.
  private static let rules: [Rule] = [
    rule(.jwt, #"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}+\.eyJ[A-Za-z0-9_-]{5,}+\.[A-Za-z0-9_-]*+"#),
    rule(.openAIKey, #"(?<![A-Za-z0-9])sk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}+"#),
    rule(.awsAccessKey, #"(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])"#),
    rule(.awsSecretKey, #"(?i)aws[\w .-]{0,30}secret[\w .-]{0,30}?[\s:="']{1,4}([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"#, group: 1),
    // STS / `aws iam create-access-key` JSON and the matching env/ini names.
    rule(.awsSecretKey, #"(?i)(?<![A-Za-z0-9])"?SecretAccessKey"?[ \t]{0,3}[:=][ \t]{0,3}"?([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"#, group: 1),
    rule(.genericSecret, #"(?i)(?<![A-Za-z0-9])"?(?:SessionToken|aws_session_token|aws_security_token)"?[ \t]{0,3}[:=][ \t]{0,3}"?([A-Za-z0-9/+=]{16,}+)"#, group: 1),
    rule(.githubToken, #"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{36,}+"#),
    rule(.githubToken, #"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{22,}+"#),
    rule(.slackToken, #"(?<![A-Za-z0-9])xox[abeprs]-[A-Za-z0-9-]{10,}+"#),
    rule(.slackToken, #"(?<![A-Za-z0-9])xapp-[0-9]-[A-Za-z0-9-]{10,}+"#),
    rule(.slackToken, #"https://hooks\.slack\.com/(?:services|workflows|triggers)/[A-Za-z0-9_/-]{20,}+"#),
    rule(.genericSecret, #"(?<![A-Za-z0-9])[rs]k_(?:live|test)_[A-Za-z0-9]{16,}+"#),
    rule(.genericSecret, #"(?<![A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?![A-Za-z0-9_-])"#),
    rule(.genericSecret, #"(?i)(?<![A-Za-z0-9])bearer[ \t]++([A-Za-z0-9._~+/-]{16,}+=*+)"#, group: 1,
         accept: looksRandom),
    // Credentials embedded in a URL: scheme://user:PASSWORD@host
    rule(.genericSecret, #"(?i)(?<![A-Za-z0-9+.-])[a-z][a-z0-9+.-]{0,20}+://[^\s:/@]{1,256}+:([^\s@/]{1,256}+)@"#,
         group: 1, accept: { !isPlaceholder($0) }),
    // .env / YAML / JSON / ini assignments whose key names a secret: PASSWORD=..., "api_key": "...".
    rule(.genericSecret,
         #"(?i)(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]{0,64}?(?:secret|passw(?:or)?d|pwd|token|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_.-]{0,64}?)["']?[ \t]{0,3}[:=][ \t]{0,3}["']?((?:[^\s"',;&]|&(?![A-Za-z_][A-Za-z0-9_.-]{0,64}=)){8,1024}+)"#,
         group: 2, keyGroup: 1, acceptKey: isSecretKeyName, accept: looksRandom),
  ]

  private static let cardCandidate = try! NSRegularExpression(pattern: #"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#)
  private static let imeiLabel = try! NSRegularExpression(
    pattern: #"(?i)(?<![A-Za-z])imei(?:[ _-]?(?:no|num|number|#))?\.?["']?[ \t:#=]*+$"#)
  private static let keyBegin = try! NSRegularExpression(
    pattern: #"-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?(?:-----)?"#)
  private static let keyEnd = try! NSRegularExpression(
    pattern: #"-----END [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----"#)

  /// Callers must not scan more than this many UTF-16 units on a latency-sensitive path: scanning is
  /// linear but costs up to ~1 s/MB for adversarial input. Longer text is treated as unscannable.
  public static let maxScanLength = 512 * 1024

  public init() {}

  public func scan(_ text: String) -> [SecretFinding] {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    var hits: [(range: Swift.Range<Int>, category: SecretFinding.Category, priority: Int)] = []  // UTF-16 offsets

    // Private keys: pair each BEGIN with the next END in one forward pass; an unterminated
    // (e.g. partially selected) key is masked to the end of the text.
    let ends = Self.keyEnd.matches(in: text, range: full).map { $0.range.location + $0.range.length }
    var e = 0
    for m in Self.keyBegin.matches(in: text, range: full) {
      let start = m.range.location
      while e < ends.count && ends[e] <= start + m.range.length { e += 1 }
      hits.append((start..<(e < ends.count ? ends[e] : ns.length), .privateKey, -1))
    }

    for (i, rule) in Self.rules.enumerated() {
      for m in rule.regex.matches(in: text, range: full) {
        let r = m.range(at: rule.group)
        guard r.location != NSNotFound, rule.accept(ns.substring(with: r)) else { continue }
        if let kg = rule.keyGroup {
          let k = m.range(at: kg)
          guard k.location != NSNotFound, rule.acceptKey(ns.substring(with: k)) else { continue }
        }
        hits.append((r.location..<(r.location + r.length), rule.category, i))
      }
    }
    for m in Self.cardCandidate.matches(in: text, range: full) {
      // The pattern only admits ASCII digits; never trust that with a force-unwrap.
      let digits = ns.substring(with: m.range).unicodeScalars.compactMap { s -> Int? in
        s.isASCII && ("0"..."9").contains(s) ? Int(s.value) - 48 : nil
      }
      guard (13...19).contains(digits.count), Set(digits).count > 1, Self.luhnValid(digits) else { continue }
      // Every IMEI passes Luhn too; a number labelled as one is a device id, not a card. The label
      // must be the number's own (`IMEI: 4901…`), not just nearby text (`IMEI field, card 4111…`).
      let back = min(m.range.location, 24)
      let before = ns.substring(with: NSRange(location: m.range.location - back, length: back))
      if Self.imeiLabel.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil { continue }
      hits.append((m.range.location..<(m.range.location + m.range.length), .creditCard, Self.rules.count))
    }

    // Earlier start wins, then longer, then earlier rule. An overlapping later hit extends the
    // kept one so no tail of a secret is left visible.
    hits.sort {
      if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
      if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
      return $0.priority < $1.priority
    }
    var kept: [(range: Swift.Range<Int>, category: SecretFinding.Category)] = []
    for h in hits {
      if let last = kept.last, h.range.lowerBound < last.range.upperBound {
        if h.range.upperBound > last.range.upperBound {
          kept[kept.count - 1].range = last.range.lowerBound..<h.range.upperBound
        }
      } else {
        kept.append((h.range, h.category))
      }
    }
    guard !kept.isEmpty else { return [] }

    // Convert UTF-16 offsets to Character offsets: floor the start and round the end up to a
    // grapheme boundary, so a match ending inside a cluster still covers the whole cluster.
    var starts: [Int] = []  // UTF-16 offset of each Character, plus the total length
    starts.reserveCapacity(text.count + 1)
    var utf16 = 0
    for ch in text { starts.append(utf16); utf16 += ch.utf16.count }
    starts.append(utf16)
    func ceilIndex(_ u: Int) -> Int {
      var lo = 0, hi = starts.count - 1
      while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < u { lo = mid + 1 } else { hi = mid } }
      return lo
    }
    func floorIndex(_ u: Int) -> Int { let c = ceilIndex(u); return starts[c] == u ? c : c - 1 }
    return kept.map {
      SecretFinding(category: $0.category, range: floorIndex($0.range.lowerBound)..<ceilIndex($0.range.upperBound))
    }
  }

  private static let keptPrefixes = ["sk_live_", "sk_test_", "rk_live_", "rk_test_", "AIza", "https://hooks.slack.com/"]

  public func mask(_ text: String, findings: [SecretFinding]) -> String {
    let chars = Array(text)
    var out = ""
    var pos = 0
    for f in findings.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
      let lo = max(f.range.lowerBound, pos), hi = min(f.range.upperBound, chars.count)
      guard lo < hi else { continue }
      out += String(chars[pos..<lo])
      let value = String(chars[lo..<hi])
      let known = Self.keptPrefixes.first { value.hasPrefix($0) && value.count > $0.count + 8 }
      switch f.category {
      case .creditCard: out += "••••••••" + String(value.suffix(4))
      case .privateKey: out += "-----BEGIN PRIVATE KEY-----••••••••"
      case .openAIKey: out += "sk-••••••••"
      case .awsAccessKey: out += String(value.prefix(4)) + "••••••••"
      case .githubToken: out += (value.hasPrefix("github_pat_") ? "github_pat_" : String(value.prefix(4))) + "••••••••"
      case .slackToken: out += (known ?? String(value.prefix(5))) + "••••••••"
      case .jwt: out += "eyJ••••••••"
      case .awsSecretKey: out += "••••••••"
      case .genericSecret: out += (known ?? "") + "••••••••"
      }
      pos = hi
    }
    if pos < chars.count { out += String(chars[pos...]) }
    return out
  }

  /// Values like `${DB_PASSWORD}`, `$DB_PASSWORD`, `<your-token>`, `your_api_key`, `********` or
  /// `changeme` are not secrets. A value merely starting with `$` or `your` (`$uperS3cret9`,
  /// `Yours3cret!2024`) can be.
  static func isPlaceholder(_ v: String) -> Bool {
    let lower = v.lowercased()
    let whole = NSRange(location: 0, length: (v as NSString).length)
    if ["${", "$(", "{{", "<", "%("].contains(where: { lower.hasPrefix($0) })
      || envReference.firstMatch(in: v, range: whole) != nil || yourPlaceholder.firstMatch(in: v, range: whole) != nil
      || lower.contains("•") || lower.contains("***") || Set(lower).count <= 2 { return true }
    return ["password", "passwd", "secret", "token", "changeme", "example", "placeholder", "redacted",
            "dummy", "undefined", "null", "none", "true", "false"].contains(lower)
  }

  /// `$NAME`: a shell/env reference, upper case as env names are by convention.
  private static let envReference = try! NSRegularExpression(pattern: #"^\$[A-Z_][A-Z0-9_]*$"#)
  /// `your` as its own word (`your_token`, `your-api-key`, `yourpassword`), not a prefix of the value.
  private static let yourPlaceholder = try! NSRegularExpression(
    pattern: #"(?i)^your(?:[_. -]|(?:own|app|api|access|client|secret|token|key|pass|pw|auth|private|db|aws|github|slack)(?:[^a-z]|$|[a-z]*$))"#)

  private static let secretWord = try! NSRegularExpression(
    pattern: #"(?i)secret|passw(?:or)?d|pwd|token|api[_-]?key|access[_-]?key|private[_-]?key|credential"#)
  /// Lowercase continuations that turn the secret word into a different word (`passwordless`).
  private static let otherWordSuffixes: Set<String> = [
    "less", "ize", "izer", "izers", "ized", "izes", "izing", "ization", "ary", "aries", "ion", "ions", "ive",
  ]
  /// Key words that say the value describes a secret rather than being one (`private_key_path`).
  private static let metadataWords: Set<String> = [
    "path", "file", "filename", "dir", "directory", "name", "type", "length", "len", "count", "size", "ttl",
    "expiry", "expires", "expiration", "endpoint", "url", "uri", "version", "format", "policy", "hint",
    "field", "label", "prompt",
  ]

  /// Whether an assignment's key really names a secret. `secret_key`, `clientSecret`, `DB_PASSWORD`
  /// do; `passwordless`, `tokenizer`, `private_key_path`, `password_hint` don't.
  static func isSecretKeyName(_ key: String) -> Bool {
    let ns = key as NSString
    guard let m = secretWord.matches(in: key, range: NSRange(location: 0, length: ns.length)).last else { return true }
    let tail = ns.substring(from: m.range.location + m.range.length)
    // The word continues directly, in the same case (`passwordless`, `PASSWORDLESS`)? camelCase
    // (`secretKey`) starts a new word instead.
    let last = ns.substring(with: NSRange(location: m.range.location + m.range.length - 1, length: 1)).first!
    let attached = tail.first.map { $0.isLetter && $0.isUppercase == last.isUppercase } ?? false
    // Split at separators and camelCase humps: "_keyPath" -> ["key", "path"].
    var words: [String] = []
    var current = ""
    for ch in tail {
      if !ch.isLetter && !ch.isNumber {
        if !current.isEmpty { words.append(current.lowercased()); current = "" }
        continue
      }
      if ch.isUppercase, let prev = current.last, !prev.isUppercase { words.append(current.lowercased()); current = "" }
      current.append(ch)
    }
    if !current.isEmpty { words.append(current.lowercased()) }
    if attached, let first = words.first, otherWordSuffixes.contains(first) { return false }
    return !words.contains { metadataWords.contains($0) }
  }

  /// `1.2.3`, `v2.0.1-beta4`, `1.0.0-rc.1+20240101`: only a known pre-release label may follow the
  /// numbers, so `1.0-Xk29fLq8ZpWm3NvB7rTy` (random tail) is not a version.
  private static let versionLike = try! NSRegularExpression(
    pattern: #"(?i)^v?[0-9]+(?:\.[0-9]+){1,3}(?:[-.]?(?:alpha|beta|rc|dev|pre|preview|snapshot|final|release|ga|lts)[.0-9]*)?(?:\+[0-9.]{1,20})?$"#)
  /// A file name. Only when the name is a path (`certs/app2.pem`) or its stem has no letter/digit mix:
  /// `hunter2.txt` or `Summer2024.json` as a password value are passwords.
  private static let fileLike = try! NSRegularExpression(
    pattern: #"(?i)^(?:[A-Za-z0-9_.~-]*/[A-Za-z0-9_.~/-]*|[A-Za-z_.~-]+|[0-9_.~-]+)\.(?:pem|key|p12|pfx|crt|cer|der|pub|ppk|jks|keystore|json|txt|ya?ml|env|conf|cfg|ini|xml|plist|toml|gpg|asc)$"#)

  /// Generic assignments only count when the value looks like a credential rather than code or prose:
  /// it must mix letters with digits (or with password-style symbols) and not be an identifier path,
  /// call, URL, version number, file name or placeholder.
  static func looksRandom(_ v: String) -> Bool {
    guard v.count >= 8, !isPlaceholder(v), !v.contains("://"), !v.contains("("), !v.contains(")") else { return false }
    let whole = NSRange(location: 0, length: (v as NSString).length)
    if versionLike.firstMatch(in: v, range: whole) != nil || fileLike.firstMatch(in: v, range: whole) != nil { return false }
    // File paths (`PWD=/Users/a/projects2`, `private_key_path: ~/.ssh/id_ed25519`) name a secret, they aren't one.
    if ["/", "~/", "./", "../"].contains(where: { v.hasPrefix($0) }), v.filter({ $0 == "/" }).count >= 2,
       v.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._/~-".unicodeScalars.contains($0) }) {
      return false
    }
    let scalars = v.unicodeScalars
    let letters = scalars.contains { CharacterSet.letters.contains($0) }
    let digits = scalars.contains { $0.isASCII && ("0"..."9").contains($0) }
    let symbols = scalars.contains { "!@#$%^*+/=?~".unicodeScalars.contains($0) }
    return letters && (digits || symbols)
  }

  static func luhnValid(_ digits: [Int]) -> Bool {
    var sum = 0
    for (i, d) in digits.reversed().enumerated() {
      if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
    }
    return sum % 10 == 0
  }
}
