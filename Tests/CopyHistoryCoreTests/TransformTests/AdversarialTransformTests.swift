import Testing
import Foundation
@testable import CopyHistoryCore

/// Seconds taken by `body`. Bounds below are deliberately generous (debug build, busy machine):
/// each input is sized so the old quadratic code took far longer than the bound.
private func seconds(_ body: () throws -> Void) rethrows -> Double {
  let start = DispatchTime.now().uptimeNanoseconds
  try body()
  return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

// MARK: - H1: HTML tokenizer must be linear on unterminated tags

@Suite(.serialized, .timeLimit(.minutes(2))) struct HTMLTokenizerComplexityTests {
  static let shapes: [(String, String)] = [
    ("unterminated start tags", String(repeating: "<a x=1 ", count: 20_000)),
    ("unterminated end tags", "<b>x</b>" + String(repeating: "</a x=1 ", count: 20_000)),
    ("unterminated quoted attribute", "<b>x</b><a title=\"" + String(repeating: "<i ", count: 40_000)),
  ]

  @Test("linear time", arguments: shapes)
  func linear(shape: (String, String)) {
    let t = HTMLToMarkdown()
    #expect(t.canApply(to: shape.1), Comment(rawValue: shape.0))
    let s = seconds { _ = try? t.apply(to: shape.1) }
    #expect(s < 3, Comment(rawValue: "\(shape.0): \(s)s"))
  }

  @Test func unterminatedTagBecomesText() throws {
    #expect(try HTMLToMarkdown().apply(to: "<b>bold</b> if a<b then") == "**bold** if a\\<b then")
    #expect(try HTMLToMarkdown().apply(to: "<p>x</p></p y") == "x\n\n\\</p y")
  }

  @Test func longBacktickRunInPre() {
    let input = "<pre>" + String(repeating: "`", count: 200_000) + "</pre>"
    var out = ""
    let s = seconds { out = (try? HTMLToMarkdown().apply(to: input)) ?? "" }
    #expect(s < 3, Comment(rawValue: "\(s)s"))
    #expect(out.hasPrefix(String(repeating: "`", count: 200_001) + "\n"))
  }
}

// MARK: - H2: StripFormatting regexes must not backtrack quadratically

@Suite(.serialized, .timeLimit(.minutes(3))) struct StripFormattingComplexityTests {
  static let shapes: [(String, String)] = [
    ("unclosed bold", String(repeating: " **a", count: 20_000)),
    ("unclosed italic", "**x" + String(repeating: " *a", count: 20_000)),
    ("unclosed bold italic", String(repeating: " ***a", count: 16_000)),
    ("unclosed underscore bold", "**x" + String(repeating: " __a", count: 20_000)),
    ("unclosed underscore italic", "**x" + String(repeating: " _a", count: 20_000)),
    ("unclosed strikethrough", "**x" + String(repeating: " ~~a", count: 20_000)),
    ("unclosed link text", "**x" + String(repeating: "[a\n", count: 20_000)),
    ("unclosed image destination", "**x" + String(repeating: "![a](", count: 16_000)),
    ("unclosed link destination", "**x" + String(repeating: "[a](x", count: 16_000)),
    ("unclosed link title", "**x" + String(repeating: "[a](x \"", count: 12_000)),
    ("rule-like line", "**x\n" + String(repeating: "- ", count: 20_000) + "x"),
    ("heading with long space run", "**x\n# x" + String(repeating: " ", count: 40_000) + "y"),
  ]

  @Test("linear time", arguments: shapes)
  func linear(shape: (String, String)) {
    let t = StripFormatting()
    #expect(t.canApply(to: shape.1), Comment(rawValue: shape.0))
    let s = seconds { _ = try? t.apply(to: shape.1) }
    #expect(s < 3, Comment(rawValue: "\(shape.0): \(s)s"))
  }

  static let semantics: [Case] = [
    ("bold with inner italic", "**a *b* c**", "a b c"),
    ("bold italic", "***both*** and ~~del~~", "both and del"),
    ("underscores", "__bold__ and _it_ but snake_case", "bold and it but snake_case"),
    ("closing hashes", "## Title ##\n# C#\n#hashtag", "Title\nC#\n#hashtag"),
    ("link with title and image", "[a](https://x.test \"T\") ![img](i.png)", "a img"),
    ("unclosed markers kept", "**a and *b and [c", "**a and *b and [c"),
  ]

  @Test("semantics kept", arguments: semantics)
  func semanticsKept(c: Case) throws {
    #expect(try StripFormatting().apply(to: c.input) == c.expected, Comment(rawValue: c.name))
  }
}

// MARK: - H3: table output must be bounded

@Suite(.serialized, .timeLimit(.minutes(2))) struct TableSizeTests {
  @Test func wideCSVHeaderIsRefused() {
    let input = "\"h\"" + String(repeating: ",", count: 20_000) + "\n" + String(repeating: "a,b\n", count: 500)
    #expect(DelimitedToMarkdown().canApply(to: input))
    #expect(throws: TransformError.self) { try DelimitedToMarkdown().apply(to: input) }
  }

  @Test func manyRowsTimesModerateColumnsIsRefused() {
    // 200 columns (under the column cap) × 100k rows would pad to ~60 MB of output.
    let input = "\"h\"" + String(repeating: ",", count: 199) + "\n" + String(repeating: "a\n", count: 100_000)
    #expect(throws: TransformError.self) { try DelimitedToMarkdown().apply(to: input) }
  }

  @Test func ordinaryLargeCSVStillConverts() throws {
    let input = "a,b,c\n" + String(repeating: "1,2,3\n", count: 50_000)
    let out = try DelimitedToMarkdown().apply(to: input)
    #expect(out.hasPrefix("| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |"))
  }

  @Test func wideHTMLTableIsRefused() {
    let input = "<table><tr>" + String(repeating: "<td>x", count: 2_000) + String(repeating: "<tr><td>a", count: 2_000) + "</table>"
    #expect(throws: TransformError.self) { try HTMLToMarkdown().apply(to: input) }
  }

  @Test func manyHTMLTablesShareOneBudget() {
    // Each table is small, but together they pad to tens of MB.
    let table = "<table><tr>" + String(repeating: "<td>x", count: 200) + String(repeating: "<tr><td>a", count: 200) + "</table>"
    let input = String(repeating: table, count: 300)
    #expect(throws: TransformError.self) { try HTMLToMarkdown().apply(to: input) }
  }

  @Test func ordinaryHTMLTableStillConverts() throws {
    let input = "<table><tr><th>A</th><th>B</th></tr>" + String(repeating: "<tr><td>1</td><td>2</td></tr>", count: 1_000) + "</table>"
    #expect(try HTMLToMarkdown().apply(to: input).hasPrefix("| A | B |\n| --- | --- |\n| 1 | 2 |"))
  }
}

// MARK: - M3/M4/M5: cURL options and credentials

@Suite struct CurlCredentialTests {
  let t = CurlToFetch()

  static let cases: [Case] = [
    ("--oauth2-bearer maps to a header and keeps the URL", "curl --oauth2-bearer FAKE_TOKEN https://api.x.test/v1",
     "fetch(\"https://api.x.test/v1\", {\n  headers: {\n    \"Authorization\": \"Bearer FAKE_TOKEN\"\n  }\n});"),
    ("value-taking options are skipped", "curl --max-redirs 5 --noproxy '*' --aws-sigv4 aws:amz:us-east-1:s3 https://x.test",
     #"fetch("https://x.test");"#),
    ("boolean long flags before a host", "curl --compressed --location localhost:3000/x",
     #"fetch("http://localhost:3000/x");"#),
    ("explicit Authorization beats -u (header first)", "curl https://x.test -H 'Authorization: Bearer fake' -u fakeuser:fakepw",
     "fetch(\"https://x.test\", {\n  headers: {\n    \"Authorization\": \"Bearer fake\"\n  }\n});"),
    ("explicit Authorization beats -u (header last)", "curl https://x.test -u fakeuser:fakepw -H 'authorization: Bearer fake'",
     "fetch(\"https://x.test\", {\n  headers: {\n    \"authorization\": \"Bearer fake\"\n  }\n});"),
    ("last of -u and --oauth2-bearer wins", "curl https://x.test --oauth2-bearer fake -u fakeuser:fakepw",
     "fetch(\"https://x.test\", {\n  headers: {\n    \"Authorization\": \"Basic \" + btoa(\"fakeuser:fakepw\")\n  }\n});"),
    ("URL credentials become Basic auth", "curl https://fakeuser:p%40ss@api.x.test/v1?q=1",
     "fetch(\"https://api.x.test/v1?q=1\", {\n  headers: {\n    \"Authorization\": \"Basic \" + btoa(\"fakeuser:p@ss\")\n  }\n});"),
    ("-u beats URL credentials", "curl -u other:fakepw https://fakeuser:fakepw@x.test/",
     "fetch(\"https://x.test/\", {\n  headers: {\n    \"Authorization\": \"Basic \" + btoa(\"other:fakepw\")\n  }\n});"),
    ("header beats URL credentials", "curl -H 'Authorization: Bearer fake' https://fakeuser@x.test/a@b",
     "fetch(\"https://x.test/a@b\", {\n  headers: {\n    \"Authorization\": \"Bearer fake\"\n  }\n});"),
    ("URL credentials with -G query", "curl -G fakeuser:fakepw@x.test/s -d q=1",
     "fetch(\"http://x.test/s?q=1\", {\n  headers: {\n    \"Authorization\": \"Basic \" + btoa(\"fakeuser:fakepw\")\n  }\n});"),
  ]

  @Test("table", arguments: cases)
  func table(c: Case) throws {
    #expect(try t.apply(to: c.input) == c.expected, Comment(rawValue: c.name))
  }

  @Test func unknownValueOptionThrowsWithoutEchoingValue() {
    do {
      _ = try t.apply(to: "curl --some-future-option FAKESECRETVALUE https://x.test")
      Issue.record("expected a throw")
    } catch {
      let message = error.localizedDescription
      #expect(message.contains("--some-future-option"))
      #expect(!message.contains("FAKESECRETVALUE"))
    }
  }
}

// MARK: - M7: JSON object parsing must be linear in the number of keys

@Suite(.serialized, .timeLimit(.minutes(2))) struct JSONComplexityTests {
  @Test func manyKeysParseQuickly() throws {
    let body = (0..<40_000).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
    var value: JSONValue?
    let s = try seconds { value = try JSONParser.parse("{" + body + "}") }
    #expect(s < 3, Comment(rawValue: "\(s)s"))
    guard case .object(let members)? = value else { Issue.record("not an object"); return }
    #expect(members.count == 40_000)
  }

  @Test func manyInterfacesWithOneNameEmitQuickly() throws {
    // 20k nested objects all named `X` with different bodies: X, X2, ..., X20000.
    let body = (0..<20_000).map { "\"k\($0)\":{\"x\":{\"v\($0)\":1}}" }.joined(separator: ",")
    var out = ""
    let s = try seconds { out = try JSONToTypeScript().apply(to: "{" + body + "}") }
    #expect(s < 10, Comment(rawValue: "\(s)s"))
    #expect(out.contains("interface X20000 {\n  v19999: number;\n}"))
  }

  @Test func identicalNestedShapesAreShared() throws {
    let out = try JSONToTypeScript().apply(to: #"{"a":{"x":{"v":1}},"b":{"x":{"w":1}},"c":{"x":{"v":1}}}"#)
    #expect(out.contains("interface C {\n  x: X;\n}"))
    #expect(out.contains("interface X2 {\n  w: number;\n}"))
    #expect(!out.contains("X3"))
  }

  @Test func duplicateKeysLastValueFirstPosition() throws {
    let v = try JSONParser.parse(#"{"a":1,"b":2,"a":3}"#)
    guard case .object(let members) = v else { Issue.record("not an object"); return }
    #expect(members.map(\.key) == ["a", "b"])
    #expect(members.first?.value == .number("3"))
  }
}
