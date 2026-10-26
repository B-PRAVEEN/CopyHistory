import Foundation
import Testing
@testable import CopyHistoryCore

// Review round 2: F2-M1 (stale popup snapshot), F2-M2 (re-pinning a kept flagged pin), F2-L1 (the
// side file's fail-closed state is not sticky), F2-L2 (a side-file write failure does not stop
// history writes) and F2-L5 (legacy vault-restored image pins keep their files). Temporary
// directories and in-memory vaults only: never the real Keychain or Application Support.

private let fakeKeyLine = "API_KEY=sk-proj-abcdefghjkmnpqrstuvwxyzABCDEFGH"  // fake fixture, not a real key
private let fakeKeyBody = "sk-proj-abcdefghjkmnpqrstuvwxyz"

private func tempURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("CHRound2Test-\(UUID())/history.json")
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

private func open(_ url: URL, vault: SecretVault = InMemoryVault()) -> HistoryStore {
  let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
  store.flush()  // after the launch-time vault restore and write
  return store
}

private func keyFindings() -> [SecretFinding] { SecretDetector().scan(fakeKeyLine) }

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
                           ocrText: fakeKeyLine, findings: keyFindings()))
}

/// A pinned image saved clean, then flagged by the OCR of a re-copy and written as a kept pin.
private func savedPinFlaggedLater(url: URL) -> (HistoryStore, ClipboardEntry) {
  let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
  let pin = saveCleanPin(store)
  flagByRecopy(store, pin)
  store.flush()
  return (store, pin)
}

private func entry(_ store: HistoryStore, _ id: UUID) -> ClipboardEntry? {
  store.entries(matching: "").first { $0.id == id }
}

/// Expects `id` to be a pinned, flagged image whose files are on disk and listed in the side file.
private func expectKeptFlaggedPin(_ store: HistoryStore, _ id: UUID, url: URL) throws {
  let e = try #require(entry(store, id))
  #expect(e.pinned)
  #expect(!e.findings.isEmpty)
  #expect(PopupPolicy.hiddenThumbnailHelp(for: e, live: store.pasteState(of: id)) == PopupPolicy.hiddenFlaggedThumbnailHelp)
  #expect(store.flaggedPinsKeptOnDisk.contains(id))
  #expect(exists(pngURL(id, next: url)))
  #expect(fileText(url).contains(id.uuidString))
  #expect(listedIDs(next: url)?.contains(id) == true)
}

/// Counts `didUpdateEntriesNotification` posts for `store` (posted synchronously by the store).
private final class UpdateCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var _count = 0
  private var token: NSObjectProtocol?
  var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
  init(_ store: HistoryStore) {
    token = NotificationCenter.default.addObserver(forName: HistoryStore.didUpdateEntriesNotification,
                                                   object: store, queue: nil) { [weak self] _ in
      guard let self else { return }
      self.lock.lock(); self._count += 1; self.lock.unlock()
    }
  }
  deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

// MARK: - F2-M1

/// An open popup decides thumbnail visibility from the store as it is now, never from its snapshot.
@Suite struct StalePopupSnapshotTests {
  @Test func imageFlaggedAfterTheSnapshotStaysHidden() throws {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let png = makeImage(width: 30, height: 30, type: "public.png")
    let image = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    let snapshot = try #require(entry(store, image.id))  // the popup's row, loaded while unscanned
    #expect(PopupPolicy.hiddenThumbnailHelp(for: snapshot, live: store.pasteState(of: image.id))
            == PopupPolicy.hiddenUnscannedThumbnailHelp)

