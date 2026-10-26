import Foundation

/// The Paste Stack queue: entries copied while stack mode is on, pasted back in copy order (FIFO).
///
/// Pure value type, memory-only: it is never persisted or logged, so flagged entries (including
/// images flagged through their OCR text) keep their findings and are written to the pasteboard as
/// sensitive. Both the entry count and the payload bytes are bounded, so a runaway copy loop or a
/// series of large screenshots cannot grow it without limit.
public struct PasteStack: Sendable, Equatable {
  public static let defaultCapacity = 50
  /// Room for at least three images at `ImageNormalizer.defaultMaxBytes` (20 MB) each.
  public static let defaultMaxBytes = 64_000_000

  public let capacity: Int
  public let maxBytes: Int
  public private(set) var items: [ClipboardEntry] = []
  public private(set) var isActive = false
  /// Sum of `payloadBytes` over `items`.
  public private(set) var byteCount = 0

  public init(capacity: Int = PasteStack.defaultCapacity, maxBytes: Int = PasteStack.defaultMaxBytes) {
    self.capacity = max(1, capacity)
    self.maxBytes = max(1, maxBytes)
  }

  public var count: Int { items.count }
  public var isEmpty: Bool { items.isEmpty }
  /// The entry the next ⌘V pastes.
  public var peek: ClipboardEntry? { items.first }

  /// Turns stack mode on with an empty queue.
  public mutating func start() {
    items = []
    byteCount = 0
    isActive = true
  }

  /// Turns stack mode off and drops the queue.
  public mutating func stop() {
    items = []
    byteCount = 0
    isActive = false
  }

  /// Why `enqueue` turned an entry away.
  public enum Rejection: Equatable, Sendable {
    case inactive
    case full      // `capacity` entries queued
    case tooLarge  // the payload would pass `maxBytes`
    case empty     // nothing that could be written to the pasteboard
  }

  /// Appends `entry`. Returns false (and changes nothing) when stack mode is off, the queue is full
  /// (by count or bytes), or the entry has no payload that could be written to the pasteboard.
  @discardableResult
  public mutating func enqueue(_ entry: ClipboardEntry) -> Bool {
    guard rejection(for: entry) == nil else { return false }
    items.append(entry)
    byteCount += Self.payloadBytes(entry)
    return true
  }

  /// Why `enqueue(entry)` would fail, or nil when it would succeed.
  public func rejection(for entry: ClipboardEntry) -> Rejection? {
    let bytes = Self.payloadBytes(entry)
    if !isActive { return .inactive }
    if bytes == 0 { return .empty }
    if items.count >= capacity { return .full }
    if byteCount + bytes > maxBytes { return .tooLarge }
    return nil
  }

  /// Removes and returns the head, or nil when the queue is empty.
  @discardableResult
  public mutating func popNext() -> ClipboardEntry? {
    guard !items.isEmpty else { return nil }
    let entry = items.removeFirst()
    byteCount -= Self.payloadBytes(entry)
    return entry
  }

  /// Removes every queued entry matching `shouldRemove`; returns how many went.
  @discardableResult
  public mutating func removeAll(where shouldRemove: (ClipboardEntry) -> Bool) -> Int {
    let before = items.count
    items.removeAll(where: shouldRemove)
    byteCount = items.reduce(0) { $0 + Self.payloadBytes($1) }
    return before - items.count
  }

  /// Empties the queue; stack mode stays on.
  public mutating func clear() {
    items = []
    byteCount = 0
  }

  /// Applies `change` to the queued entry with `id` (e.g. a late OCR result). Returns whether found.
  @discardableResult
  public mutating func update(id: UUID, _ change: (inout ClipboardEntry) -> Void) -> Bool {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
    byteCount -= Self.payloadBytes(items[index])
    change(&items[index])
    byteCount += Self.payloadBytes(items[index])
    return true
  }

  /// Bytes of the pasteable payload (UTF-8 text or PNG); 0 means nothing to paste. O(1) for native strings.
  static func payloadBytes(_ entry: ClipboardEntry) -> Int {
    switch entry.kind {
    case .text: return entry.text?.utf8.count ?? 0
    case .image: return entry.imagePNG?.count ?? 0
    }
  }
}

