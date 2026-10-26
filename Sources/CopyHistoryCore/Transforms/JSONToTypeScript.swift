import Foundation

public struct JSONToTypeScript: Transform {
  public init() {}
  public let id = "json-to-typescript"
  public let title = "JSON → TypeScript interface"

  public func canApply(to text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.utf8.count >= 2, t.utf8.count <= transformMaxInputBytes,
          let first = t.first, let last = t.last else { return false }
    guard (first == "{" && last == "}") || (first == "[" && last == "]") else { return false }
    guard t.utf8.count <= 200_000 else { return true }  // too big to validate cheaply
    guard let v = try? JSONParser.parse(t) else { return false }
    switch v {
    case .object(let m): return !m.isEmpty
    case .array(let a): return !a.isEmpty
    default: return false
    }
  }

  public func apply(to text: String) throws -> String {
    guard text.utf8.count <= transformMaxInputBytes else { throw TransformError.invalidInput("Input too large") }
    let value = try JSONParser.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let type = TSType.infer(value)
    let emitter = TSEmitter()
    if case .object = type {
      _ = emitter.render(type, hint: "Root")
      return emitter.output()
    }
    let rendered = emitter.render(type, hint: "RootItem")
    var parts = emitter.output()
    if !parts.isEmpty { parts += "\n\n" }
    return parts + "type Root = \(rendered);"
  }
}

indirect enum TSType: Equatable {
  case string, number, boolean, null, unknown
  case object([TSField])
  case array(TSType)
  case union([TSType])

  static func infer(_ v: JSONValue) -> TSType {
    switch v {
    case .null: return .null
    case .bool: return .boolean
    case .number: return .number
    case .string: return .string
    case .array(let items):
      return .array(items.isEmpty ? .unknown : unify(items.map(infer)))
    case .object(let members):
      return .object(members.map { TSField(key: $0.key, type: infer($0.value), optional: false) })
    }
  }

  /// Merges types into one: objects merge key-wise (missing keys become optional), arrays merge
  /// element types, primitives dedupe, everything else becomes a union (null last).
  static func unify(_ types: [TSType]) -> TSType {
    var flat: [TSType] = []
    func flatten(_ t: TSType) {
      if case .union(let parts) = t { parts.forEach(flatten) } else { flat.append(t) }
    }
    types.forEach(flatten)

    var prims: [TSType] = []
    var objects: [[TSField]] = []
    var arrays: [TSType] = []
    var hasNull = false
    for t in flat {
      switch t {
      case .null: hasNull = true
      case .object(let f): objects.append(f)
      case .array(let e): arrays.append(e)
      default: if !prims.contains(t) { prims.append(t) }
      }
    }

    var parts = prims
    if !objects.isEmpty { parts.append(.object(mergeObjects(objects))) }
    if !arrays.isEmpty {
      let known = arrays.filter { $0 != .unknown }
      parts.append(.array(known.isEmpty ? .unknown : unify(known)))
    }
    if hasNull { parts.append(.null) }
    if parts.isEmpty { return .unknown }
    return parts.count == 1 ? parts[0] : .union(parts)
  }

  private static func mergeObjects(_ objects: [[TSField]]) -> [TSField] {
    var order: [String] = []
    var seen: [String: [TSField]] = [:]
    for obj in objects {
      for f in obj {
        if seen[f.key] == nil { order.append(f.key) }
        seen[f.key, default: []].append(f)
      }
    }
    return order.map { key in
      let fields = seen[key] ?? []
      let optional = fields.count < objects.count || fields.contains { $0.optional }
      return TSField(key: key, type: unify(fields.map(\.type)), optional: optional)
    }
  }
}

struct TSField: Equatable {
  var key: String
  var type: TSType
  var optional: Bool
}

final class TSEmitter {
  private struct Slot {
    var name: String
    var hint: String
    var lines: [String]
  }
  private struct Shape: Hashable {
    var hint: String
    var lines: [String]
  }
  private var slots: [Slot?] = []
  private var names: Set<String> = []
  private var nameOfShape: [Shape: String] = [:]  // first finished interface with this hint and body
  private var nextSuffix: [String: Int] = [:]     // lowest suffix that may be free, per hint