    store.applyOCR(OCRUpdate(entryID: image.id, imagePNG: png, scanned: true, ocrText: fakeKeyLine,
                             findings: keyFindings()))
    // The old decision (snapshot findings + live "unscanned") would show the pixels now.
    #expect(snapshot.findings.isEmpty && !store.isUnscannedImage(image.id))
    #expect(PopupPolicy.hiddenThumbnailHelp(for: snapshot, unscanned: store.isUnscannedImage(image.id)) == nil)
    // The live decision hides them.
    #expect(PopupPolicy.hiddenThumbnailHelp(for: snapshot, live: store.pasteState(of: image.id))
            == PopupPolicy.hiddenFlaggedThumbnailHelp)
  }

  /// A row loaded clean (thumbnail shown) is hidden once a re-copy's OCR flags the same image.
  @Test func cleanRowFlaggedLaterIsHidden() throws {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let png = makeImage(width: 31, height: 31, type: "public.png")
    let image = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: image.id, imagePNG: png, scanned: true, ocrText: "Release notes"))
    let snapshot = try #require(entry(store, image.id))
    #expect(PopupPolicy.hiddenThumbnailHelp(for: snapshot, live: store.pasteState(of: image.id)) == nil)

    store.applyOCR(OCRUpdate(entryID: UUID(), imagePNG: png, scanned: true, ocrText: fakeKeyLine,
                             findings: keyFindings()))
    #expect(PopupPolicy.hiddenThumbnailHelp(for: snapshot, live: store.pasteState(of: image.id))
            == PopupPolicy.hiddenFlaggedThumbnailHelp)
    // The live entry's snippet is masked, so the row cannot show the key as text either.
    let live = try #require(store.pasteState(of: image.id)?.entry)
    let snippet = try #require(PopupPolicy.ocrSnippet(for: live, detector: SecretDetector()))
    #expect(!snippet.contains(fakeKeyBody))
  }

  @Test func goneOrUnknownEntriesFailClosed() {
    let png = makeImage(width: 8, height: 8, type: "public.png")
    let clean = ClipboardEntry(kind: .image, imagePNG: png)
    #expect(PopupPolicy.hiddenThumbnailHelp(for: clean, live: nil) == PopupPolicy.hiddenUnscannedThumbnailHelp)
    let flagged = ClipboardEntry(kind: .image, imagePNG: png, findings: keyFindings())
    #expect(PopupPolicy.hiddenThumbnailHelp(for: flagged, live: (clean, false)) == PopupPolicy.hiddenFlaggedThumbnailHelp)
    #expect(PopupPolicy.hiddenThumbnailHelp(for: clean, live: (clean, false)) == nil)
    #expect(PopupPolicy.hiddenThumbnailHelp(for: clean, live: (ClipboardEntry(kind: .text, text: "x"), false))
            == PopupPolicy.hiddenUnscannedThumbnailHelp)
    #expect(PopupPolicy.hiddenThumbnailHelp(for: ClipboardEntry(kind: .text, text: "x"), live: nil) == nil)
  }

  /// The popup reloads on this notification, so the row's mask and shield icon update too.
  @Test func applyingOCRPostsAnUpdate() {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let counter = UpdateCounter(store)
    let png = makeImage(width: 32, height: 32, type: "public.png")
    let image = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    #expect(counter.count == 0)
    store.applyOCR(OCRUpdate(entryID: image.id, imagePNG: png, scanned: true, ocrText: fakeKeyLine,
                             findings: keyFindings()))
    #expect(counter.count == 1)
    // Nothing changes (already flagged, same expiry; an entry that is gone): no post.
    store.applyOCR(OCRUpdate(entryID: image.id, imagePNG: png, scanned: true, ocrText: fakeKeyLine,
                             findings: keyFindings()))
    store.applyOCR(OCRUpdate(entryID: UUID(), imagePNG: Data([9]), scanned: true, ocrText: nil))
    #expect(counter.count == 1)
  }
}

// MARK: - F2-M2

/// Unpinning a kept flagged pin and pinning it again before the next write keeps it, on disk and
/// in the side file. Once a write has removed its files, pinning it again never writes them back.
@Suite struct RepinKeptFlaggedPinTests {
  @Test func toggleTwiceBeforeAWriteKeepsIt() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = savedPinFlaggedLater(url: url)
    try expectKeptFlaggedPin(store, pin.id, url: url)
    store.togglePin(pin.id)
    #expect(store.flaggedPinsKeptOnDisk.isEmpty)
    store.togglePin(pin.id)
    #expect(store.flaggedPinsKeptOnDisk == [pin.id])  // the ⚠︎ note is back
    store.flush()
    try expectKeptFlaggedPin(store, pin.id, url: url)

