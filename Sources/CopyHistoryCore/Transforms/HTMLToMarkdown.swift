import Foundation

public struct HTMLToMarkdown: Transform {
  public init() {}
  public let id = "html-to-markdown"
  public let title = "HTML → Markdown"

  public func canApply(to text: String) -> Bool {
    HTMLParsing.looksLikeHTML(text)
  }

  public func apply(to text: String) throws -> String {
    try Self.convert(text, escape: true)
  }

  /// `escape: false` skips Markdown escaping of text (used when the result is stripped to plain text).
  static func convert(_ html: String, escape: Bool) throws -> String {
    guard html.utf8.count <= transformMaxInputBytes else { throw TransformError.invalidInput("Input too large") }
    // The renderer recurses once per nesting level; callers (e.g. test threads) may have small stacks.
    let out = try runWithLargeStack {
      let root = try HTMLParsing.parse(html)
      var w = MDWriter()
      let renderer = MarkdownRenderer(escape: escape)
      renderer.walkChildren(root, &w)
      if let error = renderer.stopError { throw error }
      if renderer.tableTooLarge { throw TransformError.invalidInput("Table too large") }
      guard w.out.utf8.count <= transformMaxOutputBytes else { throw TransformError.invalidInput("Output too large") }
      return w.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !out.isEmpty else { throw TransformError.noContent }
    return out
  }
}

private final class ResultBox<T>: @unchecked Sendable {
  var result: Result<T, Error>?
}

/// Runs `body` on a short-lived thread with a 32 MB stack and waits for it. The thread inherits the
/// caller's cancellation, so `TransformRunner.isCancelled` polls inside `body` see an abandoned run.
func runWithLargeStack<T>(_ body: @escaping @Sendable () throws -> T) throws -> T {
  let box = ResultBox<T>()
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    box.result = Result { try body() }
    done.signal()
  }
  thread.stackSize = 32 * 1024 * 1024
  TransformRunner.inheritCancellation(into: thread)
  thread.start()
  done.wait()
  return try box.result!.get()
}

// MARK: - Entities

enum HTMLEntities {
  static let named: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©",
    "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
    "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "laquo": "«", "raquo": "»", "euro": "€",
    "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷",
    "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "sect": "§", "para": "¶", "micro": "µ",
    "frac12": "½", "frac14": "¼", "frac34": "¾", "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞",
    "check": "✓", "hearts": "♥", "sbquo": "‚", "bdquo": "„", "dagger": "†", "permil": "‰",
  ]

  static func decode(_ s: String) -> String {
    guard s.contains("&") else { return s }
    let chars = Array(s)
    var out = ""
    var i = 0
    while i < chars.count {
      let c = chars[i]
      guard c == "&" else { out.append(c); i += 1; continue }
      var j = i + 1
      var name = ""
      while j < chars.count, j - i <= 32, chars[j] != ";", chars[j] != "&", chars[j] != "<", !chars[j].isWhitespace {
        name.append(chars[j]); j += 1
      }
      guard j < chars.count, chars[j] == ";", !name.isEmpty else { out.append(c); i += 1; continue }
      if name.hasPrefix("#") {
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
          value = UInt32(digits.dropFirst(), radix: 16)
        } else {
          value = UInt32(digits, radix: 10)
        }
        guard let v = value else { out.append(c); i += 1; continue }
        let scalar = (v == 0 ? nil : Unicode.Scalar(v)) ?? Unicode.Scalar(0xFFFD)!
        out.unicodeScalars.append(scalar)
        i = j + 1
      } else if let rep = named[name] {
        out += rep
        i = j + 1
      } else {
        out.append(c); i += 1
      }
    }
    return out
  }
}

// MARK: - Tokenizer + tolerant tree builder

final class HTMLNode {
  let tag: String  // "" for text nodes, "#root" for the root
  var attrs: [String: String]
  var text: String
  var children: [HTMLNode] = []
  init(tag: String, attrs: [String: String] = [:], text: String = "") {
    self.tag = tag; self.attrs = attrs; self.text = text
  }
}