  private static let reserved: Set<String> = [
    "String", "Number", "Boolean", "Object", "Array", "Date", "Record", "Promise", "Map", "Set",
    "Function", "Error", "Symbol", "Partial", "Readonly", "Pick", "Omit", "Exclude", "Extract",
    "Required", "NonNullable", "RegExp", "JSON", "Math", "Intl", "Element", "Node", "Event",
    "Window", "Document", "Response", "Request", "Headers", "URL", "Blob", "File", "Text",
  ]

  func output() -> String {
    slots.compactMap { $0 }
      .map { "interface \($0.name) {\n" + $0.lines.joined(separator: "\n") + "\n}" }
      .joined(separator: "\n\n")
  }

  func render(_ t: TSType, hint: String) -> String {
    switch t {
    case .string: return "string"
    case .number: return "number"
    case .boolean: return "boolean"
    case .null: return "null"
    case .unknown: return "unknown"
    case .array(let element):
      let inner = render(element, hint: Self.singular(hint))
      if case .union = element { return "(\(inner))[]" }
      return "\(inner)[]"
    case .union(let parts):
      return parts.map { render($0, hint: hint) }.joined(separator: " | ")
    case .object(let fields):
      if fields.isEmpty { return "Record<string, unknown>" }
      let name = uniqueName(hint)
      names.insert(name)
      let index = slots.count
      slots.append(nil)  // reserve so the parent precedes its nested interfaces
      var lines: [String] = []
      for f in fields {
        let typeText = render(f.type, hint: Self.pascal(f.key))
        lines.append("  \(Self.propertyKey(f.key))\(f.optional ? "?" : ""): \(typeText);")
      }
      let shape = Shape(hint: hint, lines: lines)
      if let same = nameOfShape[shape] {
        names.remove(name)
        if name != hint, let n = Int(name.dropFirst(hint.count)) { nextSuffix[hint] = min(nextSuffix[hint] ?? n, n) }
        return same
      }
      nameOfShape[shape] = name
      slots[index] = Slot(name: name, hint: hint, lines: lines)
      return name
    }
  }

  private func uniqueName(_ hint: String) -> String {
    if !names.contains(hint) { return hint }
    var n = nextSuffix[hint] ?? 2
    while names.contains("\(hint)\(n)") { n += 1 }
    nextSuffix[hint] = n
    return "\(hint)\(n)"
  }

  static func propertyKey(_ key: String) -> String {
    isIdentifier(key) ? key : jsStringLiteral(key)
  }

  static func isIdentifier(_ s: String) -> Bool {
    guard let first = s.unicodeScalars.first else { return false }
    func isStart(_ u: Unicode.Scalar) -> Bool {
      u.properties.isIDStart || u == "_" || u == "$"
    }
    guard isStart(first) else { return false }
    return s.unicodeScalars.allSatisfy { isStart($0) || $0.properties.isIDContinue }
  }

  static func pascal(_ key: String) -> String {
    var out = ""
    var upperNext = true
    for ch in key {
      if ch.isLetter || ch.isNumber {
        out += upperNext ? String(ch).uppercased() : String(ch)
        upperNext = false
      } else {
        upperNext = true
      }
    }
    if out.isEmpty { return "Item" }
    if out.first!.isNumber { out = "_" + out }
    if reserved.contains(out) { out += "Type" }
    return out
  }

  static func singular(_ name: String) -> String {
    let lower = name.lowercased()
    if lower.hasSuffix("ies"), name.count > 3 { return String(name.dropLast(3)) + "y" }
    for suffix in ["sses", "xes", "ches", "shes"] where lower.hasSuffix(suffix) {
      return String(name.dropLast(2))
    }
    if lower.hasSuffix("s"), !lower.hasSuffix("ss"), name.count > 1 { return String(name.dropLast()) }
    return name
  }
}