    let reopened = open(url)
    try expectKeptFlaggedPin(reopened, pin.id, url: url)
    #expect(entry(reopened, pin.id)?.imagePNG == pin.imagePNG)
  }

  /// The same for a pin loaded flagged from the side file at launch.
  @Test func toggleTwiceAfterARelaunchKeepsIt() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (_, pin) = savedPinFlaggedLater(url: url)
    let reopened = open(url)
    reopened.togglePin(pin.id)
    reopened.togglePin(pin.id)
    reopened.flush()
    try expectKeptFlaggedPin(reopened, pin.id, url: url)
    try expectKeptFlaggedPin(open(url), pin.id, url: url)
  }

  /// Unpin, write (files removed), pin again: it stays pinned and flagged in memory, but its flagged
  /// PNG is never written back and it is not listed.
  @Test func repinAfterTheWriteRemovedItStaysOffDisk() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = savedPinFlaggedLater(url: url)
    store.togglePin(pin.id)
    store.flush()
    #expect(!exists(pngURL(pin.id, next: url)))
    store.togglePin(pin.id)
    store.flush()
    let e = try #require(entry(store, pin.id))
    #expect(e.pinned && !e.findings.isEmpty)
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!fileText(url).contains(pin.id.uuidString))
    #expect(!exists(sideURL(next: url)))
    #expect(store.flaggedPinsKeptOnDisk.isEmpty)
  }

  /// The same for a pin loaded from disk (its id was in `loadedImageIDs`, which also allows a write).
  @Test func repinAfterTheWriteRemovedALoadedPinStaysOffDisk() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (_, pin) = savedPinFlaggedLater(url: url)
    let reopened = open(url)
    reopened.togglePin(pin.id)
    reopened.flush()
    #expect(!exists(pngURL(pin.id, next: url)))
    reopened.togglePin(pin.id)
    _ = reopened.add(ClipboardEntry(kind: .text, text: "touch"))
    reopened.flush()
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!fileText(url).contains(pin.id.uuidString))
    #expect(listedIDs(next: url)?.contains(pin.id) != true)
    #expect(entry(open(url), pin.id) == nil)
  }
}

// MARK: - F2-L1

/// The fail-closed state of an unreadable side file is never persisted; a later successful read
/// restores the true set, and nothing a scan confirmed is cleared by it.
@Suite struct SideFileRecoveryTests {
  private func makeUnreadable(_ url: URL, listing ids: [UUID]) throws {
    try JSONEncoder().encode(ids.map(\.uuidString)).write(to: sideURL(next: url))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sideURL(next: url).path)
  }

  private func makeReadable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sideURL(next: url).path)
  }

  /// The file lists one of two pins: once readable, the listed one stays flagged and the other is
  /// clean again, without any file being touched or the store being reopened.
  @Test func laterReadRestoresTheTrueSet() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, flaggedPin) = savedPinFlaggedLater(url: url)
    let cleanPin = saveCleanPin(store, width: 50)
    #expect(listedIDs(next: url) == [flaggedPin.id])
    try makeUnreadable(url, listing: [flaggedPin.id])

    let reopened = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let counter = UpdateCounter(reopened)
    reopened.flush()
    #expect(entry(reopened, cleanPin.id)?.findings.isEmpty == false)  // fail closed
    #expect(entry(reopened, flaggedPin.id)?.findings.isEmpty == false)

    try makeReadable(url)
    _ = reopened.add(ClipboardEntry(kind: .text, text: "touch"))
    reopened.flush()
    let clean = try #require(entry(reopened, cleanPin.id))
    #expect(clean.findings.isEmpty)
    #expect(PopupPolicy.hiddenThumbnailHelp(for: clean, live: reopened.pasteState(of: cleanPin.id)) == nil)
    #expect(!reopened.flaggedPinsKeptOnDisk.contains(cleanPin.id))
    #expect(exists(pngURL(cleanPin.id, next: url)))
    try expectKeptFlaggedPin(reopened, flaggedPin.id, url: url)
    #expect(listedIDs(next: url) == [flaggedPin.id])
    #expect(counter.count >= 1)  // a visible popup reloads

    let again = open(url)
    #expect(entry(again, cleanPin.id)?.findings.isEmpty == true)
    try expectKeptFlaggedPin(again, flaggedPin.id, url: url)
  }

  /// A suspect pin that a scan really flags this session is confirmed: the recovery read (which
  /// does not list it) must not clear it.
  @Test func aScanConfirmedSuspectIsNotCleared() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let seed = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let pin = saveCleanPin(seed)
    try makeUnreadable(url, listing: [])

    let reopened = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    reopened.flush()
    flagByRecopy(reopened, pin)
    try makeReadable(url)
    reopened.flush()
    let e = try #require(entry(reopened, pin.id))
    #expect(!e.findings.isEmpty)
    #expect(e.ocrText == fakeKeyLine)  // in memory; masked on disk
    try expectKeptFlaggedPin(reopened, pin.id, url: url)
    #expect(!fileText(url).contains(fakeKeyBody))
    try expectKeptFlaggedPin(open(url), pin.id, url: url)
  }

  /// Still unreadable when a pin flagged this session must be listed: the file is replaced by the
  /// fail-closed superset, so neither the new pin nor any suspect loads unflagged.
  @Test func unreadableFileIsReplacedOnlyWhenANewPinMustBeListed() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let seed = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let suspect = saveCleanPin(seed)
    let later = saveCleanPin(seed, width: 60)
    try Data("garbage".utf8).write(to: sideURL(next: url))

    let reopened = open(url)
    _ = reopened.add(ClipboardEntry(kind: .text, text: "touch"))
    reopened.flush()
    #expect(fileText(sideURL(next: url)) == "garbage")  // nothing new to list: left alone
    flagByRecopy(reopened, later)
    reopened.flush()
    #expect(listedIDs(next: url) == [suspect.id, later.id])
    #expect(!fileText(url).contains(fakeKeyBody))
    let again = open(url)
    try expectKeptFlaggedPin(again, suspect.id, url: url)
    try expectKeptFlaggedPin(again, later.id, url: url)
  }
}

