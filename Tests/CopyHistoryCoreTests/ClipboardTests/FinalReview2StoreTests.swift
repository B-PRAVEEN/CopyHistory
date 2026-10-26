import Foundation
import Testing
@testable import CopyHistoryCore

// Final review 2: FF-M1 (a side file that was unreadable and then went missing never unflags pins),
// FF-M2 (a kept pin left out of a write is retried by the next flush, and its flagged PNG is not
// orphaned at quit), FF-L1 (a legacy vault-restored image pin gets its exact text back after every
// relaunch), FF-L3 (no post from deinit) and the FF-L5 store test gaps. Temporary directories and
// in-memory vaults only: never the real Keychain or Application Support.

private let fakeKeyLine = "API_KEY=sk-proj-abcdefghjkmnpqrstuvwxyzABCDEFGH"  // fake fixture, not a real key
private let fakeKeyBody = "sk-proj-abcdefghjkmnpqrstuvwxyz"

private func tempURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("CHFinal2Test-\(UUID())/history.json")
}

private func sideURL(next url: URL) -> URL {
  url.deletingLastPathComponent().appendingPathComponent("history.flagged-pins.json")
}

private func pngURL(_ id: UUID, next url: URL) -> URL {
  url.deletingLastPathComponent().appendingPathComponent("images/\(id.uuidString).png")
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func fileText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

private func listedIDs(next url: URL) -> Set<UUID>? {
  guard let data = try? Data(contentsOf: sideURL(next: url)),
        let raw = try? JSONDecoder().decode([String].self, from: data) else { return nil }
  let ids = raw.compactMap(UUID.init(uuidString:))
  return ids.count == raw.count ? Set(ids) : nil
}

private func setPermissions(_ mode: Int, _ url: URL) throws {
  try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func open(_ url: URL, vault: SecretVault = InMemoryVault()) -> HistoryStore {
  let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
  store.flush()  // after the launch-time vault restore and write
  return store
}

private func entry(_ store: HistoryStore, _ id: UUID) -> ClipboardEntry? {
  store.entries(matching: "").first { $0.id == id }
}

/// A pinned image saved clean ("Release notes").
private func saveCleanPin(_ store: HistoryStore, width: Int = 40) -> ClipboardEntry {
  let png = makeImage(width: width, height: 20, type: "public.png")
  let pin = store.add(ClipboardEntry(kind: .image, imagePNG: png, pinned: true), awaitingOCR: true)
  store.applyOCR(OCRUpdate(entryID: pin.id, imagePNG: png, scanned: true, ocrText: "Release notes"))
  store.flush()
  return pin
}

/// The OCR of a re-copy of `pin`'s bytes now reads a key.
private func flagByRecopy(_ store: HistoryStore, _ pin: ClipboardEntry) {
  store.applyOCR(OCRUpdate(entryID: UUID(), imagePNG: pin.imagePNG!, scanned: true,
                           ocrText: fakeKeyLine, findings: SecretDetector().scan(fakeKeyLine)))
}

/// A non-empty directory where the side file goes: the atomic rename onto it fails.
private func blockSideFile(_ url: URL) throws {
  let dir = sideURL(next: url)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try Data("x".utf8).write(to: dir.appendingPathComponent("keep"))
}

/// Flagged in memory, pasted concealed, its pixels hidden.
private func expectFlagged(_ store: HistoryStore, _ id: UUID) throws {
  let e = try #require(entry(store, id))
  #expect(e.pinned)
  #expect(!e.findings.isEmpty)
  #expect(PastePolicy.sensitivity(of: e) == true)
  #expect(PopupPolicy.hiddenThumbnailHelp(for: e, live: store.pasteState(of: id)) == PopupPolicy.hiddenFlaggedThumbnailHelp)
}

/// Expects `id` to be a pinned, flagged image whose files are on disk and listed in the side file.
private func expectKeptFlaggedPin(_ store: HistoryStore, _ id: UUID, url: URL) throws {
  try expectFlagged(store, id)
  #expect(store.flaggedPinsKeptOnDisk.contains(id))
  #expect(exists(pngURL(id, next: url)))
  #expect(fileText(url).contains(id.uuidString))
  #expect(listedIDs(next: url)?.contains(id) == true)
}

/// Counts `didUpdateEntriesNotification` posts by the store with this identity. Never keeps the
/// sender: it only compares identities.
private final class PostCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _count = 0
  private var token: NSObjectProtocol?
  var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
  init(sender: ObjectIdentifier) {
    token = NotificationCenter.default.addObserver(forName: HistoryStore.didUpdateEntriesNotification,
                                                   object: nil, queue: nil) { [weak self] note in
      guard let self, let object = note.object as AnyObject?, ObjectIdentifier(object) == sender else { return }
      self.lock.lock(); self._count += 1; self.lock.unlock()
    }
  }
  deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

// MARK: - FF-M1

/// A side file that was unreadable at launch and then disappears is not a successful read of an
/// empty list: every suspect stays flagged, and the fail-closed superset is written so a relaunch
/// loads them flagged too.
@Suite struct MissingAfterUnreadableSideFileTests {
  /// A clean pin listed in the side file (flagged later), and the store reopened while it is unreadable.
  private func unreadableAtLaunch(_ url: URL) throws -> (HistoryStore, ClipboardEntry) {
    let first = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let pin = saveCleanPin(first)
    flagByRecopy(first, pin)
    first.flush()
    #expect(listedIDs(next: url) == [pin.id])
    try setPermissions(0o000, sideURL(next: url))
    let store = open(url)
    try expectFlagged(store, pin.id)  // fails closed at launch
    return (store, pin)
  }

  @Test func aLaterWriteKeepsThePinFlaggedAcrossARelaunch() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = try unreadableAtLaunch(url)

    try FileManager.default.removeItem(at: sideURL(next: url))  // a sync or cleanup tool
    _ = store.add(ClipboardEntry(kind: .text, text: "something else"))
    store.flush()
    try expectFlagged(store, pin.id)
    #expect(store.isUnscannedImage(pin.id) == false)
    #expect(listedIDs(next: url) == [pin.id])  // the superset, written from known state
    #expect(!fileText(url).contains(fakeKeyBody))
    try expectKeptFlaggedPin(store, pin.id, url: url)

    let reopened = open(url)
    try expectKeptFlaggedPin(reopened, pin.id, url: url)
  }

  /// No other change before quitting: the flush at quit still writes the superset.
  @Test func aFlushWithNoChangeWritesTheSuperset() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = try unreadableAtLaunch(url)

    try FileManager.default.removeItem(at: sideURL(next: url))
    store.flushForTermination()
    try expectFlagged(store, pin.id)
    #expect(listedIDs(next: url) == [pin.id])
    #expect(exists(pngURL(pin.id, next: url)))  // a suspect's files are never removed at quit

    let reopened = open(url)
    try expectKeptFlaggedPin(reopened, pin.id, url: url)
  }

  /// FF-L5 gap: a suspect the user unpins, then a readable side file that does not list it, becomes
  /// an ordinary clean unpinned image; its PNG is kept, and it reloads clean.
  @Test func anUnpinnedSuspectThatRecoveryClearsIsAnOrdinaryCleanImage() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let pin = saveCleanPin(HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault()))
    try Data("not json".utf8).write(to: sideURL(next: url))  // undecodable: fails closed
    let store = open(url)
    try expectFlagged(store, pin.id)

    store.togglePin(pin.id)
    try Data("[]".utf8).write(to: sideURL(next: url))  // readable again, lists nothing
    store.flush()
    let e = try #require(entry(store, pin.id))
    #expect(!e.pinned)
    #expect(e.findings.isEmpty)
    #expect(store.isUnscannedImage(pin.id) == false)
    #expect(PopupPolicy.hiddenThumbnailHelp(for: e, live: store.pasteState(of: pin.id)) == nil)
    #expect(exists(pngURL(pin.id, next: url)))
    #expect(fileText(url).contains(pin.id.uuidString))

    let reopened = open(url)
    let again = try #require(entry(reopened, pin.id))
    #expect(!again.pinned && again.findings.isEmpty)
    #expect(reopened.isUnscannedImage(pin.id) == false)
  }
}