/// One-line labels for the stack panel. Flagged entries never show any of their text (nor OCR text),
/// and only a short prefix of other text is examined, so long entries cost O(maxLength).
public enum PasteStackPreview {
  public static func title(for entry: ClipboardEntry, maxLength: Int = 60) -> String {
    let limit = max(1, maxLength)
    if let category = entry.findings.first?.category {
      let what = entry.kind == .image ? "Image with secret text" : "Secret"
      return "🔒 \(what) (\(label(for: category)))"
    }
    switch entry.kind {
    case .text:
      return snippet(entry.text ?? "", limit: limit) ?? "(blank text)"
    case .image:
      guard let ocr = entry.ocrText, let text = snippet(ocr, limit: max(1, limit - 9)) else { return "Image" }
      return "Image — \(text)"
    }
  }

  /// Whitespace-collapsed prefix of `text`, at most `limit` characters plus an ellipsis.
  static func snippet(_ text: String, limit: Int) -> String? {
    // Look a little past the limit so leading whitespace and collapsed runs do not starve the label.
    let head = text.prefix(limit * 4)
    let words = head.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    guard !words.isEmpty else { return nil }
    let joined = words.joined(separator: " ")
    let truncated = joined.count > limit || head.endIndex < text.endIndex
    return truncated ? String(joined.prefix(limit)) + "…" : joined
  }

  static func label(for category: SecretFinding.Category) -> String {
    switch category {
    case .openAIKey: return "OpenAI key"
    case .awsAccessKey: return "AWS access key"
    case .awsSecretKey: return "AWS secret key"
    case .githubToken: return "GitHub token"
    case .slackToken: return "Slack token"
    case .jwt: return "JWT"
    case .privateKey: return "private key"
    case .creditCard: return "card number"
    case .genericSecret: return "secret"
    }
  }
}

/// A key press seen by the listen-only keyboard monitor, reduced to what the stack needs.
public struct PasteStackKeyPress: Equatable, Sendable {
  public struct Modifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
  }

  public enum Action: Equatable, Sendable {
    case paste     // the user's ⌘V
    case ownPaste  // a ⌘V this app synthesized (the popup's paste)
    case ignore
  }

  /// kVK_ANSI_V: the ⌘V key on QWERTY; used only when the layout's character is unknown.
  public static let vKeyCode: UInt16 = 9

  public var keyCode: UInt16
  /// Only ⌘⇧⌥⌃; callers drop caps lock, fn and device bits.
  public var modifiers: Modifiers
  /// What `keyCode` types with ⌘ held in the active keyboard layout (see `KeyboardLayoutCharacter`);
  /// nil when the layout could not be read. On Dvorak keycode 9 is "k", and ⌘V is keycode 47.
  public var character: String?
  public var isAutorepeat: Bool
  /// Synthesized by this app (e.g. the popup's own ⌘V), which must never advance the stack.
  public var fromOwnProcess: Bool

  public init(keyCode: UInt16, modifiers: Modifiers, character: String? = nil,
              isAutorepeat: Bool = false, fromOwnProcess: Bool = false) {
    self.keyCode = keyCode; self.modifiers = modifiers; self.character = character
    self.isAutorepeat = isAutorepeat; self.fromOwnProcess = fromOwnProcess
  }

  /// Exactly ⌘V (⇧⌘V and ⌥⌘V are other shortcuts), matched by the character the layout types, so
  /// ⌘K on Dvorak (keycode 9) never counts. No other key, Esc included, does anything: a stray Esc
  /// dismissing an autocomplete list must not throw the queue away.
  public var action: Action {
    guard !isAutorepeat, modifiers == .command else { return .ignore }
    let isV = character.map { $0.lowercased() == "v" } ?? (keyCode == Self.vKeyCode)
    guard isV else { return .ignore }
    return fromOwnProcess ? .ownPaste : .paste
  }
}