// MARK: - F2-L2

/// The side file cannot be written: history is still saved, the affected pin is left out of the
/// JSON (memory only, PNG kept) instead of being saved where a relaunch loads it unflagged, and
/// Settings says so. A later successful write saves it.
@Suite struct SideFileWriteFailureTests {
  /// A non-empty directory where the side file goes: the atomic rename onto it fails.
  private func blockSideFile(_ url: URL) throws {
    let dir = sideURL(next: url)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: dir.appendingPathComponent("keep"))
  }

  @Test func historyIsStillWrittenAndTheStatusSaysSo() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let pin = saveCleanPin(store)
    try blockSideFile(url)

    flagByRecopy(store, pin)
    _ = store.add(ClipboardEntry(kind: .text, text: "saved despite the side file", pinned: true))
    store.flush()
    let json = fileText(url)
    #expect(json.contains("saved despite the side file"))  // the rest of history is written
    #expect(!json.contains(pin.id.uuidString))           // never saved where it would load unflagged
    #expect(!json.contains(fakeKeyBody))
    #expect(exists(pngURL(pin.id, next: url)))           // its PNG is kept, not deleted
    #expect(store.flaggedPinsNotSaved == [pin.id])
    #expect(store.flaggedPinsKeptOnDisk.isEmpty)
    let e = try #require(entry(store, pin.id))
    #expect(e.pinned && !e.findings.isEmpty)               // still there this session, still flagged
    let status = VaultStatus(store)
    #expect(status.unsavedFlaggedImageCount == 1)
    #expect(!status.isHealthy)
    #expect(status.messages.contains { $0.contains("1 pinned image with sensitive text was not saved") })

    // A relaunch while it is still failing never shows the image unflagged.
    let meanwhile = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    #expect(entry(meanwhile, pin.id) == nil)
    #expect(meanwhile.entries(matching: "").contains { $0.text == "saved despite the side file" })

    // Once the side file can be written, the next write (here the retry) saves the pin.
    try FileManager.default.removeItem(at: sideURL(next: url))
    store.retryVaultWrites()
    store.flush()
    #expect(store.flaggedPinsNotSaved.isEmpty)
    #expect(VaultStatus(store).isHealthy)
    try expectKeptFlaggedPin(store, pin.id, url: url)
    try expectKeptFlaggedPin(open(url), pin.id, url: url)
  }
}

// MARK: - F2-L5

/// A legacy pinned image whose OCR text an older version vaulted keeps its files once the restore
/// confirms it is flagged, like a saved pin a later scan flagged: masked on disk, listed in the side
/// file, removed from disk (and the vault) only when unpinned.
@Suite struct LegacyVaultImagePinTests {
  private let secret = "sk-proj-LEGACYFAKELEGACYFAKE1234"  // fake fixture, not a real key

  private func legacyPinnedImage(at url: URL) throws -> (UUID, Data) {
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
    return (id, png)
  }

  @Test func keepsItsFilesUntilUnpinned() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (id, png) = try legacyPinnedImage(at: url)
    let vault = InMemoryVault()
    _ = vault.store("staging key: \(secret)", for: id)

    let store = open(url, vault: vault)
    store.flush()  // the write the restore scheduled
    try expectKeptFlaggedPin(store, id, url: url)
    #expect(entry(store, id)?.ocrText == "staging key: \(secret)")  // exact text in memory
    #expect(!fileText(url).contains(secret))                         // masked on disk
    #expect(!fileText(sideURL(next: url)).contains(secret))

    // Next launch: flagged from the side file before any vault read, PNG intact.
    let reopened = open(url, vault: vault)
    try expectKeptFlaggedPin(reopened, id, url: url)
    #expect(entry(reopened, id)?.imagePNG == png)

    reopened.togglePin(id)
    reopened.flush()
    #expect(!exists(pngURL(id, next: url)))
    #expect(!fileText(url).contains(id.uuidString))
    #expect(vault.load(id) == nil)  // an unpinned flagged item leaves the vault like any other
  }
}