enum HTMLToken {
  case text(String)
  case start(name: String, attrs: [String: String], selfClosing: Bool)
  case end(String)
}

enum HTMLParsing {
  static let knownTags: Set<String> = [
    "html", "head", "body", "div", "span", "p", "a", "br", "hr", "img", "ul", "ol", "li", "table", "thead",
    "tbody", "tfoot", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6", "b", "i", "em", "strong", "code",
    "pre", "blockquote", "section", "article", "header", "footer", "nav", "main", "aside", "figure",
    "figcaption", "u", "s", "del", "ins", "small", "sub", "sup", "mark", "kbd", "samp", "font", "center",
    "label", "input", "button", "form", "dl", "dt", "dd", "style", "script", "meta", "link", "title", "details", "summary",
  ]
  static let voidTags: Set<String> = [
    "br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr", "param",
  ]
  private static let skippedContent: Set<String> = ["script", "style", "title", "template"]
  private static let maxDepth = 100

  /// Cheap, conservative check: some `<known-tag ...>` or `</known-tag>` or doctype near the start.
  static func looksLikeHTML(_ text: String) -> Bool {
    let chars = Array(text.prefix(20_000))
    var i = 0
    while i < chars.count {
      if chars[i] == "<", i + 1 < chars.count {
        var j = i + 1
        if chars[j] == "!" {
          let rest = String(chars[j...].prefix(9)).lowercased()
          if rest.hasPrefix("!doctype") || rest.hasPrefix("!--") { return true }
        }
        if chars[j] == "/" { j += 1 }
        var name = ""
        while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber, name.count < 12 {
          name.append(Character(chars[j].lowercased())); j += 1
        }
        guard knownTags.contains(name), j < chars.count else { i += 1; continue }
        if chars[j] == ">" || chars[j] == "/" { return true }
        if chars[j] == " " || chars[j].isNewline {
          // `<b then c>` in prose is not a tag: require an attribute (`=`) before the closing `>`.
          var k = j
          while k < chars.count, k - j < 500, chars[k] != ">" {
            if chars[k] == "=" { return true }
            k += 1
          }
        }
      }
      i += 1
    }
    return false
  }

  static func parse(_ html: String) throws -> HTMLNode {
    try build(tokenize(html))
  }

