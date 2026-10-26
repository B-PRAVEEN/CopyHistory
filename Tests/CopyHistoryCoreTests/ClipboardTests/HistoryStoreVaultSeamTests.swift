import Foundation
import Testing
@testable import CopyHistoryCore

// Never touches the real Keychain or Application Support: every store uses a temporary directory
// and an in-memory vault.

/// A vault that batches reads through its own `loadAll`, and can hold the restore until released.
private final class BatchingVault: SecretVault, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID: String] = [:]
  private var _loadCalls = 0
  private var _loadAllCalls: [Set<UUID>] = []
  let gate = DispatchSemaphore(value: 0)
  var blockLoadAll = false

  var loadCalls: Int { lock.lock(); defer { lock.unlock() }; return _loadCalls }
  var loadAllCalls: [Set<UUID>] { lock.lock(); defer { lock.unlock() }; return _loadAllCalls }

  func store(_ text: String, for id: UUID) -> Bool { lock.lock(); values[id] = text; lock.unlock(); return true }
  func load(_ id: UUID) -> String? {
    lock.lock(); defer { lock.unlock() }; _loadCalls += 1; return values[id]
  }
  func remove(_ id: UUID) { lock.lock(); values[id] = nil; lock.unlock() }
  func ids() -> Set<UUID>? { lock.lock(); defer { lock.unlock() }; return Set(values.keys) }
  func loadAll(_ ids: Set<UUID>) -> [UUID: String] {
    lock.lock(); _loadAllCalls.append(ids); lock.unlock()
    if blockLoadAll { _ = gate.wait(timeout: .now() + 10) }
    lock.lock(); defer { lock.unlock() }
    return values.filter { ids.contains($0.key) }
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return n }
  func bump() { lock.lock(); n += 1; lock.unlock() }
}

private let fakeSecret = "sk-proj-FAKEFAKEFAKEFAKEFAKE1234"  // fake fixture, not a real key

private func tempURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("CHTest-\(UUID())/history.json")
}

@Suite struct SecretVaultLoadAllTests {
  /// The protocol's default `loadAll`: only ids that are stored, nothing else from the vault.
  @Test func defaultLoadAllReturnsOnlyRequestedStoredIDs() {
    let vault = InMemoryVault()
    let a = UUID(), b = UUID(), missing = UUID()
    #expect(vault.store("alpha", for: a))
    #expect(vault.store("beta", for: b))
    #expect(vault.loadAll([a, missing]) == [a: "alpha"])
    #expect(vault.loadAll([]) == [:])
    #expect(vault.loadAll([a, b]) == [a: "alpha", b: "beta"])
    vault.remove(a)
    #expect(vault.loadAll([a, b]) == [b: "beta"])
  }
}

@Suite struct HistoryStoreVaultSeamTests {
  @Test func defaultFileURLIsCopyHistoryInApplicationSupport() throws {
    let url = try #require(HistoryStore.defaultFileURL())
    let base = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    #expect(url.lastPathComponent == "history.json")
    #expect(url.deletingLastPathComponent().lastPathComponent == "CopyHistory")
    #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
            == base.standardizedFileURL)
    #expect(HistoryStore.defaultFileURL() == url)  // stable: `init` compares against it to pick the Keychain
  }

  /// The restore reads every vaulted pin with one `loadAll` call (so a vault can batch), never `load`,
  /// and posts `didRestoreVaultNotification` once the plaintext is back.
  @Test func restoreUsesLoadAllAndPostsTheNotification() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = BatchingVault()
    let first = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
    let pin = first.add(ClipboardEntry(kind: .text, text: fakeSecret, pinned: true,
                                       findings: SecretDetector().scan(fakeSecret)))
    first.flush()
    #expect(vault.load(pin.id) == fakeSecret)
    let loadsBefore = vault.loadCalls

    vault.blockLoadAll = true
    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
    let posted = Counter()
    let observer = NotificationCenter.default.addObserver(
      forName: HistoryStore.didRestoreVaultNotification, object: store, queue: nil) { _ in posted.bump() }
    defer { NotificationCenter.default.removeObserver(observer) }

    // Held in `loadAll`: the pin is masked and the popup refuses it.
    #expect(store.isRestoringVault)
    #expect(VaultStatus(store).isRestoring)
    let masked = try #require(store.entries(matching: "").first)
    #expect(masked.id == pin.id && masked.text != fakeSecret)
    #expect(PopupPolicy.decide(masked, request: .entry, plainOnly: false, isRestoringVault: store.isRestoringVault)
            == .refuse(PopupPolicy.restoringVaultMessage))
    #expect(posted.value == 0)

    vault.gate.signal()
    store.flush()  // runs after the restore on the store's queue
    #expect(!store.isRestoringVault)
    #expect(!VaultStatus(store).isRestoring)
    #expect(posted.value == 1)
    #expect(vault.loadAllCalls.last == [pin.id])
    #expect(vault.loadCalls == loadsBefore)
    let restored = try #require(store.entries(matching: "").first)
    #expect(restored.text == fakeSecret)
    #expect(PopupPolicy.decide(restored, request: .entry, plainOnly: false, isRestoringVault: store.isRestoringVault)
            == .deliver(.text(fakeSecret), sensitive: true))
  }

  /// A store with nothing to restore still finishes restoring and says so.
  @Test func emptyHistoryStillPostsTheNotification() {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = BatchingVault()
    vault.blockLoadAll = true
    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
    let posted = Counter()
    let observer = NotificationCenter.default.addObserver(
      forName: HistoryStore.didRestoreVaultNotification, object: store, queue: nil) { _ in posted.bump() }
    defer { NotificationCenter.default.removeObserver(observer) }
    vault.gate.signal()
    store.flush()
    #expect(!store.isRestoringVault)
    #expect(posted.value == 1)
  }

  /// No file means no vault and nothing to restore.
  @Test func inMemoryStoreIsNeverRestoring() {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    #expect(!store.isRestoringVault)
    #expect(VaultStatus(store).isHealthy)
  }
}
