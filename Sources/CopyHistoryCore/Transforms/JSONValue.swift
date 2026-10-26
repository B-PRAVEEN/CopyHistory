import Foundation

/// Order-preserving JSON model. Foundation's JSONSerialization drops key order and number text,
/// both of which matter when generating code from the JSON.
struct JSONMember: Equatable, Sendable {
  var key: String
  var value: JSONValue
}

indirect enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(String)
  case string(String)
  case array([JSONValue])
  case object([JSONMember])

  /// Renders as a JavaScript literal, indented by `indent` spaces for the closing bracket.
  func jsLiteral(indent: Int = 0) -> String {
    switch self {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return n
    case .string(let s): return jsStringLiteral(s)
    case .array(let items):
      if items.isEmpty { return "[]" }
      let pad = String(repeating: " ", count: indent + 2)
      let body = items.map { pad + $0.jsLiteral(indent: indent + 2) }.joined(separator: ",\n")
      return "[\n\(body)\n\(String(repeating: " ", count: indent))]"
    case .object(let members):
      if members.isEmpty { return "{}" }
      let pad = String(repeating: " ", count: indent + 2)
      let body = members
        .map { pad + jsStringLiteral($0.key) + ": " + $0.value.jsLiteral(indent: indent + 2) }
        .joined(separator: ",\n")
      return "{\n\(body)\n\(String(repeating: " ", count: indent))}"
    }
  }
}

func jsStringLiteral(_ s: String) -> String {
  var out = "\""
  for u in s.unicodeScalars {
    switch u {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    default:
      if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 {
        out += "\\u" + String(format: "%04X", u.value)
      } else {
        out.unicodeScalars.append(u)
      }
    }
  }
  return out + "\""
}

/// Strict, depth-limited JSON parser. Never traps; every failure is a thrown `TransformError`.
struct JSONParser {
  static let maxDepth = 128
  private let bytes: [UInt8]
  private var pos = 0

  private init(_ text: String) { bytes = Array(text.utf8) }

  static func parse(_ text: String) throws -> JSONValue {
    var p = JSONParser(text)
    p.skipWhitespace()
    let value = try p.parseValue(depth: 0)
    p.skipWhitespace()
    guard p.pos == p.bytes.count else { throw p.error("Unexpected content after JSON value") }
    return value
  }

  private func error(_ message: String) -> TransformError {
    .invalidInput("Invalid JSON at offset \(pos): \(message)")
  }

  private mutating func skipWhitespace() {
    while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
  }

  private mutating func parseValue(depth: Int) throws -> JSONValue {
    guard depth <= Self.maxDepth else { throw error("Nesting too deep") }
    guard pos < bytes.count else { throw error("Unexpected end of input") }
    switch bytes[pos] {
    case UInt8(ascii: "{"): return try parseObject(depth: depth)
    case UInt8(ascii: "["): return try parseArray(depth: depth)
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"): try expect("true"); return .bool(true)
    case UInt8(ascii: "f"): try expect("false"); return .bool(false)
    case UInt8(ascii: "n"): try expect("null"); return .null
    default: return try parseNumber()
    }
  }

  private mutating func expect(_ literal: String) throws {
    let lit = Array(literal.utf8)
    guard pos + lit.count <= bytes.count, Array(bytes[pos..<pos + lit.count]) == lit else {
      throw error("Unexpected token")
    }
    pos += lit.count
  }