  static func tokenize(_ html: String) throws -> [HTMLToken] {
    let s = Array(html)
    let n = s.count
    var tokens: [HTMLToken] = []
    var buf = ""
    var i = 0
    var poll = CancellationPoll()

    func flush() {
      if !buf.isEmpty { tokens.append(.text(HTMLEntities.decode(buf))); buf = "" }
    }
    func isNameChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == ":" || c == "_") }
    func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\r\n" || c == "\u{0C}" }

    /// Returns (token, nextIndex), or nil when the input ends before the tag is closed.
    func parseStartTag(_ at: Int) -> (HTMLToken, Int)? {
      var j = at + 1
      var name = ""
      while j < n, isNameChar(s[j]) { name += s[j].lowercased(); j += 1 }
      var attrs: [String: String] = [:]
      while true {
        while j < n, isSpace(s[j]) { j += 1 }
        guard j < n else { return nil }
        if s[j] == ">" { return (.start(name: name, attrs: attrs, selfClosing: false), j + 1) }
        if s[j] == "/" {
          if j + 1 < n, s[j + 1] == ">" { return (.start(name: name, attrs: attrs, selfClosing: true), j + 2) }
          j += 1
          continue
        }
        var key = ""
        while j < n, !isSpace(s[j]), s[j] != "=", s[j] != ">", !(s[j] == "/" && j + 1 < n && s[j + 1] == ">") {
          key += s[j].lowercased(); j += 1
        }
        if key.isEmpty { j += 1; continue }
        while j < n, isSpace(s[j]) { j += 1 }
        var value = ""
        if j < n, s[j] == "=" {
          j += 1
          while j < n, isSpace(s[j]) { j += 1 }
          guard j < n else { return nil }
          if s[j] == "\"" || s[j] == "'" {
            let q = s[j]
            j += 1
            while j < n, s[j] != q { value.append(s[j]); j += 1 }
            guard j < n else { return nil }
            j += 1
          } else {
            while j < n, !isSpace(s[j]), s[j] != ">" { value.append(s[j]); j += 1 }
          }
        }
        if attrs[key] == nil { attrs[key] = HTMLEntities.decode(value) }
      }
    }

    func indexAfterClosing(_ name: String, from: Int) -> Int {
      let target = Array(name)
      var j = from
      while j < n {
        if s[j] == "<", j + 1 < n, s[j + 1] == "/" {
          var k = j + 2
          var matched = 0
          while matched < target.count, k < n, Character(s[k].lowercased()) == target[matched] { k += 1; matched += 1 }
          if matched == target.count {
            while k < n, s[k] != ">" { k += 1 }
            return min(k + 1, n)
          }
        }
        j += 1
      }
      return n
    }

    while i < n {
      try poll.check()
      let c = s[i]
      guard c == "<", i + 1 < n else { buf.append(c); i += 1; continue }
      let next = s[i + 1]
      if next == "!" || next == "?" {
        flush()
        if i + 3 < n, s[i + 2] == "-", s[i + 3] == "-" {
          var j = i + 4
          while j + 2 < n, !(s[j] == "-" && s[j + 1] == "-" && s[j + 2] == ">") { j += 1 }
          i = (j + 2 < n) ? j + 3 : n  // unterminated comment swallows the rest, like browsers
        } else {
          var j = i + 2
          while j < n, s[j] != ">" { j += 1 }
          i = min(j + 1, n)
        }
      } else if next == "/", i + 2 < n, s[i + 2].isASCII, s[i + 2].isLetter {
        var j = i + 2
        var name = ""
        while j < n, isNameChar(s[j]) { name += s[j].lowercased(); j += 1 }
        while j < n, s[j] != ">" { j += 1 }
        guard j < n else { break }  // unterminated: no later `>` exists, so the rest is text
        flush(); tokens.append(.end(name)); i = j + 1
      } else if next.isASCII, next.isLetter {
        if let (tok, after) = parseStartTag(i) {
          flush()
          tokens.append(tok)
          i = after
          if case .start(let name, _, let selfClosing) = tok, !selfClosing, skippedContent.contains(name) {
            i = indexAfterClosing(name, from: i)
            tokens.append(.end(name))
          }
        } else {
          break  // unterminated: retrying at i + 1 would rescan to the end (quadratic)
        }
      } else {
        buf.append(c); i += 1
      }
    }
    if i < n { buf.append(contentsOf: s[i...]) }
    flush()
    return tokens
  }

  private static let blockish: Set<String> = [
    "div", "p", "ul", "ol", "li", "table", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
    "section", "article", "header", "footer", "nav", "main", "aside", "form", "dl", "figure",
  ]
  private static let paragraphBoundaries: Set<String> = [
    "div", "li", "td", "th", "blockquote", "ul", "ol", "table", "body", "section", "article", "header",
    "footer", "main", "aside", "dd", "dt", "figure", "#root",
  ]

  static func build(_ tokens: [HTMLToken]) throws -> HTMLNode {
    let root = HTMLNode(tag: "#root")
    var stack: [HTMLNode] = [root]
    var poll = CancellationPoll()

    /// Pops through the nearest open `names` element, unless a boundary tag is met first.
    func closeImplied(_ names: Set<String>, boundaries: Set<String>) {
      var k = stack.count - 1
      while k > 0 {
        let t = stack[k].tag
        if names.contains(t) { stack.removeSubrange(k...); return }
        if boundaries.contains(t) { return }
        k -= 1
      }
    }

    for tok in tokens {
      try poll.check()
      switch tok {
      case .text(let t):
        stack[stack.count - 1].children.append(HTMLNode(tag: "", text: t))
      case .start(let name, let attrs, let selfClosing):
        switch name {
        case "li": closeImplied(["li"], boundaries: ["ul", "ol"])
        case "tr": closeImplied(["tr"], boundaries: ["table"])
        case "td", "th": closeImplied(["td", "th"], boundaries: ["tr", "table"])
        case "dt", "dd": closeImplied(["dt", "dd"], boundaries: ["dl"])
        default: break
        }
        if blockish.contains(name) { closeImplied(["p"], boundaries: paragraphBoundaries) }
        let node = HTMLNode(tag: name, attrs: attrs)
        stack[stack.count - 1].children.append(node)
        if !selfClosing, !voidTags.contains(name), stack.count < maxDepth { stack.append(node) }
      case .end(let name):
        if let k = stack.lastIndex(where: { $0.tag == name }), k > 0 { stack.removeSubrange(k...) }
      }
    }
    return root
  }
}