// MARK: - FF-M2

/// A kept pin left out of a write while the side file could not be written: the next flush (also
/// the one at quit) saves it once the file is writable, without any other change, and Settings can
/// retry it. If it still fails at quit, its flagged PNG is removed rather than orphaned.
@Suite struct UnlistedPinRetryTests {
  private func unlistedPin(_ url: URL) throws -> (HistoryStore, ClipboardEntry) {
    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let pin = saveCleanPin(store)
    try blockSideFile(url)
    flagByRecopy(store, pin)
    store.flush()
    #expect(store.flaggedPinsNotSaved == [pin.id])
    #expect(!fileText(url).contains(pin.id.uuidString))
    #expect(VaultStatus(store).canRetry)  // the Settings button is shown for it
    return (store, pin)
  }

  @Test func theNextFlushSavesItWithNoOtherChange() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = try unlistedPin(url)
    store.flush()  // still blocked: still left out
    #expect(store.flaggedPinsNotSaved == [pin.id])

    try FileManager.default.removeItem(at: sideURL(next: url))
    store.flush()  // as at quit: nothing else changed
    #expect(store.flaggedPinsNotSaved.isEmpty)
    #expect(VaultStatus(store).isHealthy)
    try expectKeptFlaggedPin(store, pin.id, url: url)
    try expectKeptFlaggedPin(open(url), pin.id, url: url)
  }

  @Test func theQuitFlushSavesItOnceWritable() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = try unlistedPin(url)
    try FileManager.default.removeItem(at: sideURL(next: url))
    store.flushForTermination()
    #expect(store.flaggedPinsNotSaved.isEmpty)
    try expectKeptFlaggedPin(open(url), pin.id, url: url)
  }

  @Test func stillFailingAtQuitRemovesItsPNG() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = try unlistedPin(url)
    #expect(exists(pngURL(pin.id, next: url)))  // kept while the session may still save it
    store.flushForTermination()
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!fileText(url).contains(pin.id.uuidString))

    let reopened = open(url)
    #expect(entry(reopened, pin.id) == nil)
    let images = (try? FileManager.default.contentsOfDirectory(atPath: pngURL(pin.id, next: url).deletingLastPathComponent().path)) ?? []
    #expect(images.isEmpty)
  }

  /// The retry (Settings) path still works too.
  @Test func retryVaultWritesSavesIt() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = try unlistedPin(url)
    try FileManager.default.removeItem(at: sideURL(next: url))
    store.retryVaultWrites()
    store.flush()
    try expectKeptFlaggedPin(store, pin.id, url: url)
  }
}

