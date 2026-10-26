import Foundation

/// Removes formatting from copied text: ANSI escapes, HTML tags, Markdown syntax, invisible
/// characters, non-breaking spaces and smart quotes, plus trailing whitespace and extra blank lines.
public struct StripFormatting: Transform {
  public init() {}
  public let id = "strip-formatting"
  public let title = "Strip formatting (plain text)"

  private static let invisible: Set<Unicode.Scalar> = [
    "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00A0}", "\u{202F}", "\u{2007}",
    "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}",
  ]

  public func canApply(to text: String) -> Bool {
    guard text.utf8.count <= transformMaxInputBytes else { return false }
    let head = String(text.prefix(100_000))
    if head.contains("\u{1B}[") { return true }
    if head.unicodeScalars.contains(where: { Self.invisible.contains($0) }) { return true }
    if head.contains("**") || head.contains("](") || head.contains("```") { return true }
    return HTMLParsing.looksLikeHTML(head)
  }

  public func apply(to text: String) throws -> String {
    guard text.utf8.count <= transformMaxInputBytes else { throw TransformError.invalidInput("Input too large") }
    var s = Self.stripANSI(text)
    if HTMLParsing.looksLikeHTML(s) { s = try HTMLToMarkdown.convert(s, escape: false) }
    s = Self.stripMarkdown(s)
    // `replace` skips its pass once the run is cancelled; report that instead of partial output.
    if TransformRunner.isCancelled { throw CancellationError() }
    s = Self.normalizeCharacters(s)
    let lines = s.components(separatedBy: .newlines).map { line -> String in
      var l = Substring(line)
      while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
      return String(l)
    }
    var out = lines.joined(separator: "\n")
    while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !out.isEmpty else { throw TransformError.noContent }
    return out
  }

  private static func replace(_ s: String, _ pattern: String, _ template: String,
                              options: NSRegularExpression.Options = []) -> String {
    // Each pass can take a while on a large input, so an abandoned run stops between passes.
    guard !TransformRunner.isCancelled, let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
    return re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: template)
  }

  static func stripANSI(_ s: String) -> String {
    guard s.contains("\u{1B}") else { return s }
    var out = replace(s, #"\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, "")
    out = replace(out, #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, "")
    return out
  }

  // Every span below is linear: it excludes `\n` and its own opening delimiter, so a scan from an
  // unclosed opener stops at the next opener instead of re-reading the rest of the input.
  static func stripMarkdown(_ s: String) -> String {
    var out = s
    out = replace(out, #"^[ \t]*(```|~~~)[^\n]*\n?"#, "", options: [.anchorsMatchLines])
    out = replace(out, #"!\[([^\[\]\n]*)\]\([^()\[\n]*\)"#, "$1")
    out = replace(out, #"\[([^\[\]\n]+)\]\([^()\[\s]*(\s+"[^"\n]{0,500}")?\)"#, "$1")
    out = stripHeadings(out)
    out = replace(out, #"^[ \t]*>[ \t]?"#, "", options: [.anchorsMatchLines])
    out = replace(out, #"^[ \t]*([-*_][ \t]*){3,}$"#, "", options: [.anchorsMatchLines])
    out = replace(out, #"\*\*\*([^\s*](?:[^*\n]*?[^\s*])?)\*\*\*"#, "$1")
    out = replace(out, #"\*\*([^\s*](?:(?:[^*\n]|\*(?!\*))*?[^\s*])?)\*\*"#, "$1")
    out = replace(out, #"(?<!\w)__([^\s_](?:(?:[^_\n]|_(?!_))*?[^\s_])?)__(?!\w)"#, "$1")
    out = replace(out, #"(?<![\*\w])\*(?![\s\*])([^*\n]+?)(?<![\s\*])\*(?![\*\w])"#, "$1")
    out = replace(out, #"(?<![_\w])_(?![\s_])([^_\n]+?)(?<![\s_])_(?![_\w])"#, "$1")
    out = replace(out, #"~~([^\s~](?:(?:[^~\n]|~(?!~))*?[^\s~])?)~~"#, "$1")
    out = replace(out, #"`([^`\n]+)`"#, "$1")
    return out
  }

  /// ATX headings (`## Title ##` → `Title`). Done by hand: the equivalent regex backtracks
  /// quadratically on long runs of spaces.
  static func stripHeadings(_ s: String) -> String {
    guard s.contains("#") else { return s }
    func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
    let lines = s.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
      var rest = Substring.UnicodeScalarView(line)
      var cr = false
      if rest.last == "\r" { rest.removeLast(); cr = true }
      var indent = 0
      while indent < 3, let f = rest.first, isBlank(f) { rest.removeFirst(); indent += 1 }
      var level = 0
      while level < 7, rest.first == "#" { rest.removeFirst(); level += 1 }
      guard (1...6).contains(level), let f = rest.first, isBlank(f) else { return String(line) }
      while let f = rest.first, isBlank(f) { rest.removeFirst() }
      while let l = rest.last, isBlank(l) { rest.removeLast() }
      // Optional closing sequence: blanks then `#`s at the end of the line.
      var closing = rest
      while closing.last == "#" { closing.removeLast() }
      if closing.count < rest.count, let l = closing.last, isBlank(l) {
        while let l = closing.last, isBlank(l) { closing.removeLast() }
        rest = closing
      }
      return String(rest) + (cr ? "\r" : "")
    }
    return lines.joined(separator: "\n")
  }

  static func normalizeCharacters(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
      switch u {
      case "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}": continue
      case "\u{00A0}", "\u{202F}", "\u{2007}": out.append(" ")
      case "\u{2018}", "\u{2019}": out.append("'")
      case "\u{201C}", "\u{201D}": out.append("\"")
      default: out.append(u)
      }
    }
    return String(out)
  }
}
