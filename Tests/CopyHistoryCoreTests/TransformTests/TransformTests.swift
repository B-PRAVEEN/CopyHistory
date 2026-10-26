import Testing
import Foundation
@testable import CopyHistoryCore

typealias Case = (name: String, input: String, expected: String)

// MARK: - JSON → TypeScript

@Suite struct JSONToTypeScriptTests {
  let t = JSONToTypeScript()

  static let cases: [Case] = [
    ("flat", #"{"id":1,"name":"a","ok":true}"#,
     "interface Root {\n  id: number;\n  name: string;\n  ok: boolean;\n}"),
    ("nested object + null", #"{"user":{"name":"a","bio":null}}"#,
     "interface Root {\n  user: User;\n}\n\ninterface User {\n  name: string;\n  bio: null;\n}"),
    ("array of objects merges, missing keys optional", #"{"items":[{"a":1,"b":"x"},{"a":2}]}"#,
     "interface Root {\n  items: Item[];\n}\n\ninterface Item {\n  a: number;\n  b?: string;\n}"),
    ("null in one element becomes union", #"[{"a":1},{"a":null}]"#,
     "interface RootItem {\n  a: number | null;\n}\n\ntype Root = RootItem[];"),
    ("mixed array union", #"{"v":[1,"a",true,null]}"#,
     "interface Root {\n  v: (number | string | boolean | null)[];\n}"),
    ("empty array and empty object", #"{"a":[],"b":{}}"#,
     "interface Root {\n  a: unknown[];\n  b: Record<string, unknown>;\n}"),
    ("keys needing quotes", #"{"first-name":"a","2x":1,"ok_1":2,"a b":3}"#,
     "interface Root {\n  \"first-name\": string;\n  \"2x\": number;\n  ok_1: number;\n  \"a b\": number;\n}"),
    ("primitive array root", "[1,2,3]", "type Root = number[];"),
    ("nested arrays", #"{"m":[[1,2],[3]]}"#, "interface Root {\n  m: number[][];\n}"),
    ("name collision gets suffix", #"{"a":{"x":1},"b":{"a":{"y":1}}}"#,
     "interface Root {\n  a: A;\n  b: B;\n}\n\ninterface A {\n  x: number;\n}\n\ninterface B {\n  a: A2;\n}\n\ninterface A2 {\n  y: number;\n}"),
    ("reserved global name", #"{"date":{"y":1}}"#, "interface Root {\n  date: DateType;\n}\n\ninterface DateType {\n  y: number;\n}"),
    ("unicode escapes + exponent", #"{"ké":1e3}"#, "interface Root {\n  ké: number;\n}"),
  ]

  @Test("table", arguments: cases)
  func table(c: Case) throws {
    #expect(t.canApply(to: c.input))
    #expect(try t.apply(to: c.input) == c.expected, Comment(rawValue: c.name))
  }

  static let malformed = [
    "", "{", "[", #"{"a":}"#, #"{"a":1,}"#, "{'a':1}", #"{"a":1} x"#, "nul", "-", #"{"a":"\u12"}"#,
    "[1,,2]", #"{"a":"unterminated}"#, String(repeating: "[", count: 5000),
  ]

  @Test("malformed throws", arguments: malformed)
  func malformedThrows(input: String) {
    #expect(throws: TransformError.self) { try t.apply(to: input) }
    #expect(!t.canApply(to: input))
  }

  @Test func deeplyNestedValidJSONDoesNotCrash() throws {
    let deep = String(repeating: "[", count: 120) + "1" + String(repeating: "]", count: 120)
    #expect(try t.apply(to: deep).hasPrefix("type Root = number"))
    let deepObj = String(repeating: #"{"a":"#, count: 120) + "1" + String(repeating: "}", count: 120)
    #expect(try t.apply(to: deepObj).hasPrefix("interface Root"))
  }

  @Test func canApplyIsConservative() {
    #expect(!t.canApply(to: "hello"))
    #expect(!t.canApply(to: "{}"))
    #expect(!t.canApply(to: "[]"))
    #expect(!t.canApply(to: "{not json}"))
    #expect(!t.canApply(to: "42"))
  }
}

// MARK: - CSV / TSV → Markdown

@Suite struct DelimitedToMarkdownTests {
  let t = DelimitedToMarkdown()

  static let cases: [Case] = [
    ("csv basic", "a,b\n1,2\n3,4", "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"),
    ("tsv", "a\tb\n1\t2", "| a | b |\n| --- | --- |\n| 1 | 2 |"),
    ("quoted with comma and escaped quote", "name,note\n\"Smith, J\",\"say \"\"hi\"\"\"", "| name | note |\n| --- | --- |\n| Smith, J | say \"hi\" |"),
    ("ragged rows are padded", "a,b,c\n1,2\n1,2,3,4", "| a | b | c |  |\n| --- | --- | --- | --- |\n| 1 | 2 |  |  |\n| 1 | 2 | 3 | 4 |"),
    ("pipe escaped", "a,b\nx|y,z", "| a | b |\n| --- | --- |\n| x\\|y | z |"),
    ("newline in quoted field", "a,b\n\"l1\nl2\",x", "| a | b |\n| --- | --- |\n| l1<br>l2 | x |"),
    ("CRLF and trailing newline", "a,b\r\n1,2\r\n", "| a | b |\n| --- | --- |\n| 1 | 2 |"),
    ("blank lines skipped", "a,b\n\n1,2\n\n", "| a | b |\n| --- | --- |\n| 1 | 2 |"),
    ("empty cells kept", "a,b\n,2", "| a | b |\n| --- | --- |\n|  | 2 |"),
    ("BOM", "\u{FEFF}a,b\n1,2", "| a | b |\n| --- | --- |\n| 1 | 2 |"),
  ]

  @Test("table", arguments: cases)
  func table(c: Case) throws {
    if !c.name.hasPrefix("ragged") { #expect(t.canApply(to: c.input), Comment(rawValue: c.name)) }
    #expect(try t.apply(to: c.input) == c.expected, Comment(rawValue: c.name))
  }

  @Test("malformed throws", arguments: ["", "   \n", "single line no delimiter", "a,b\n\"unterminated,1"])
  func malformedThrows(input: String) {
    #expect(throws: TransformError.self) { try t.apply(to: input) }
  }

  @Test func canApplyIsConservative() {
    #expect(!t.canApply(to: "just one line, with comma"))
    #expect(!t.canApply(to: "Hello, world\nthis line has no comma"))
    #expect(!t.canApply(to: #"{"a":1,"b":2}"# + "\n" + #"{"a":1,"b":2}"#))
    #expect(!t.canApply(to: "plain\ntext"))
  }
}

// MARK: - cURL → fetch

@Suite struct CurlToFetchTests {
  let t = CurlToFetch()

  static let cases: [Case] = [
    ("simple get", "curl https://example.com/api", #"fetch("https://example.com/api");"#),
    ("-X and header", "curl -X DELETE -H 'X-Token: abc' https://x.test/1",
     "fetch(\"https://x.test/1\", {\n  method: \"DELETE\",\n  headers: {\n    \"X-Token\": \"abc\"\n  }\n});"),
    ("json body implies POST, pretty literal", #"curl https://x.test -H 'Content-Type: application/json' -d '{"a":1,"b":[true,null]}'"#,
     "fetch(\"https://x.test\", {\n  method: \"POST\",\n  headers: {\n    \"Content-Type\": \"application/json\"\n  },\n  body: JSON.stringify({\n    \"a\": 1,\n    \"b\": [\n      true,\n      null\n    ]\n  })\n});"),
    ("multi-line with backslashes", "curl 'https://x.test/a' \\\n  -H 'Accept: */*' \\\n  --data-raw 'k=v'",
     "fetch(\"https://x.test/a\", {\n  method: \"POST\",\n  headers: {\n    \"Accept\": \"*/*\",\n    \"Content-Type\": \"application/x-www-form-urlencoded\"\n  },\n  body: \"k=v\"\n});"),
    ("basic auth kept as written", "curl -u fakeuser:fakepass https://x.test",
     "fetch(\"https://x.test\", {\n  headers: {\n    \"Authorization\": \"Basic \" + btoa(\"fakeuser:fakepass\")\n  }\n});"),
    ("--url and -XPUT attached", "curl --url https://x.test/p -XPUT -d x=1 -H 'Content-Type: text/plain'",
     "fetch(\"https://x.test/p\", {\n  method: \"PUT\",\n  headers: {\n    \"Content-Type\": \"text/plain\"\n  },\n  body: \"x=1\"\n});"),
    ("--json flag", #"curl --json '{"a":1}' https://x.test"#,
     "fetch(\"https://x.test\", {\n  method: \"POST\",\n  headers: {\n    \"Content-Type\": \"application/json\",\n    \"Accept\": \"application/json\"\n  },\n  body: JSON.stringify({\n    \"a\": 1\n  })\n});"),
    ("-G moves data to query", "curl -G https://x.test/s -d q=1", #"fetch("https://x.test/s?q=1");"#),
    ("ignored flags and cluster", "curl -sSL --compressed -k https://x.test", #"fetch("https://x.test");"#),
    ("double quotes and escapes", #"curl "https://x.test" -H "X-A: say \"hi\"""#,
     "fetch(\"https://x.test\", {\n  headers: {\n    \"X-A\": \"say \\\"hi\\\"\"\n  }\n});"),
    ("ANSI-C quoting", "curl https://x.test -d $'a\\nb'", "fetch(\"https://x.test\", {\n  method: \"POST\",\n  headers: {\n    \"Content-Type\": \"application/x-www-form-urlencoded\"\n  },\n  body: \"a\\nb\"\n});"),
    ("scheme-less url and prompt", "$ curl localhost:3000/x", #"fetch("http://localhost:3000/x");"#),
    ("pipe truncates", "curl https://x.test | jq .", #"fetch("https://x.test");"#),
    ("cookie and head", "curl -I -b 'a=1' https://x.test",
     "fetch(\"https://x.test\", {\n  method: \"HEAD\",\n  headers: {\n    \"Cookie\": \"a=1\"\n  }\n});"),
  ]

  @Test("table", arguments: cases)
  func table(c: Case) throws {
    #expect(t.canApply(to: c.input), Comment(rawValue: c.name))
    #expect(try t.apply(to: c.input) == c.expected, Comment(rawValue: c.name))
  }

  @Test("malformed throws", arguments: [
    "curl", "curl -X POST", "curl 'unterminated", "curl \"unterminated", "curl -H", "wget https://x.test",
    "curl -F file=@a.txt https://x.test", "curl -d @body.json https://x.test", "curl $'bad", "",
  ])
  func malformedThrows(input: String) {
    #expect(throws: TransformError.self) { try t.apply(to: input) }
  }

  @Test func canApplyIsConservative() {
    #expect(!t.canApply(to: "curly braces"))
    #expect(!t.canApply(to: "curl"))
    #expect(!t.canApply(to: "wget https://x.test"))
    #expect(!t.canApply(to: "echo curl https://x.test"))
  }
}

// MARK: - HTML → Markdown

@Suite struct HTMLToMarkdownTests {
  let t = HTMLToMarkdown()

  static let cases: [Case] = [
    ("headings and paragraphs", "<h1>Title</h1><p>Hello <b>world</b> and <i>you</i>.</p><h3>Sub</h3>",
     "# Title\n\nHello **world** and *you*.\n\n### Sub"),
    ("link with title", #"<p>See <a href="https://x.test/a b" title="T">the docs</a>.</p>"#,
     #"See [the docs](https://x.test/a%20b "T")."#),
    ("lists", "<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol start=\"3\"><li>a</li><li>b</li></ol>",
     "- one\n- two\n  - nested\n\n3. a\n4. b"),
    ("code and pre", "<p>Use <code>a &lt; b</code></p><pre><code class=\"language-swift\">let x = 1\n\nlet y = 2\n</code></pre>",
     "Use `a < b`\n\n```swift\nlet x = 1\n\nlet y = 2\n```"),
    ("entities", "<p>Fish &amp; chips &copy; &#8364;5 &#x41; &bogus; AT&T &amp</p>", "Fish & chips © €5 A &bogus; AT&T &amp"),
    ("unclosed tags are tolerated", "<p>one<p>two <b>bold <i>both</b> after", "one\n\ntwo **bold *both*** after"),
    ("implicit li close", "<ul><li>a<li>b</ul>", "- a\n- b"),
    ("br becomes hard break", "<p>a<br>b</p>", "a  \nb"),
    ("script, style, comments dropped", "<style>p{}</style><!-- hi --><p>x</p><script>alert('<b>')</script>", "x"),
    ("image", #"<img src="a.png" alt="A [x]">"#, "![A x](a.png)"),
    ("blockquote", "<blockquote><p>q1</p><p>q2</p></blockquote>", "> q1\n>\n> q2"),
    ("table", "<table><tr><th>A</th><th>B</th></tr><tr><td>1|2</td><td>3</td></tr></table>",
     "| A | B |\n| --- | --- |\n| 1\\|2 | 3 |"),
    ("whitespace collapse", "<div>  a \n\n   b  </div><div>c</div>", "a b\n\nc"),
    ("escapes markdown specials", "<p>2 * 3 &lt;div&gt; `x`</p>", "2 \\* 3 \\<div> \\`x\\`"),
    ("javascript link dropped", #"<a href="javascript:void(0)">click</a>"#, "click"),
    ("attribute edge cases", #"<a href=x.test/p title='a "q"' data-x=1 disabled>l</a>"#, #"[l](x.test/p "a \"q\"")"#),
  ]

  @Test("table", arguments: cases)
  func table(c: Case) throws {
    #expect(t.canApply(to: c.input), Comment(rawValue: c.name))
    #expect(try t.apply(to: c.input) == c.expected, Comment(rawValue: c.name))
  }

  @Test("malformed never crashes", arguments: [
    "<", "<<<>>>", "<div", "<div class=\"x", "</", "</div>", "<!--", "<!-- x", "<a href=>", "<p <b>>",
    "&", "&#;", "&#99999999999;", "&#0;", "<![CDATA[", "<?xml", "<script>", "<img src=",
    String(repeating: "<div>", count: 10_000), String(repeating: "<b>", count: 10_000) + "x",
    String(repeating: "<ul><li>", count: 2_000), String(repeating: "&", count: 10_000),
  ])
  func malformedNeverCrashes(input: String) {
    _ = try? t.apply(to: input)
    _ = t.canApply(to: input)
  }

  @Test("no content throws", arguments: ["", "   ", "<div></div>", "<script>x</script>", "<!-- c -->"])
  func noContentThrows(input: String) {
    #expect(throws: TransformError.self) { try t.apply(to: input) }
  }

  @Test func canApplyIsConservative() {
    #expect(!t.canApply(to: "plain text"))
    #expect(!t.canApply(to: "if a <b then c> d"))
    #expect(!t.canApply(to: "List<String> x = new ArrayList<>();"))
    #expect(!t.canApply(to: "1 < 2 && 3 > 2"))
    #expect(t.canApply(to: "<!DOCTYPE html><html></html>"))
    #expect(t.canApply(to: "<b>x</b>"))
  }
}

// MARK: - Strip formatting

@Suite struct StripFormattingTests {
  let t = StripFormatting()

  static let cases: [Case] = [
    ("ansi", "\u{1B}[31mred\u{1B}[0m \u{1B}[1;32mgreen\u{1B}[m", "red green"),
    ("markdown", "# Title\n\n**bold** and *it* and `code` and [link](https://x.test) ~~gone~~", "Title\n\nbold and it and code and link gone"),
    ("html", "<h1>Hi</h1><p>a <b>b</b> <a href=\"https://x.test\">c</a></p>", "Hi\n\na b c"),
    ("invisible and smart quotes", "a\u{200B}b\u{00A0}c “q” it’s", "ab c \"q\" it's"),
    ("trailing whitespace and blank lines", "a  \n\n\n\n b\t\n", "a\n\n b"),
    ("fenced code", "```swift\nlet x = 1\n```", "let x = 1"),
    ("multiplication untouched", "2 * 3 * 4 and snake_case_name", "2 * 3 * 4 and snake_case_name"),
    ("blockquote and rule", "> quoted\n\n---\n\nend", "quoted\n\nend"),
  ]

  @Test("table", arguments: cases)
  func table(c: Case) throws {
    #expect(try t.apply(to: c.input) == c.expected, Comment(rawValue: c.name))
  }

  @Test("no content throws", arguments: ["", "  \n ", "\u{200B}", "<script>x</script>"])
  func noContentThrows(input: String) {
    #expect(throws: TransformError.self) { try t.apply(to: input) }
  }

  @Test func canApplyIsConservative() {
    #expect(!t.canApply(to: "plain text, nothing special"))
    #expect(!t.canApply(to: "def __init__(self): pass"))
    #expect(!t.canApply(to: "snake_case and 2 * 3"))
    #expect(t.canApply(to: "**bold**"))
    #expect(t.canApply(to: "a\u{200B}b"))
    #expect(t.canApply(to: "\u{1B}[0mx"))
    #expect(t.canApply(to: "<p>x</p>"))
  }
}

// MARK: - Registry

@Suite struct TransformRegistryTests {
  @Test func registerDefaultsIsIdempotentAndComplete() {
    TransformRegistry.registerDefaults()
    TransformRegistry.registerDefaults()
    let ids = TransformRegistry.all.map(\.id)
    for id in ["json-to-typescript", "delimited-to-markdown-table", "curl-to-fetch", "html-to-markdown", "strip-formatting"] {
      #expect(ids.filter { $0 == id }.count == 1, Comment(rawValue: id))
    }
  }

  @Test func transformsHaveTitlesAndUniqueIds() {
    let all = TransformRegistry.defaultTransforms
    #expect(Set(all.map(\.id)).count == all.count)
    #expect(all.allSatisfy { !$0.title.isEmpty })
  }

  @Test func nothingIsOfferedForPlainProse() {
    let prose = "Meeting moved to 3pm, bring the slides.\nSee you there."
    #expect(TransformRegistry.defaultTransforms.filter { $0.canApply(to: prose) }.isEmpty)
  }
}