// MARK: - FF-L1

/// A legacy pinned image whose OCR text an older version vaulted gets its exact text back after
/// every relaunch, not only the first one (it is listed in the side file from then on).
@Suite struct LegacyVaultImagePinRelaunchTests {
  private let secret = "sk-proj-LEGACYFAKELEGACYFAKE1234"  // fake fixture, not a real key

  @Test func exactTextAfterASecondRelaunch() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let id = UUID()
    let png = makeImage(width: 44, height: 22, type: "public.png")
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
    try png.write(to: pngURL(id, next: url))
    let json = """
    [{"id":"\(id.uuidString)","kind":"image","pinned":true,"copyCount":1,"ocrText":"staging key: sk-proj-••••••••",
      "firstCopiedAt":"2026-01-01T00:00:00Z","lastCopiedAt":"2026-01-01T00:00:00Z","findings":[]}]
    """
    try Data(json.utf8).write(to: url)
    let vault = InMemoryVault()
    _ = vault.store("staging key: \(secret)", for: id)

    let first = open(url, vault: vault)
    first.flush()
    #expect(entry(first, id)?.ocrText == "staging key: \(secret)")
    #expect(listedIDs(next: url) == [id])

    for _ in 0..<2 {
      let reopened = open(url, vault: vault)
      try expectKeptFlaggedPin(reopened, id, url: url)
      #expect(entry(reopened, id)?.ocrText == "staging key: \(secret)")  // exact, not masked
      #expect(!fileText(url).contains(secret))
      #expect(vault.load(id) != nil)
    }
  }
}

// MARK: - FF-L3

/// The final flush in deinit can clear suspects (the side file reads again), but never posts with
/// the deallocating store as the object.
@Suite struct NoPostFromDeinitTests {
  @Test func recoveryInDeinitDoesNotPost() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let pin = saveCleanPin(HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault()))
    try Data("not json".utf8).write(to: sideURL(next: url))
    var store: HistoryStore? = open(url)
    let counter = PostCounter(sender: ObjectIdentifier(store!))
    try expectFlagged(store!, pin.id)
    try Data("[]".utf8).write(to: sideURL(next: url))
    _ = store!.add(ClipboardEntry(kind: .text, text: "pending"))  // the debounced save is cancelled by deinit
    store = nil  // deinit flushes: the side file reads, the suspect is cleared
    #expect(counter.count == 0)
    #expect(listedIDs(next: url) == [])
    let reopened = open(url)
    #expect(entry(reopened, pin.id)?.findings.isEmpty == true)  // the recovery did happen
  }

  /// Outside deinit the same recovery still posts, so a visible list reloads.
  @Test func recoveryOutsideDeinitPosts() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let pin = saveCleanPin(HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault()))
    try Data("not json".utf8).write(to: sideURL(next: url))
    let store = open(url)
    let counter = PostCounter(sender: ObjectIdentifier(store))
    try Data("[]".utf8).write(to: sideURL(next: url))
    _ = store.add(ClipboardEntry(kind: .text, text: "pending"))
    store.flush()
    #expect(counter.count == 1)
    #expect(entry(store, pin.id)?.findings.isEmpty == true)
  }
}

// MARK: - FF-L5: notification deadlock pattern

/// The popup's observers use `queue: nil` and hop to their own queue with `async`: a post from the
/// store's queue inside a `flush()` that the observer's queue is blocked in completes. A stand-in
/// serial queue plays the main thread.
@Suite struct UpdatePostDuringFlushTests {
  @Test(.timeLimit(.minutes(1))) func asyncHoppingObserverDoesNotDeadlockAFlush() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let pin = saveCleanPin(HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault()))
    try Data("not json".utf8).write(to: sideURL(next: url))
    let store = open(url)
    try Data("[]".utf8).write(to: sideURL(next: url))
    _ = store.add(ClipboardEntry(kind: .text, text: "pending"))

    let main = DispatchQueue(label: "CopyHistoryTests.fakeMain")
    let delivered = DispatchSemaphore(value: 0)
    let token = NotificationCenter.default.addObserver(forName: HistoryStore.didUpdateEntriesNotification,
                                                       object: store, queue: nil) { _ in
      main.async { delivered.signal() }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let flushed = DispatchSemaphore(value: 0)
    main.async { store.flush(); flushed.signal() }  // the post happens while `main` is in flush()
    #expect(flushed.wait(timeout: .now() + 10) == .success)
    #expect(delivered.wait(timeout: .now() + 10) == .success)
    #expect(entry(store, pin.id)?.findings.isEmpty == true)
  }
}