// MARK: - Rendering

struct MDWriter {
  var out = ""
  var pendingNL = 0
  var pendingSpace = false
  var leadSpace = false

  struct Fragment {
    var text: String
    var lead: Bool
    var trail: Bool
  }

  mutating func space() {
    if out.isEmpty { leadSpace = true }
    pendingSpace = true
  }

  mutating func write(_ s: String) {
    guard !s.isEmpty else { return }
    if !out.isEmpty {
      if pendingNL > 0 { out += String(repeating: "\n", count: pendingNL) } else if pendingSpace { out += " " }
    }
    pendingNL = 0
    pendingSpace = false
    out += s
  }

  mutating func block() { pendingNL = 2; pendingSpace = false }
  mutating func newline() { pendingNL = max(pendingNL, 1); pendingSpace = false }

  mutating func hardBreak() {
    guard !out.isEmpty, pendingNL == 0 else { return }
    out += out.hasSuffix("\n") ? "\n" : "  \n"
    pendingSpace = false
  }

  func fragment() -> Fragment {
    Fragment(text: out, lead: leadSpace, trail: pendingSpace && pendingNL == 0)
  }

  mutating func append(_ f: Fragment) {
    if f.text.isEmpty {
      if f.lead || f.trail { space() }
      return
    }
    if f.lead { space() }
    write(f.text)
    if f.trail { space() }
  }
}

final class MarkdownRenderer {
  /// Nested lists deeper than this are not indented further. Each level used to re-indent every
  /// line below it, so 100 nested `<ul><li>` turned 8 input bytes into ~200 output bytes per item.
  static let maxListIndentDepth = 10

  let escape: Bool
  init(escape: Bool) { self.escape = escape }

  /// Set when the tables would exceed `transformMaxTableColumns` or the shared output budget.
  private(set) var tableTooLarge = false
  private var tableBudget = transformMaxOutputBytes
  /// Set once rendering must end: `CancellationError` or "Output too large". Later walks are no-ops.
  private(set) var stopError: Error?
  private var poll = CancellationPoll(every: 256)
  private var listDepth = 0

  /// Checks cancellation and the output budget of `w` (any writer, nested ones included).
  /// `force` checks cancellation now rather than every 256 calls: used before re-processing a
  /// whole nested subtree, which deep lists and quotes do once per level while unwinding.
  private func shouldStop(_ w: MDWriter, force: Bool = false) -> Bool {
    if stopError != nil { return true }
    if w.out.utf8.count > transformMaxOutputBytes {
      stopError = TransformError.invalidInput("Output too large")
    } else if force, TransformRunner.isCancelled {
      stopError = CancellationError()
    } else {
      do { try poll.check() } catch { stopError = error }
    }
    return stopError != nil
  }

  func walkChildren(_ node: HTMLNode, _ w: inout MDWriter) {
    for c in node.children { walk(c, &w) }
  }

  private func fragment(of node: HTMLNode) -> MDWriter.Fragment {
    var sub = MDWriter()
    walkChildren(node, &sub)
    return sub.fragment()
  }

