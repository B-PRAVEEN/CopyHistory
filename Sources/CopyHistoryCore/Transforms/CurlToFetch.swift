import Foundation

/// cURL command → `fetch(...)` call. Credentials (-u, headers, cookies) are kept exactly as written.
public struct CurlToFetch: Transform {
  public init() {}
  public let id = "curl-to-fetch"
  public let title = "cURL → fetch"

  public func canApply(to text: String) -> Bool {
    var t = Substring(text.prefix(2000).drop(while: { $0.isWhitespace }))
    if t.hasPrefix("$ ") { t = t.dropFirst(2).drop(while: { $0.isWhitespace }) }
    guard t.hasPrefix("curl") else { return false }
    let rest = t.dropFirst(4)
    guard let next = rest.first, next.isWhitespace else { return false }
    return !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public func apply(to text: String) throws -> String {
    guard text.utf8.count <= transformMaxInputBytes else { throw TransformError.invalidInput("Input too large") }
    var tokens = try ShellTokenizer.tokenize(text)
    if tokens.first?.value == "$", tokens.first?.quoted == false { tokens.removeFirst() }
    if let stop = tokens.firstIndex(where: { !$0.quoted && ["|", "||", "&&", ";", ">", ">>", "&"].contains($0.value) }) {
      tokens = Array(tokens[..<stop])
    }
    guard let head = tokens.first, head.value == "curl" || head.value == "curl.exe" else {
      throw TransformError.invalidInput("Not a curl command")
    }
    var req = CurlRequest()
    try req.parse(Array(tokens.dropFirst().map(\.value)))
    return try req.render()
  }
}

struct ShellToken: Equatable {
  var value: String
  var quoted: Bool
}

enum ShellTokenizer {
  static func tokenize(_ text: String) throws -> [ShellToken] {
    let s = Array(text)
    var tokens: [ShellToken] = []
    var cur = ""
    var has = false
    var quoted = false
    var i = 0

    func isNewline(_ c: Character) -> Bool { c == "\n" || c == "\r" || c == "\r\n" }
    func flush() {
      if has { tokens.append(ShellToken(value: cur, quoted: quoted)) }
      cur = ""; has = false; quoted = false
    }

    while i < s.count {
      let c = s[i]
      switch c {
      case "\\":
        if i + 1 < s.count {
          let n = s[i + 1]
          if !isNewline(n) { cur.append(n); has = true }
          i += 2
        } else {
          i += 1
        }
      case "'":
        guard let end = s[(i + 1)...].firstIndex(of: "'") else {
          throw TransformError.invalidInput("Unterminated single quote")
        }
        cur += String(s[(i + 1)..<end]); has = true; quoted = true
        i = end + 1
      case "\"":
        i += 1
        var closed = false
        while i < s.count {
          let d = s[i]
          if d == "\"" { closed = true; i += 1; break }
          if d == "\\", i + 1 < s.count {
            let n = s[i + 1]
            if n == "\"" || n == "\\" || n == "$" || n == "`" { cur.append(n); i += 2; continue }
            if isNewline(n) { i += 2; continue }
          }
          cur.append(d); i += 1
        }
        guard closed else { throw TransformError.invalidInput("Unterminated double quote") }
        has = true; quoted = true
      case "$" where i + 1 < s.count && s[i + 1] == "'":
        i += 2
        var closed = false
        while i < s.count {
          let d = s[i]
          if d == "'" { closed = true; i += 1; break }
          if d == "\\", i + 1 < s.count {
            let n = s[i + 1]
            i += 2
            switch n {
            case "n": cur.append("\n")
            case "t": cur.append("\t")
            case "r": cur.append("\r")
            case "a", "b", "f", "v":
              break
            case "e": cur.append("\u{1B}")
            case "\\", "'", "\"": cur.append(n)
            case "x", "u", "U":
              let maxDigits = n == "x" ? 2 : (n == "u" ? 4 : 8)
              var digits = ""
              while digits.count < maxDigits, i < s.count, s[i].isHexDigit { digits.append(s[i]); i += 1 }
              if let v = UInt32(digits, radix: 16), let u = Unicode.Scalar(v) { cur.unicodeScalars.append(u) }
            default: cur.append("\\"); cur.append(n)
            }
            continue
          }
          cur.append(d); i += 1
        }
        guard closed else { throw TransformError.invalidInput("Unterminated $'...' string") }
        has = true; quoted = true
      default:
        if c.isWhitespace { flush() } else { cur.append(c); has = true }
        i += 1
      }
    }
    flush()
    return tokens
  }
}

struct CurlRequest {
  var url: String?
  var positionals: [String] = []
  var method: String?
  var headers: [(name: String, value: String)] = []  // value is already a JS expression
  /// Authorization from `-u` / `--oauth2-bearer` (last wins). An explicit `-H Authorization` beats
  /// it, and it beats credentials embedded in the URL, as in curl.
  var optionAuth: (index: Int, value: String)?  // index: header position when first given
  var dataParts: [String] = []
  var queryParts: [String] = []
  var usedJSONFlag = false
  var getMode = false
  var head = false

