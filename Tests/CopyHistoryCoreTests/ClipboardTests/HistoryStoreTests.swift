import Foundation
import Testing
@testable import CopyHistoryCore

@Suite struct HistoryStoreTests {
  func text(_ s: String, at t: TimeInterval = 0) -> ClipboardEntry {
    ClipboardEntry(kind: .text, text: s, now: Date(timeIntervalSince1970: t))
  }

  /// Adds an image and reports a clean scan of it: only then may it reach disk.
  @discardableResult
  func addScannedImage(_ store: HistoryStore, _ png: Data) -> ClipboardEntry {
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: e.id, imagePNG: png, scanned: true, ocrText: nil))
    return e
  }

  @Test func dedupeBumpsCount() {
    let store = HistoryStore(fileURL: nil)
    let first = store.add(text("hello", at: 1))
    let second = store.add(text("hello", at: 5))
    #expect(second.id == first.id)
    #expect(second.copyCount == 2)
    #expect(second.lastCopiedAt == Date(timeIntervalSince1970: 5))
    #expect(store.entries(matching: "").count == 1)
  }

  @Test func orderingPinnedFirstThenNewest() {
    let store = HistoryStore(fileURL: nil)
    let a = store.add(text("a", at: 1)); _ = store.add(text("b", at: 2)); _ = store.add(text("c", at: 3))
    store.togglePin(a.id)
    #expect(store.entries(matching: "").map(\.text) == ["a", "c", "b"])
  }

  @Test func capKeepsPinned() {
    let store = HistoryStore(fileURL: nil, unpinnedCap: 3)
    let p = store.add(text("pinned", at: 0)); store.togglePin(p.id)
    for i in 1...5 { _ = store.add(text("e\(i)", at: TimeInterval(i))) }
    #expect(store.entries(matching: "").map(\.text) == ["pinned", "e5", "e4", "e3"])
  }

  @Test func defaultCapIs200() {
    let store = HistoryStore(fileURL: nil)
    for i in 0..<230 { _ = store.add(text("e\(i)", at: TimeInterval(i))) }
    #expect(store.entries(matching: "").count == 200)
  }

  @Test func fuzzySearch() {
    let store = HistoryStore(fileURL: nil)
    _ = store.add(text("Hello World")); _ = store.add(text("goodbye")); _ = store.add(ClipboardEntry(kind: .image, imagePNG: Data([1])))
    #expect(store.entries(matching: "hwd").map(\.text) == ["Hello World"])
    #expect(store.entries(matching: "dlrow").isEmpty)
    #expect(store.entries(matching: "  ").count == 3)
  }

  @Test func removeExpiredSkipsPinned() {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let now = Date(timeIntervalSince1970: 100)
    var e1 = text("old"); e1.expiresAt = now.addingTimeInterval(-1)
    var e2 = text("future"); e2.expiresAt = now.addingTimeInterval(10)
    var e3 = text("pinnedOld"); e3.expiresAt = now.addingTimeInterval(-1); e3.pinned = true
    for e in [e1, e2, e3] { _ = store.add(e) }
    store.removeExpired(now: now)
    #expect(Set(store.entries(matching: "").compactMap(\.text)) == ["future", "pinnedOld"])
  }

  @Test func removeAndClear() {
    let store = HistoryStore(fileURL: nil)
    let a = store.add(text("a")); let b = store.add(text("b")); store.togglePin(b.id)
    store.remove(a.id)
    #expect(store.entries(matching: "").count == 1)
    _ = store.add(text("c")); store.clearUnpinned()
    #expect(store.entries(matching: "").map(\.text) == ["b"])
  }

  @Test func persistsToDisk() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CHTest-\(UUID())/history.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let s1 = HistoryStore(fileURL: url)
    let e = s1.add(text("persist me", at: 3)); s1.togglePin(e.id)
    s1.flush()
    let s2 = HistoryStore(fileURL: url)
    let loaded = s2.entries(matching: "")
    #expect(loaded.count == 1)
    #expect(loaded[0].text == "persist me" && loaded[0].pinned)
  }

  // MARK: - Secrecy at rest, persistence and recovery

  static let fakeSecret = "sk-proj-FAKEFAKEFAKEFAKEFAKE1234"

  func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CHTest-\(UUID())/history.json")
  }

  func flagged(_ s: String, expiresAt: Date? = nil, pinned: Bool = false) -> ClipboardEntry {
    ClipboardEntry(kind: .text, text: s, pinned: pinned, findings: SecretDetector().scan(s), expiresAt: expiresAt)
  }

  /// Every byte stored under the store's directory (history, images, backups, temp files).
  func allBytes(under dir: URL) -> [Data] {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return e.compactMap { ($0 as? URL).flatMap { try? Data(contentsOf: $0) } }
  }

  func mode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  func writeLegacy(_ entries: [ClipboardEntry], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    try enc.encode(entries).write(to: url)
  }

  @Test func flaggedPlaintextNeverWrittenToDisk() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pinnedSecret = "sk-proj-PINNEDFAKEPINNEDFAKE9999"
    let store = HistoryStore(fileURL: url)
    let live = store.add(flagged(Self.fakeSecret, expiresAt: Date().addingTimeInterval(60)))
    #expect(!live.findings.isEmpty)
    _ = store.add(flagged(pinnedSecret, pinned: true))
    _ = store.add(text("plain note"))
    store.flush()
    // Still pasteable from memory during the expiry window.
    #expect(store.entries(matching: "").contains { $0.text == Self.fakeSecret })
    let bytes = allBytes(under: dir)
    #expect(!bytes.isEmpty)
    for secret in [Self.fakeSecret, pinnedSecret, "FAKEFAKEFAKE", "PINNEDFAKE"] {
      #expect(!bytes.contains { String(decoding: $0, as: UTF8.self).contains(secret) })
    }
    // After a relaunch the pin survives as a masked placeholder; the unpinned secret is gone.
    let reloaded = HistoryStore(fileURL: url).entries(matching: "")
    #expect(reloaded.count == 2)
    #expect(reloaded.contains { $0.text == "plain note" })
    #expect(reloaded.contains { $0.pinned && $0.text != nil && $0.text != pinnedSecret })
  }

  @Test func filesArePrivateEvenIfDirectoryExisted() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let store = HistoryStore(fileURL: url)
    _ = store.add(text("hello"))
    addScannedImage(store, Data([0x89, 0x50, 0x4E, 0x47]))
    store.flush()
    #expect(mode(dir) == 0o700)
    #expect(mode(url) == 0o600)
    let images = dir.appendingPathComponent("images")
    #expect(mode(images) == 0o700)
    let files = try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)
    #expect(files.count == 1 && files.allSatisfy { mode($0) == 0o600 })
  }

  @Test func readsAndNoOpMutationsDoNotRewrite() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = HistoryStore(fileURL: url)
    var future = text("future"); future.expiresAt = Date().addingTimeInterval(3600)
    _ = store.add(future); _ = store.add(text("other"))
    store.flush()
    try FileManager.default.removeItem(at: url)
    store.removeExpired(now: Date())
    _ = store.entries(matching: ""); _ = store.entries(matching: "oth")
    store.togglePin(UUID()); store.remove(UUID())
    store.flush()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    // A real change is still persisted.
    store.clearUnpinned(); store.flush()
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test func writesAreDebounced() {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = HistoryStore(fileURL: url, saveDelay: 60)
    store.flush()  // the launch-time write (nothing to write yet), so it cannot race the adds
    for i in 0..<5 { _ = store.add(text("e\(i)")) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
    store.flush()
    #expect(HistoryStore(fileURL: url).entries(matching: "").count == 5)
  }

  @Test func imagesAreStoredOnceOutsideTheJSON() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = Data((0..<2048).map { UInt8($0 % 251) })
    let store = HistoryStore(fileURL: url)
    let img = addScannedImage(store, png)
    store.flush()
    let imageFile = dir.appendingPathComponent("images/\(img.id.uuidString).png")
    #expect(try Data(contentsOf: imageFile) == png)
    #expect(try Data(contentsOf: url).count < png.count)  // no base64 image inside history.json
    #expect(HistoryStore(fileURL: url).entries(matching: "").first?.imagePNG == png)

    // Later copies don't re-encode or rewrite the image.
    try FileManager.default.removeItem(at: imageFile)
    _ = store.add(text("later")); store.flush()
    #expect(!FileManager.default.fileExists(atPath: imageFile.path))

    // Removing the entry removes its file.
    let img2 = addScannedImage(store, Data([9, 9, 9])); store.flush()
    let file2 = dir.appendingPathComponent("images/\(img2.id.uuidString).png")
    #expect(FileManager.default.fileExists(atPath: file2.path))
    store.remove(img2.id); store.flush()
    #expect(!FileManager.default.fileExists(atPath: file2.path))
  }

  @Test func legacyFileIsPurgedAndScrubbedAtLoad() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let now = Date()
    let expired = flagged("sk-proj-EXPIREDFAKEEXPIREDFAKE1", expiresAt: now.addingTimeInterval(-100))
    let live = flagged(Self.fakeSecret, expiresAt: now.addingTimeInterval(600))
    try writeLegacy([expired, live, text("keep")], to: url)
    let store = HistoryStore(fileURL: url, now: { now })
    let texts = store.entries(matching: "").compactMap(\.text)
    #expect(Set(texts) == [Self.fakeSecret, "keep"])
    store.flush()
    let onDisk = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(!onDisk.contains("EXPIREDFAKE") && !onDisk.contains("FAKEFAKEFAKE"))
    #expect(onDisk.contains("keep"))
  }

  @Test func purgeTimerExpiresEntriesWithoutThePopup() async throws {
    let store = HistoryStore(fileURL: nil, purgeInterval: 0.05)
    _ = store.add(flagged(Self.fakeSecret, expiresAt: Date().addingTimeInterval(0.1)))
    _ = store.add(text("stays"))
    for _ in 0..<40 where store.entries(matching: "").count > 1 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(store.entries(matching: "").compactMap(\.text) == ["stays"])
  }

  func backups(in dir: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("history.corrupt-") }
  }

  @Test func corruptFileIsBackedUpNotWiped() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let garbage = Data("[{\"pinned\": true, oops".utf8)
    try garbage.write(to: url)
    let store = HistoryStore(fileURL: url)
    #expect(store.entries(matching: "").isEmpty)
    _ = store.add(text("new")); store.flush()
    let b = backups(in: dir)
    #expect(b.count == 1)
    #expect(try b.first.map { try Data(contentsOf: $0) } == garbage)
    #expect(store.recoveryBackupURL?.lastPathComponent == b.first?.lastPathComponent)
    #expect(b.allSatisfy { mode($0) == 0o600 })
  }

  @Test func undecodableRecordDoesNotDropPins() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    var pinned = text("pinned snippet"); pinned.pinned = true
    try writeLegacy([pinned, text("future kind")], to: url)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    json[1]["kind"] = "rtf"  // e.g. written by a newer version
    try JSONSerialization.data(withJSONObject: json).write(to: url)

    let store = HistoryStore(fileURL: url)
    #expect(store.entries(matching: "").map(\.text) == ["pinned snippet"])
    _ = store.add(text("new")); store.flush()
    #expect(HistoryStore(fileURL: url).entries(matching: "").contains { $0.pinned && $0.text == "pinned snippet" })
    #expect(backups(in: dir).count == 1)
  }

  @Test func searchDoesNotMatchHiddenSecretCharacters() {
    let store = HistoryStore(fileURL: nil)
    _ = store.add(flagged(Self.fakeSecret))
    #expect(store.entries(matching: "FAKEFAKEFAKE").isEmpty)
  }

  // MARK: - Recovery backups never hold plaintext secrets

  /// Fake AWS-style secret containing `/`, which JSONEncoder writes as `\/`.
  static let fakeAWSSecret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYFAKEFAKE00"

  func isExcludedFromBackup(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
  }

  @Test func corruptBackupOfLegacyFileMasksSecrets() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacySecret = "aws_secret_access_key=\(Self.fakeAWSSecret)"
    try writeLegacy([flagged(legacySecret, pinned: true), text("keep me note"), text("future kind")], to: url)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    json[2]["kind"] = "rtf"
    json[2]["text"] = "rtf body with sk-proj-UNDECODABLEFAKE00000000"
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("bPxRfiCY"))

    let store = HistoryStore(fileURL: url)
    store.flush()
    let backup = try #require(store.recoveryBackupURL)
    let bytes = String(decoding: try Data(contentsOf: backup), as: UTF8.self)
    #expect(!bytes.contains("bPxRfiCY") && !bytes.contains("UNDECODABLEFAKE"))
    // Everything that is not a secret is still there to recover, including the undecodable record.
    #expect(bytes.contains("keep me note") && bytes.contains("rtf body with") && bytes.contains("\"rtf\""))
    #expect(mode(backup) == 0o600)
    #expect(isExcludedFromBackup(backup))
    for data in allBytes(under: dir) {
      #expect(!String(decoding: data, as: UTF8.self).contains("bPxRfiCY"))
    }
  }

  @Test func corruptNonJSONBackupMasksEscapedSecrets() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let escaped = Self.fakeAWSSecret.replacingOccurrences(of: "/", with: "\\/")
    try Data("[{\"pinned\":true,\"text\":\"aws_secret_access_key=\(escaped)\", oops".utf8).write(to: url)
    let store = HistoryStore(fileURL: url)
    store.flush()
    let bytes = String(decoding: try Data(contentsOf: try #require(store.recoveryBackupURL)), as: UTF8.self)
    #expect(!bytes.contains("bPxRfiCY"))
    #expect(bytes.contains("\"pinned\":true"))
  }

  @Test func oldBackupsArePurgedCappedAndScrubbed() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date()
    func backup(_ name: String, _ body: String, age days: Double) throws -> URL {
      let u = dir.appendingPathComponent("history.corrupt-\(name).json")
      try Data(body.utf8).write(to: u)
      try fm.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86400), .posixPermissions: 0o644],
                           ofItemAtPath: u.path)
      return u
    }
    let old = try backup("old", "[]", age: 40)
    // Written in plaintext by an older version.
    let leaky = try backup("leaky", "[{\"text\":\"aws_secret_access_key=\(Self.fakeAWSSecret)\"}]", age: 1)
    let recent = try (2...7).map { try backup("r\($0)", "[]", age: Double($0)) }

    let store = HistoryStore(fileURL: url, now: { now })
    store.flush()
    let left = backups(in: dir)
    #expect(!fm.fileExists(atPath: old.path))
    #expect(left.count == HistoryStore.maxBackups)
    #expect(!fm.fileExists(atPath: recent.last!.path))  // the oldest beyond the cap goes first
    let leakyBytes = String(decoding: try Data(contentsOf: leaky), as: UTF8.self)
    #expect(!leakyBytes.contains("bPxRfiCY") && leakyBytes.contains("aws_secret_access_key"))
    #expect(left.allSatisfy { mode($0) == 0o600 && isExcludedFromBackup($0) })
  }

  // MARK: - False positives never destroy pinned data

  @Test func pinnedFlaggedEntryKeepsExactTextAcrossRelaunchViaVault() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = InMemoryVault()
    // Whatever the detector thinks, the user pinned it: it must come back verbatim.
    let pinnedText = "config token: sk-proj-PINNEDFAKEPINNEDFAKE9999"
    let s1 = HistoryStore(fileURL: url, vault: vault)
    let e = s1.add(flagged(pinnedText, expiresAt: Date().addingTimeInterval(60)))
    s1.togglePin(e.id)
    s1.flush()
    for data in allBytes(under: dir) { #expect(!String(decoding: data, as: UTF8.self).contains("PINNEDFAKE")) }
    #expect(vault.ids() == [e.id])

    let s2 = HistoryStore(fileURL: url, vault: vault)
    s2.flush()  // the vault is restored in the background
    let reloaded = try #require(s2.entries(matching: "").first)
    #expect(reloaded.id == e.id && reloaded.pinned)
    #expect(reloaded.text == pinnedText)
    #expect(!reloaded.findings.isEmpty)  // still masked in the UI, still never written in plaintext
    s2.flush()
    for data in allBytes(under: dir) { #expect(!String(decoding: data, as: UTF8.self).contains("PINNEDFAKE")) }

    // Unpinning (then expiry/removal) drops the vault copy.
    s2.togglePin(e.id); s2.remove(e.id); s2.flush()
    #expect(vault.ids()?.isEmpty == true)
  }

  @Test func legacyPlaintextPinMovesToVaultInsteadOfBeingMasked() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = InMemoryVault()
    try writeLegacy([flagged(Self.fakeSecret, pinned: true)], to: url)
    HistoryStore(fileURL: url, vault: vault).flush()
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("FAKEFAKEFAKE"))
    let s2 = HistoryStore(fileURL: url, vault: vault); s2.flush()
    #expect(s2.entries(matching: "").first?.text == Self.fakeSecret)
  }

  @Test func orphanedVaultItemsAreRemovedAtLoad() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = InMemoryVault()
    _ = vault.store("leftover", for: UUID())
    let store = HistoryStore(fileURL: url, vault: vault)
    store.flush()
    #expect(vault.ids()?.isEmpty == true)
  }

  /// Lists ids but refuses reads, like a Keychain whose access was denied after a re-sign.
  final class DeniedVault: SecretVault, @unchecked Sendable {
    let held: Set<UUID>
    private let lock = NSLock()
    private var _removed: Set<UUID> = []
    var removed: Set<UUID> { lock.lock(); defer { lock.unlock() }; return _removed }
    init(_ held: Set<UUID>) { self.held = held }
    func store(_ text: String, for id: UUID) -> Bool { false }
    func load(_ id: UUID) -> String? { nil }
    func remove(_ id: UUID) { lock.lock(); _removed.insert(id); lock.unlock() }
    func ids() -> Set<UUID>? { held }
  }

  @Test func unreadableVaultItemIsNeverDeletedUntilTheUserUnpins() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var pin = text("config token: sk-proj-••••••••"); pin.pinned = true
    try writeLegacy([pin], to: url)
    let vault = DeniedVault([pin.id])
    let store = HistoryStore(fileURL: url, vault: vault)
    #expect(store.entries(matching: "").first?.text == pin.text)  // masked, but kept
    _ = store.add(text("other")); store.flush()
    #expect(vault.removed.isEmpty)
    store.togglePin(pin.id); store.flush()
    #expect(vault.removed == [pin.id])
  }

  @Test func vaultItemOfUndecodableRecordSurvives() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = InMemoryVault()
    var pin = text("masked pin"); pin.pinned = true
    try writeLegacy([pin, text("ok")], to: url)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    json[0]["kind"] = "rtf"  // the pinned record can no longer be decoded
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    _ = vault.store("sk-proj-ONLYCOPYFAKEONLYCOPY000", for: pin.id)
    let store = HistoryStore(fileURL: url, vault: vault)
    _ = store.add(text("new")); store.flush()
    #expect(vault.load(pin.id) == "sk-proj-ONLYCOPYFAKEONLYCOPY000")
  }

  // MARK: - Round 3 review (R1, R2, R4, R6, R7, R8, R11)

  /// A vault that can fail listing, refuse writes, or block reads until released.
  final class TestVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    var listFails = false
    var storeFails = false
    let gate = DispatchSemaphore(value: 0)
    var blockLoads = false
    private var _loadCalls = 0
    var loadCalls: Int { lock.lock(); defer { lock.unlock() }; return _loadCalls }
    var all: [UUID: String] { lock.lock(); defer { lock.unlock() }; return values }
    func store(_ text: String, for id: UUID) -> Bool {
      if storeFails { return false }
      lock.lock(); values[id] = text; lock.unlock(); return true
    }
    func load(_ id: UUID) -> String? {
      lock.lock(); _loadCalls += 1; lock.unlock()
      if blockLoads { _ = gate.wait(timeout: .now() + 10) }
      lock.lock(); defer { lock.unlock() }; return values[id]
    }
    func remove(_ id: UUID) { lock.lock(); values[id] = nil; lock.unlock() }
    func ids() -> Set<UUID>? { listFails ? nil : { lock.lock(); defer { lock.unlock() }; return Set(values.keys) }() }
  }

  /// Writes a history file holding one masked pin whose plaintext is in `vault`, as the app would.
  func pinnedSecretOnDisk(_ secret: String, at url: URL, vault: SecretVault) -> UUID {
    let s = HistoryStore(fileURL: url, vault: vault)
    let e = s.add(flagged(secret, pinned: true))
    s.flush()
    return e.id
  }

  @Test func unreadableHistoryFileIsNeitherOverwrittenNorPurged() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = TestVault()
    let id = pinnedSecretOnDisk(Self.fakeSecret, at: url, vault: vault)
    let before = try Data(contentsOf: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

    let store = HistoryStore(fileURL: url, vault: vault)
    _ = store.add(text("copied this session")); store.flush()
    #expect(store.isReadOnly)
    #expect(store.entries(matching: "").count == 1)  // in memory only
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == before)
    #expect(vault.all[id] == Self.fakeSecret)
  }

  @Test func missingHistoryFileIsAFreshStart() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = HistoryStore(fileURL: url, vault: TestVault())
    _ = store.add(text("first")); store.flush()
    #expect(!store.isReadOnly)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test func initDoesNotWaitForTheVault() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = TestVault()
    let id = pinnedSecretOnDisk(Self.fakeSecret, at: url, vault: vault)
    vault.blockLoads = true
    let store = HistoryStore(fileURL: url, vault: vault)  // would deadlock here if init read the vault
    #expect(store.isRestoringVault)
    let pending = try #require(store.entries(matching: "").first)
    #expect(pending.id == id && pending.text != Self.fakeSecret)  // masked until restored
    vault.gate.signal()
    store.flush()
    #expect(!store.isRestoringVault)
    #expect(store.entries(matching: "").first?.text == Self.fakeSecret)
    #expect(vault.loadCalls == 1)
  }

  @Test func copyDuringRestoreFoldsIntoThePin() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = TestVault()
    let plain = "just some pinned words"  // not flagged by today's detector
    var pin = text("just some ••••••••"); pin.pinned = true
    try writeLegacy([pin], to: url)
    _ = vault.store(plain, for: pin.id)
    vault.blockLoads = true
    let store = HistoryStore(fileURL: url, vault: vault)
    _ = store.add(text(plain))  // re-copied while the pin still shows masked
    vault.gate.signal()
    store.flush()
    let all = store.entries(matching: "")
    #expect(all.count == 1 && all[0].id == pin.id && all[0].text == plain && all[0].copyCount == 2)
    for data in allBytes(under: dir) { #expect(!String(decoding: data, as: UTF8.self).contains(plain)) }
  }

  @Test func retainedVaultItemSurvivesLaterLaunchesWhileItsBackupExists() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = TestVault()
    var pin = text("ghp_••••••••"); pin.pinned = true
    try writeLegacy([pin, text("ok")], to: url)
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    json[0]["kind"] = "rtf"
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let secret = "ghp_" + String(repeating: "F", count: 36)
    _ = vault.store(secret, for: pin.id)

    let launch1 = HistoryStore(fileURL: url, vault: vault)
    _ = launch1.add(text("new")); launch1.flush()  // rewrites history.json without the bad record
    #expect(vault.all[pin.id] == secret)
    let launch2 = HistoryStore(fileURL: url, vault: vault)
    _ = launch2.add(text("newer")); launch2.flush()
    #expect(vault.all[pin.id] == secret)
    #expect(backups(in: dir).count == 1)

    // Once the backup is gone (retention), the item is an orphan like any other.
    for b in backups(in: dir) { try FileManager.default.removeItem(at: b) }
    HistoryStore(fileURL: url, vault: vault).flush()
    #expect(vault.all[pin.id] == nil)
  }

  @Test func unchangedCorruptFileIsBackedUpOnlyOnce() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("[{\"pinned\": true, oops".utf8).write(to: url)
    for _ in 0..<3 { HistoryStore(fileURL: url, vault: TestVault()).flush() }
    #expect(backups(in: dir).count == 1)
  }

  @Test func recopyingARestoredPinKeepsItsPlaintextOffDisk() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = TestVault()
    let plain = "token: v1.2.3-beta4"  // pinned while an older detector flagged it
    var pin = text("token: ••••••••"); pin.pinned = true
    try writeLegacy([pin], to: url)
    _ = vault.store(plain, for: pin.id)
    let store = HistoryStore(fileURL: url, vault: vault)
    store.flush()
    var again = text(plain); again.expiresAt = Date().addingTimeInterval(60)
    let merged = store.add(again)
    #expect(merged.id == pin.id && !merged.findings.isEmpty && merged.expiresAt == nil)
    store.flush()
    for data in allBytes(under: dir) { #expect(!String(decoding: data, as: UTF8.self).contains("v1.2.3")) }
    #expect(vault.all[pin.id] == plain)
  }

  @Test func legacyPlaintextAlreadyInVaultIsScrubbed() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = TestVault()
    let legacy = flagged(Self.fakeSecret, pinned: true)
    try writeLegacy([legacy], to: url)
    _ = vault.store(Self.fakeSecret, for: legacy.id)  // vault write succeeded, the JSON write did not
    HistoryStore(fileURL: url, vault: vault).flush()
    #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("FAKEFAKEFAKE"))
    #expect(vault.all[legacy.id] == Self.fakeSecret)
  }

  @Test func vaultListingFailureDeletesNothing() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = TestVault()
    let id = pinnedSecretOnDisk(Self.fakeSecret, at: url, vault: vault)
    let other = UUID(); _ = vault.store("sk-proj-OTHERFAKEOTHERFAKE00000", for: other)
    vault.listFails = true
    let store = HistoryStore(fileURL: url, vault: vault)
    store.flush()
    #expect(store.entries(matching: "").first?.text == Self.fakeSecret)  // still restored, by id
    store.togglePin(id); store.remove(id); store.flush()
    #expect(vault.all.count == 2)
  }

  @Test func refusedVaultWritesAreReported() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = TestVault(); vault.storeFails = true
    let store = HistoryStore(fileURL: url, vault: vault)
    let e = store.add(flagged(Self.fakeSecret, pinned: true)); store.flush()
    #expect(store.pinsNotSavedToVault == [e.id])
    vault.storeFails = false
    store.retryVaultWrites(); store.flush()
    #expect(store.pinsNotSavedToVault.isEmpty)
    #expect(vault.all[e.id] == Self.fakeSecret)
  }

  @Test func emptyVaultListsAsEmptyNotUnavailable() throws {
    // An injected in-memory vault: tests never touch the user's login Keychain.
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let vault = InMemoryVault()
    #expect(vault.ids() == [])  // empty, not nil (nil would mean "could not be listed")
    let store = HistoryStore(fileURL: url, vault: vault)
    _ = store.add(text("plain")); store.flush()
    #expect(vault.ids() == [])
  }
}