  private func oneLine(_ node: HTMLNode) -> String {
    fragment(of: node).text
      .replacingOccurrences(of: "  \n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  private func rawText(_ node: HTMLNode) -> String {
    if node.tag.isEmpty { return node.text }
    if node.tag == "br" { return "\n" }
    return node.children.map(rawText).joined()
  }

  private func escaped(_ word: String) -> String {
    guard escape else { return word }
    var out = ""
    let chars = Array(word)
    for (i, c) in chars.enumerated() {
      switch c {
      case "*", "`": out += "\\" + String(c)
      case "<":
        if i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "/" || chars[i + 1] == "!" || chars[i + 1] == "?" {
          out += "\\<"
        } else {
          out.append(c)
        }
      default: out.append(c)
      }
    }
    return out
  }

  private func writeText(_ raw: String, _ w: inout MDWriter) {
    var word = ""
    for c in raw {
      if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\r\n" || c == "\u{0C}" {
        if !word.isEmpty { w.write(escaped(word)); word = "" }
        w.space()
      } else {
        word.append(c)
      }
    }
    if !word.isEmpty { w.write(escaped(word)) }
  }

  private func wrapInline(_ node: HTMLNode, open: String, close: String, _ w: inout MDWriter) {
    let f = fragment(of: node)
    let trimmed = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      if f.lead || f.trail { w.space() }
      return
    }
    if f.lead { w.space() }
    w.write(open + trimmed + close)
    if f.trail { w.space() }
  }

  private func destination(_ url: String) -> String {
    url.replacingOccurrences(of: " ", with: "%20")
      .replacingOccurrences(of: "(", with: "%28")
      .replacingOccurrences(of: ")", with: "%29")
  }

  func walk(_ node: HTMLNode, _ w: inout MDWriter) {
    guard !shouldStop(w) else { return }
    if node.tag.isEmpty { writeText(node.text, &w); return }
    switch node.tag {
    case "h1", "h2", "h3", "h4", "h5", "h6":
      let level = Int(node.tag.dropFirst()) ?? 1
      let t = oneLine(node)
      guard !t.isEmpty else { return }
      w.block()
      w.write(String(repeating: "#", count: level) + " " + t)
      w.block()
    case "p", "div", "section", "article", "header", "footer", "main", "nav", "aside", "figure",
         "figcaption", "form", "fieldset", "address", "details", "summary", "dl", "dt", "dd", "center",
         "body", "html":
      w.block(); walkChildren(node, &w); w.block()
    case "br": w.hardBreak()
    case "hr": w.block(); w.write("---"); w.block()
    case "strong", "b": wrapInline(node, open: "**", close: "**", &w)
    case "em", "i": wrapInline(node, open: "*", close: "*", &w)
    case "del", "s", "strike": wrapInline(node, open: "~~", close: "~~", &w)
    case "code", "kbd", "samp", "tt":
      let t = rawText(node).replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
      guard !t.isEmpty else { return }
      w.write(t.contains("`") ? "`` \(t) ``" : "`\(t)`")
    case "a":
      let href = (node.attrs["href"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let f = fragment(of: node)
      let usable = !href.isEmpty && !href.hasPrefix("#") && !href.lowercased().hasPrefix("javascript:")
      let label = f.text.replacingOccurrences(of: "  \n", with: " ").replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
      if !usable || label.isEmpty {
        w.append(f)
        return
      }
      var dest = destination(href)
      if let title = node.attrs["title"], !title.isEmpty {
        dest += " \"" + title.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
      }
      if f.lead { w.space() }
      w.write("[\(label)](\(dest))")
      if f.trail { w.space() }
    case "img":
      guard let src = node.attrs["src"], !src.isEmpty else { return }
      let alt = (node.attrs["alt"] ?? "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        .replacingOccurrences(of: "\n", with: " ")
      w.write("![\(alt)](\(destination(src)))")
    case "pre":
      var lang = ""
      if let code = node.children.first(where: { $0.tag == "code" }), let cls = code.attrs["class"] {
        for part in cls.split(separator: " ") {
          if part.hasPrefix("language-") { lang = String(part.dropFirst(9)) }
          else if part.hasPrefix("lang-") { lang = String(part.dropFirst(5)) }
        }
      }
      var content = rawText(node)
      if content.hasPrefix("\r\n") { content.removeFirst(2) } else if content.hasPrefix("\n") { content.removeFirst() }
      while let last = content.last, last.isNewline || last == " " || last == "\t" { content.removeLast() }
      guard !content.isEmpty else { return }
      var longestRun = 0, run = 0
      for c in content.utf8 {
        run = c == UInt8(ascii: "`") ? run + 1 : 0
        longestRun = max(longestRun, run)
      }
      let fence = String(repeating: "`", count: max(3, longestRun + 1))
      w.block()
      w.write("\(fence)\(lang)\n\(content)\n\(fence)")
      w.block()
    case "ul", "ol":
      renderList(node, ordered: node.tag == "ol", &w)
    case "li":
      let single = HTMLNode(tag: "ul")
      single.children = [node]
      renderList(single, ordered: false, &w)
    case "blockquote":
      var sub = MDWriter()
      walkChildren(node, &sub)
      guard !shouldStop(sub, force: true) else { return }
      let body = sub.out.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return }
      let quoted = body.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
      w.block(); w.write(quoted); w.block()
    case "table":
      renderTable(node, &w)
    case "input":
      if node.attrs["type"]?.lowercased() == "checkbox" {
        w.write(node.attrs["checked"] != nil ? "[x]" : "[ ]")
      }
    case "script", "style", "title", "template":
      break
    default:
      walkChildren(node, &w)
    }
  }

  private func renderList(_ node: HTMLNode, ordered: Bool, _ w: inout MDWriter) {
    var index = Int(node.attrs["start"] ?? "") ?? 1
    listDepth += 1
    defer { listDepth -= 1 }
    w.block()
    for child in node.children {
      if child.tag == "li" {
        var sub = MDWriter()
        walkChildren(child, &sub)
        guard !shouldStop(sub, force: true) else { return }
        var body = sub.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.contains("```") {
          while body.contains("\n\n") { body = body.replacingOccurrences(of: "\n\n", with: "\n") }
        }
        let marker = ordered ? "\(index). " : "- "
        index += 1
        let indent = listDepth <= Self.maxListIndentDepth ? String(repeating: " ", count: marker.count) : ""
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        var rendered = marker + (lines.first.map(String.init) ?? "")
        for l in lines.dropFirst() { rendered += "\n" + (l.isEmpty ? "" : indent + l) }
        w.write(rendered.trimmingCharacters(in: .whitespaces))
        w.newline()
      } else if !(child.tag.isEmpty && child.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
        walk(child, &w)
      }
    }
    w.block()
  }

  private func collectRows(_ node: HTMLNode, into rows: inout [[HTMLNode]]) {
    for child in node.children {
      switch child.tag {
      case "tr": rows.append(child.children.filter { $0.tag == "td" || $0.tag == "th" })
      case "td", "th", "table", "": continue
      default: collectRows(child, into: &rows)
      }
    }
  }

  private func renderTable(_ node: HTMLNode, _ w: inout MDWriter) {
    var rows: [[HTMLNode]] = []
    collectRows(node, into: &rows)
    rows.removeAll { $0.isEmpty }
    let columns = rows.map(\.count).max() ?? 0
    guard columns > 0 else { walkChildren(node, &w); return }
    // Padding every row to `columns` can multiply the output; check before building strings.
    let padded = rows.count &* (3 &* columns &+ 4)
    guard !tableTooLarge, columns <= transformMaxTableColumns, padded <= tableBudget else {
      tableTooLarge = true
      return
    }
    tableBudget -= padded
    func line(_ row: [HTMLNode]) -> String {
      let cells = (0..<columns).map { i in i < row.count ? oneLine(row[i]).replacingOccurrences(of: "|", with: "\\|") : "" }
      return "| " + cells.joined(separator: " | ") + " |"
    }
    var lines = [line(rows[0])]
    lines.append("| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |")
    lines.append(contentsOf: rows.dropFirst().map(line))
    w.block(); w.write(lines.joined(separator: "\n")); w.block()
  }
}