  private static let shortWithArg: Set<Character> = ["X", "H", "d", "u", "b", "A", "e", "F", "o", "m", "w", "x", "T", "c", "K", "E", "Y", "y", "r", "z", "C", "D", "t", "P", "Q", "U"]
  private static let longWithArg: Set<String> = [
    "request", "header", "data", "data-raw", "data-binary", "data-ascii", "data-urlencode", "user", "cookie",
    "user-agent", "referer", "url", "json", "form", "output", "max-time", "connect-timeout", "proxy", "cacert",
    "cert", "key", "write-out", "retry", "limit-rate", "cookie-jar", "config", "proxy-user", "range",
    "time-cond", "resolve", "interface", "dump-header", "upload-file", "retry-delay", "retry-max-time",
    "oauth2-bearer", "url-query", "form-string", "aws-sigv4", "max-redirs", "noproxy", "unix-socket",
    "abstract-unix-socket", "cert-type", "key-type", "pass", "ciphers", "tls13-ciphers", "curves",
    "request-target", "variable", "happy-eyeballs-timeout-ms", "expect100-timeout", "local-port",
    "proxy-header", "connect-to", "continue-at", "keepalive-time", "dns-servers", "dns-interface",
    "dns-ipv4-addr", "dns-ipv6-addr", "doh-url", "ftp-port", "quote", "telnet-option", "speed-limit",
    "speed-time", "max-filesize", "rate", "tls-max", "netrc-file", "trace", "trace-ascii", "stderr",
    "output-dir", "create-file-mode", "capath", "crlfile", "pinnedpubkey", "proxy-cacert", "proxy-capath",
    "proxy-cert", "proxy-cert-type", "proxy-key", "proxy-key-type", "proxy-pass", "proxy-ciphers",
    "proxy-tls13-ciphers", "proxy-crlfile", "proxy-pinnedpubkey", "proxy-service-name", "proxy-tlsuser",
    "proxy-tlspassword", "proxy-tlsauthtype", "socks4", "socks4a", "socks5", "socks5-hostname",
    "socks5-gssapi-service", "preproxy", "login-options", "sasl-authzid", "service-name", "mail-from",
    "mail-rcpt", "mail-auth", "tlsuser", "tlspassword", "tlsauthtype", "random-file", "egd-file", "engine",
    "delegation", "hostpubmd5", "hostpubsha256", "pubkey", "krb", "ftp-account", "ftp-alternative-to-user",
    "ftp-method", "ftp-ssl-ccc-mode", "alt-svc", "hsts", "etag-save", "etag-compare", "parallel-max",
    "header-file", "proto", "proto-redir", "proto-default", "ech", "ip-tos", "vlan-priority", "mptcp-path",
    "ssl-sessions", "write-out", "config", "expand-url", "expand-data", "expand-header", "expand-user",
  ]
  /// Common long options that take no value. Any other unknown option followed by a value-like
  /// token is refused rather than guessed (the token is often a secret, and must not become the URL).
  private static let longFlags: Set<String> = [
    "compressed", "insecure", "silent", "show-error", "location", "location-trusted", "verbose", "include",
    "fail", "fail-with-body", "fail-early", "globoff", "no-buffer", "no-keepalive", "no-sessionid",
    "progress-bar", "raw", "http0.9", "http1.0", "http1.1", "http2", "http2-prior-knowledge", "http3",
    "http3-only", "ipv4", "ipv6", "tlsv1", "tlsv1.0", "tlsv1.1", "tlsv1.2", "tlsv1.3", "sslv2", "sslv3",
    "ssl", "ssl-reqd", "ssl-no-revoke", "ssl-allow-beast", "ssl-revoke-best-effort", "basic", "digest",
    "ntlm", "ntlm-wb", "negotiate", "anyauth", "netrc", "netrc-optional", "remote-name", "remote-name-all",
    "remote-header-name", "remote-time", "create-dirs", "path-as-is", "post301", "post302", "post303",
    "proxy-insecure", "proxytunnel", "proxy-basic", "proxy-digest", "proxy-ntlm", "proxy-negotiate",
    "proxy-anyauth", "tcp-nodelay", "tcp-fastopen", "tr-encoding", "junk-session-cookies", "disable",
    "disallow-username-in-url", "styled-output", "suppress-connect-headers", "retry-connrefused",
    "retry-all-errors", "parallel", "parallel-immediate", "no-progress-meter", "manual", "help", "version",
    "append", "list-only", "use-ascii", "crlf", "ftp-pasv", "ftp-create-dirs", "ftp-skip-pasv-ip",
    "ftp-ssl-control", "ftp-pret", "ignore-content-length", "false-start", "sasl-ir", "xattr", "doh-insecure",
    "cert-status", "ca-native", "proxy-ca-native", "no-npn", "no-alpn", "skip-existing", "clobber",
    "no-clobber", "ssl-auto-client-cert", "metalink", "next", "trace-time", "trace-ids", "dump-ca-embed",
    "remove-on-error", "mail-rcpt-allowfails", "haproxy-protocol", "include-headers",
  ]

