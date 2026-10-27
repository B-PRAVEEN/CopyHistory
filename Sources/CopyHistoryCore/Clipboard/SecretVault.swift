import Foundation
import Security

/// Encrypted-at-rest storage for the plaintext of pinned flagged entries, keyed by entry id.
/// `HistoryStore` keeps only masked text in `history.json` and the plaintext here, so a pin whose
/// "secret" was a detector false positive is not destroyed on relaunch.
public protocol SecretVault: AnyObject, Sendable {
  /// Returns false when the value could not be stored; the caller then keeps only the masked text.
  func store(_ text: String, for id: UUID) -> Bool
  func load(_ id: UUID) -> String?
  func remove(_ id: UUID)
  /// Every id with a stored value (used to drop orphans left by a crash), or nil when the vault
  /// could not be listed (e.g. Keychain locked): the caller must then not treat anything as an orphan.
  func ids() -> Set<UUID>?
  /// The values of `ids` that could be read; a missing id was absent or unreadable. Called once at
  /// launch, off the main thread, so a vault can batch the lookups.
  func loadAll(_ ids: Set<UUID>) -> [UUID: String]
}

extension SecretVault {
  public func loadAll(_ ids: Set<UUID>) -> [UUID: String] {
    var out: [UUID: String] = [:]
    for id in ids { if let v = load(id) { out[id] = v } }
    return out
  }
}

/// Generic-password items in the user's login Keychain (the file-based keychain: the app has no
/// keychain access group, so the data-protection keychain is not available). Its accessibility
/// attribute is therefore ignored: the items are encrypted with the login keychain, but they travel
/// wherever `login.keychain-db` goes (Time Machine, Migration Assistant). Items keep the access
/// list of the binary that created them, so an app re-signed with a different (e.g. ad-hoc)
/// identity gets one access prompt per item.
public final class KeychainVault: SecretVault, @unchecked Sendable {
  public static let defaultService = "io.github.b-praveen.copyhistory.pinned-secrets"
  private let service: String

  public init(service: String = KeychainVault.defaultService) { self.service = service }

  private func query(_ id: UUID?) -> [String: Any] {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    if let id { q[kSecAttrAccount as String] = id.uuidString }
    return q
  }

  public func store(_ text: String, for id: UUID) -> Bool {
    SecItemDelete(query(id) as CFDictionary)
    var add = query(id)
    add[kSecValueData as String] = Data(text.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  public func load(_ id: UUID) -> String? {
    var q = query(id)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func remove(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }

  public func ids() -> Set<UUID>? {
    var q = query(nil)
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    var out: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let items = out as? [[String: Any]] else { return nil }
    return Set(items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) })
  }

  /// One query for every value where the keychain supports it; the file-based login keychain
  /// rejects returning data for `kSecMatchLimitAll` (`errSecParam`), so it falls back to one
  /// lookup per id.
  public func loadAll(_ ids: Set<UUID>) -> [UUID: String] {
    guard !ids.isEmpty else { return [:] }
    var q = query(nil)
    q[kSecReturnAttributes as String] = true
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else {
      var values: [UUID: String] = [:]
      for id in ids { if let v = load(id) { values[id] = v } }
      return values
    }
    var values: [UUID: String] = [:]
    for item in items {
      guard let id = (item[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)), ids.contains(id),
            let data = item[kSecValueData as String] as? Data, let v = String(data: data, encoding: .utf8) else { continue }
      values[id] = v
    }
    return values
  }
}

/// Process-lifetime vault: for tests and for stores that are not the app's real history file.
public final class InMemoryVault: SecretVault, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: String] = [:]
  public init() {}
  public func store(_ text: String, for id: UUID) -> Bool { lock.lock(); values[id] = text; lock.unlock(); return true }
  public func load(_ id: UUID) -> String? { lock.lock(); defer { lock.unlock() }; return values[id] }
  public func remove(_ id: UUID) { lock.lock(); values[id] = nil; lock.unlock() }
  public func ids() -> Set<UUID>? { lock.lock(); defer { lock.unlock() }; return Set(values.keys) }
}