  private mutating func parseObject(depth: Int) throws -> JSONValue {
    pos += 1
    var members: [JSONMember] = []
    var indexOfKey: [String: Int] = [:]  // keeps duplicate-key handling linear
    skipWhitespace()
    if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object([]) }
    while true {
      skipWhitespace()
      guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw error("Expected string key") }
      let key = try parseString()
      skipWhitespace()
      guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw error("Expected ':'") }
      pos += 1
      skipWhitespace()
      let value = try parseValue(depth: depth + 1)
      if let i = indexOfKey[key] {
        members[i].value = value  // duplicate key: last wins, first position kept
      } else {
        indexOfKey[key] = members.count
        members.append(JSONMember(key: key, value: value))
      }
      skipWhitespace()
      guard pos < bytes.count else { throw error("Unterminated object") }
      if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
      if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
      throw error("Expected ',' or '}'")
    }
  }

  private mutating func parseArray(depth: Int) throws -> JSONValue {
    pos += 1
    var items: [JSONValue] = []
    skipWhitespace()
    if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array([]) }
    while true {
      skipWhitespace()
      items.append(try parseValue(depth: depth + 1))
      skipWhitespace()
      guard pos < bytes.count else { throw error("Unterminated array") }
      if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
      if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
      throw error("Expected ',' or ']'")
    }
  }

  private mutating func parseHex4() throws -> UInt32 {
    guard pos + 4 <= bytes.count else { throw error("Bad \\u escape") }
    var v: UInt32 = 0
    for _ in 0..<4 {
      guard let d = Character(UnicodeScalar(bytes[pos])).hexDigitValue else { throw error("Bad \\u escape") }
      v = v * 16 + UInt32(d)
      pos += 1
    }
    return v
  }

  private mutating func parseString() throws -> String {
    pos += 1  // opening quote
    var buf: [UInt8] = []
    while true {
      guard pos < bytes.count else { throw error("Unterminated string") }
      let b = bytes[pos]
      switch b {
      case UInt8(ascii: "\""):
        pos += 1
        return String(decoding: buf, as: UTF8.self)
      case UInt8(ascii: "\\"):
        pos += 1
        guard pos < bytes.count else { throw error("Unterminated string") }
        let e = bytes[pos]
        pos += 1
        switch e {
        case UInt8(ascii: "\""): buf.append(0x22)
        case UInt8(ascii: "\\"): buf.append(0x5C)
        case UInt8(ascii: "/"): buf.append(0x2F)
        case UInt8(ascii: "b"): buf.append(0x08)
        case UInt8(ascii: "f"): buf.append(0x0C)
        case UInt8(ascii: "n"): buf.append(0x0A)
        case UInt8(ascii: "r"): buf.append(0x0D)
        case UInt8(ascii: "t"): buf.append(0x09)
        case UInt8(ascii: "u"):
          var code = try parseHex4()
          if (0xD800...0xDBFF).contains(code) {
            if pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
              let save = pos
              pos += 2
              let low = try parseHex4()
              if (0xDC00...0xDFFF).contains(low) {
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
              } else {
                pos = save
                code = 0xFFFD
              }
            } else {
              code = 0xFFFD
            }
          } else if (0xDC00...0xDFFF).contains(code) {
            code = 0xFFFD
          }
          let scalar = Unicode.Scalar(code) ?? Unicode.Scalar(0xFFFD)!
          buf.append(contentsOf: Array(String(Character(scalar)).utf8))
        default: throw error("Invalid escape")
        }
      case 0..<0x20:
        throw error("Control character in string")
      default:
        buf.append(b)
        pos += 1
      }
    }
  }

  private mutating func parseNumber() throws -> JSONValue {
    let start = pos
    if pos < bytes.count, bytes[pos] == UInt8(ascii: "-") { pos += 1 }
    var digits = 0
    while pos < bytes.count, (0x30...0x39).contains(bytes[pos]) { pos += 1; digits += 1 }
    guard digits > 0 else { throw error("Unexpected token") }
    if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
      pos += 1
      var frac = 0
      while pos < bytes.count, (0x30...0x39).contains(bytes[pos]) { pos += 1; frac += 1 }
      guard frac > 0 else { throw error("Bad number") }
    }
    if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
      pos += 1
      if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
      var exp = 0
      while pos < bytes.count, (0x30...0x39).contains(bytes[pos]) { pos += 1; exp += 1 }
      guard exp > 0 else { throw error("Bad number") }
    }
    return .number(String(decoding: bytes[start..<pos], as: UTF8.self))
  }
}