  static func looksLikeURL(_ s: String) -> Bool {
    if s.contains("://") || s.hasPrefix("localhost") || s.hasPrefix("[") { return true }
    let host = s.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    return host.contains(".") && host.first.map { $0.isLetter || $0.isNumber } == true
  }

  mutating func setHeader(_ name: String, _ jsValue: String, onlyIfAbsent: Bool = false) {
    if let i = headers.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
      if !onlyIfAbsent { headers[i] = (name, jsValue) }
    } else {
      headers.append((name, jsValue))
    }
  }

  private mutating func setOptionAuth(_ jsValue: String) {
    optionAuth = (optionAuth?.index ?? headers.count, jsValue)
  }

  private mutating func addHeader(_ raw: String) {
    guard let colon = raw.firstIndex(of: ":") else {
      if raw.hasSuffix(";") { setHeader(String(raw.dropLast()).trimmingCharacters(in: .whitespaces), jsStringLiteral("")) }
      return
    }
    let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
    let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !value.isEmpty else { return }  // `Name:` removes a header in curl
    setHeader(name, jsStringLiteral(value))
  }

  private mutating func apply(option: String, value: String) throws {
    switch option {
    case "X", "request": method = value.uppercased()
    case "H", "header": addHeader(value)
    case "d", "data", "data-ascii", "data-binary", "data-raw":
      if option != "data-raw", value.hasPrefix("@") { throw TransformError.unsupported("request body read from a file (\(value))") }
      dataParts.append(value)
    case "data-urlencode":
      dataParts.append(Self.urlEncodeData(value))
    case "json":
      if value.hasPrefix("@") { throw TransformError.unsupported("request body read from a file (\(value))") }
      dataParts.append(value)
      usedJSONFlag = true
    case "u", "user":
      let creds = value.contains(":") ? value : value + ":"
      setOptionAuth("\"Basic \" + btoa(\(jsStringLiteral(creds)))")
    case "oauth2-bearer":
      setOptionAuth(jsStringLiteral("Bearer " + value))
    case "url-query":
      if value.hasPrefix("@") || value.contains("=@") || value.hasPrefix("+@") {
        throw TransformError.unsupported("query read from a file")
      }
      queryParts.append(value.hasPrefix("+") ? String(value.dropFirst()) : Self.urlEncodeData(value))
    case "b", "cookie":
      if value.contains("=") { setHeader("Cookie", jsStringLiteral(value)) }
    case "A", "user-agent": setHeader("User-Agent", jsStringLiteral(value))
    case "e", "referer": setHeader("Referer", jsStringLiteral(value))
    case "url": if url == nil { url = value }
    case "F", "form", "form-string": throw TransformError.unsupported("multipart form data (-F)")
    default: break  // options that take a value but do not affect fetch (-o, -m, --proxy, ...)
    }
  }

  private static func urlEncodeData(_ v: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
    if let eq = v.firstIndex(of: "="), eq != v.startIndex {
      return String(v[..<eq]) + "=" + enc(String(v[v.index(after: eq)...]))
    }
    if v.hasPrefix("=") { return enc(String(v.dropFirst())) }
    return enc(v)
  }

