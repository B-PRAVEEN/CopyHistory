import Foundation

/// CSV or TSV (auto-detected) → GitHub-flavoured Markdown table.
public struct DelimitedToMarkdown: Transform {
  public init() {}
  public let id = "delimited-to-markdown-table"
  public let title = "CSV/TSV → Markdown table"

  public func canApply(to text: String) -> Bool {
    guard text.utf8.count <= transformMaxInputBytes else { return false }
    let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
      .prefix(6)
    guard lines.count >= 2 else { return false }
    let first = lines[lines.startIndex]
    if first.first == "{" || first.first == "[" || first.first == "<" { return false }
    let delimiter: Character = first.contains("\t") ? "\t" : ","
    let counts = lines.map { $0.reduce(0) { $1 == delimiter ? $0 + 1 : $0 } }
    guard let firstCount = counts.first, firstCount >= 1 else { return false }
    if text.contains("\"") { return true }  // quoting makes per-line counts unreliable
    return counts.allSatisfy { $0 == firstCount }
  }

  public func apply(to text: String) throws -> String {
    guard text.utf8.count <= transformMaxInputBytes else { throw TransformError.invalidInput("Input too large") }
    var body = text
    if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
    let firstLine = body.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).first ?? ""
    let delimiter: Unicode.Scalar = firstLine.contains("\t") ? "\t" : ","
    let rows = try Self.parseRecords(body, delimiter: delimiter)
    guard !rows.isEmpty else { throw TransformError.noContent }
    let columns = rows.map(\.count).max() ?? 0
    guard columns >= 2 else { throw TransformError.invalidInput("No delimiters found; not tabular data") }
    // Every row is padded to the widest one, so a single wide row multiplies the output size.
    // Check the padded size before building any strings.
    let padded = (rows.count + 1) &* (3 &* columns &+ 4)
    guard columns <= transformMaxTableColumns, padded &+ body.utf8.count <= transformMaxOutputBytes else {
      throw TransformError.invalidInput("Table too large")
    }

    var poll = CancellationPoll(every: 256)
    func line(_ row: [String]) throws -> String {
      try poll.check()
      let cells = (0..<columns).map { i in i < row.count ? Self.escapeCell(row[i]) : "" }
      return "| " + cells.joined(separator: " | ") + " |"
    }
    var out = [try line(rows[0])]
    out.append("| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |")
    out.append(contentsOf: try rows.dropFirst().map(line))
    return out.joined(separator: "\n")
  }

  static func escapeCell(_ cell: String) -> String {
    cell.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: "|", with: "\\|")
      .replacingOccurrences(of: "\r\n", with: "<br>")
      .replacingOccurrences(of: "\n", with: "<br>")
      .replacingOccurrences(of: "\r", with: "<br>")
  }

  /// RFC 4180 style parser: quoted fields, `""` escapes, embedded delimiters and newlines.
  /// Throws on an unterminated quote, or `CancellationError` once the run is cancelled.
  static func parseRecords(_ text: String, delimiter: Unicode.Scalar) throws -> [[String]] {
    let s = Array(text.unicodeScalars)
    var rows: [[String]] = []
    var row: [String] = []
    var field = String.UnicodeScalarView()
    var inQuotes = false
    var wasQuoted = false
    var wasQuotedRow = false
    var i = 0
    var poll = CancellationPoll()

    func endField() {
      row.append(String(field))
      field = String.UnicodeScalarView()
      wasQuoted = false
    }
    func endRow() {
      endField()
      if !(row.count == 1 && row[0].isEmpty && !wasQuotedRow) { rows.append(row) }
      row = []
      wasQuotedRow = false
    }

    while i < s.count {
      try poll.check()
      let c = s[i]
      if inQuotes {
        if c == "\"" {
          if i + 1 < s.count, s[i + 1] == "\"" { field.append("\""); i += 2; continue }
          inQuotes = false
        } else {
          field.append(c)
        }
        i += 1
        continue
      }
      if c == "\"", field.isEmpty, !wasQuoted {
        inQuotes = true
        wasQuoted = true
        wasQuotedRow = true
      } else if c == delimiter {
        endField()
      } else if c == "\n" || c == "\r" {
        if c == "\r", i + 1 < s.count, s[i + 1] == "\n" { i += 1 }
        endRow()
      } else {
        field.append(c)
      }
      i += 1
    }
    if inQuotes { throw TransformError.invalidInput("Unterminated quoted field") }
    if !field.isEmpty || !row.isEmpty || wasQuoted { endRow() }
    return rows
  }
}