  mutating func parse(_ args: [String]) throws {
    var i = 0
    func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
    while i < args.count {
      let a = args[i]
      if a.hasPrefix("--"), a.count > 2 {
        var name = String(a.dropFirst(2))
        var inline: String?
        if let eq = name.firstIndex(of: "=") {
          inline = String(name[name.index(after: eq)...])
          name = String(name[..<eq])
        }
        switch name {
        case "get": getMode = true
        case "head": head = true
        default:
          if Self.longWithArg.contains(name) {
            guard let v = inline ?? next() else { throw TransformError.invalidInput("Option --\(name) needs a value") }
            try apply(option: name, value: v)
          } else if inline == nil, !Self.longFlags.contains(name), !name.hasPrefix("no-"),
                    i + 1 < args.count, !args[i + 1].hasPrefix("-"), !Self.looksLikeURL(args[i + 1]) {
            // Never echo the value: it is often a credential.
            throw TransformError.unsupported("unknown option --\(name)")
          }
        }
      } else if a.hasPrefix("-"), a.count > 1 {
        let chars = Array(a.dropFirst())
        var k = 0
        while k < chars.count {
          let c = chars[k]
          if Self.shortWithArg.contains(c) {
            let rest = String(chars[(k + 1)...])
            guard let v = rest.isEmpty ? next() : rest else { throw TransformError.invalidInput("Option -\(c) needs a value") }
            try apply(option: String(c), value: v)
            break
          }
          if c == "G" { getMode = true }
          if c == "I" { head = true }
          k += 1
        }
      } else {
        positionals.append(a)
      }
      i += 1
    }
  }

  func render() throws -> String {
    let chosen = url ?? positionals.first(where: Self.looksLikeURL) ?? positionals.first
    guard var target = chosen, !target.isEmpty else { throw TransformError.invalidInput("No URL found in curl command") }
    if !target.contains("://") { target = "http://" + target }
    let urlCredentials = Self.stripCredentials(&target)

    var body: String? = dataParts.isEmpty ? nil : dataParts.joined(separator: "&")
    var headers = self.headers
    func hasHeader(_ n: String) -> Bool { headers.contains { $0.name.lowercased() == n } }
    if !hasHeader("authorization") {
      if let auth = optionAuth {
        headers.insert(("Authorization", auth.value), at: min(auth.index, headers.count))
      } else if let creds = urlCredentials {
        headers.append(("Authorization", "\"Basic \" + btoa(\(jsStringLiteral(creds)))"))
      }
    }
    var query = queryParts
    if getMode, let b = body {
      query.insert(b, at: 0)
      body = nil
    }
    if !query.isEmpty {
      let fragment = target.firstIndex(of: "#").map { String(target[$0...]) } ?? ""
      target = String(target.dropLast(fragment.count))
      target += (target.contains("?") ? "&" : "?") + query.joined(separator: "&") + fragment
    }
    if usedJSONFlag {
      if !hasHeader("content-type") { headers.append(("Content-Type", jsStringLiteral("application/json"))) }
      if !hasHeader("accept") { headers.append(("Accept", jsStringLiteral("application/json"))) }
    } else if body != nil, !hasHeader("content-type") {
      headers.append(("Content-Type", jsStringLiteral("application/x-www-form-urlencoded")))  // curl's default for -d
    }

    let verb = method ?? (head ? "HEAD" : (body != nil ? "POST" : "GET"))
    var options: [String] = []
    if verb != "GET" { options.append("  method: \(jsStringLiteral(verb))") }
    if !headers.isEmpty {
      let lines = headers.map { "    \(jsStringLiteral($0.name)): \($0.value)" }.joined(separator: ",\n")
      options.append("  headers: {\n\(lines)\n  }")
    }
    if let b = body {
      if let json = try? JSONParser.parse(b.trimmingCharacters(in: .whitespacesAndNewlines)), Self.isContainer(json) {
        options.append("  body: JSON.stringify(\(json.jsLiteral(indent: 2)))")
      } else {
        options.append("  body: \(jsStringLiteral(b))")
      }
    }
    let urlLiteral = jsStringLiteral(target)
    if options.isEmpty { return "fetch(\(urlLiteral));" }
    return "fetch(\(urlLiteral), {\n" + options.joined(separator: ",\n") + "\n});"
  }

  /// Removes `user:password@` from the URL (fetch rejects URLs with credentials) and returns the
  /// percent-decoded `user:password`, or nil when the URL has none.
  static func stripCredentials(_ target: inout String) -> String? {
    guard let scheme = target.range(of: "://") else { return nil }
    let authorityEnd = target[scheme.upperBound...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? target.endIndex
    guard let at = target[scheme.upperBound..<authorityEnd].lastIndex(of: "@") else { return nil }
    let userinfo = target[scheme.upperBound..<at]
    target.removeSubrange(scheme.upperBound...at)
    func decode<S: StringProtocol>(_ s: S) -> String { String(s).removingPercentEncoding ?? String(s) }
    if let colon = userinfo.firstIndex(of: ":") {
      return decode(userinfo[..<colon]) + ":" + decode(userinfo[userinfo.index(after: colon)...])
    }
    return decode(userinfo) + ":"
  }

  private static func isContainer(_ v: JSONValue) -> Bool {
    switch v {
    case .object, .array: return true
    default: return false
    }
  }
}
