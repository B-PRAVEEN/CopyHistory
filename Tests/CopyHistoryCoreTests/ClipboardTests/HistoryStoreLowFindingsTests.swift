import Foundation
import Testing
@testable import CopyHistoryCore

// Review R-L3, R-L4 and the cancellable save timer. Never touches the real Keychain or Application
// Support: temporary directories and fake vaults only.

private let fakeKeyLine = "API_KEY=sk-proj-abcdefghjkmnpqrstuvwxyzABCDEFGH"  // fake fixture, not a real key

private func tempURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("CHLowTest-\(UUID())/history.json")
}

private func pngURL(_ id: UUID, next url: URL) -> URL {
  url.deletingLastPathComponent().appendingPathComponent("images/\(id.uuidString).png")
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func fileText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

/// A vault that lists items it cannot read (e.g. Keychain access denied after a re-sign).
private final class UnreadableVault: SecretVault, @unchecked Sendable {
  private let lock = NSLock()
  private let listed: Set<UUID>
  private var _removed: Set<UUID> = []
  var removed: Set<UUID> { lock.lock(); defer { lock.unlock() }; return _removed }
  init(listing: Set<UUID>) { listed = listing }
  func store(_ text: String, for id: UUID) -> Bool { false }
  func load(_ id: UUID) -> String? { nil }
  func remove(_ id: UUID) { lock.lock(); _removed.insert(id); lock.unlock() }
  func ids() -> Set<UUID>? { listed }
  func loadAll(_ ids: Set<UUID>) -> [UUID: String] { [:] }
}

/// R-L3: a pinned image already saved clean, then flagged by a later scan (a re-copy of the same bytes).
@Suite struct FlaggedSavedPinTests {
  private func savedCleanPin(url: URL) -> (HistoryStore, ClipboardEntry) {
    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let png = makeImage(width: 40, height: 20, type: "public.png")
    let pin = store.add(ClipboardEntry(kind: .image, imagePNG: png, pinned: true), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: pin.id, imagePNG: png, scanned: true, ocrText: "Release notes"))
    store.flush()
    return (store, pin)
  }

  private func flagByRecopy(_ store: HistoryStore, _ pin: ClipboardEntry) {
    let findings = SecretDetector().scan(fakeKeyLine)
    #expect(!findings.isEmpty)
    // A new copy of the same bytes, folded into the pin; its OCR update finds the entry by bytes.
    store.applyOCR(OCRUpdate(entryID: UUID(), imagePNG: pin.imagePNG!, scanned: true, ocrText: fakeKeyLine,
                             findings: findings))
  }

  @Test func flaggedInMemoryButFilesKeptUntilUnpinned() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = savedCleanPin(url: url)
    #expect(exists(pngURL(pin.id, next: url)))

    flagByRecopy(store, pin)
    let entry = try #require(store.entries(matching: "").first { $0.id == pin.id })
    #expect(!entry.findings.isEmpty)               // masked and pasted concealed this session
    store.flush()
    #expect(store.flaggedPinsKeptOnDisk == [pin.id])
    #expect(exists(pngURL(pin.id, next: url)))     // not silently un-persisted
    let json = fileText(url)
    #expect(json.contains(pin.id.uuidString))
    #expect(!json.contains("sk-proj-abcdefghjkmnpqrstuvwxyz"))  // the new OCR text is masked on disk

    store.togglePin(pin.id)                        // the user's unpin is what removes it
    #expect(store.flaggedPinsKeptOnDisk.isEmpty)
    store.flush()
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!fileText(url).contains(pin.id.uuidString))
  }

  @Test func survivesRelaunchWithoutPlaintext() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = savedCleanPin(url: url)
    flagByRecopy(store, pin)
    store.flush()

    let reopened = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    reopened.flush()
    let entry = try #require(reopened.entries(matching: "").first { $0.id == pin.id })
    #expect(entry.pinned)
    #expect(entry.imagePNG == pin.imagePNG)
    #expect(!(entry.ocrText ?? "").contains("sk-proj-abcdefghjkmnpqrstuvwxyz"))
  }

  /// The exception only covers pins whose files were already written: an unsaved pin stays memory-only.
  @Test func pinNotYetWrittenStaysMemoryOnly() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = HistoryStore(fileURL: url, saveDelay: 600, purgeInterval: nil, vault: InMemoryVault())
    store.flush()  // the launch-time write has run; the next one is 600 s away
    let png = makeImage(width: 40, height: 20, type: "public.png")
    let pin = store.add(ClipboardEntry(kind: .image, imagePNG: png, pinned: true), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: pin.id, imagePNG: png, scanned: true, ocrText: nil))
    flagByRecopy(store, pin)  // before any write
    store.flush()
    #expect(store.flaggedPinsKeptOnDisk.isEmpty)  // the UI must not claim it is saved
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!fileText(url).contains(pin.id.uuidString))
  }

  /// Unchanged: an unpinned saved image that a later scan flags leaves the disk.
  @Test func unpinnedSavedImageStillLeavesDisk() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let png = makeImage(width: 40, height: 20, type: "public.png")
    let e = store.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: e.id, imagePNG: png, scanned: true, ocrText: nil))
    store.flush()
    #expect(exists(pngURL(e.id, next: url)))
    flagByRecopy(store, e)
    #expect(store.flaggedPinsKeptOnDisk.isEmpty)
    store.flush()
    #expect(!exists(pngURL(e.id, next: url)))
  }
}

/// R-L4: a legacy pinned image stored inline in the JSON, whose vault item exists but cannot be read.
@Suite struct LegacyInlineUnreadablePinTests {
  @Test func isKeptMovedToImagesAndItsVaultItemSurvives() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let png = makeImage(width: 40, height: 20, type: "public.png")
    let legacy = ClipboardEntry(kind: .image, imagePNG: png, pinned: true, ocrText: "API_KEY=sk-••••")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([legacy]).write(to: url)
    let vault = UnreadableVault(listing: [legacy.id])

    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
    store.flush()  // after the vault restore, which is queued first
    let entry = try #require(store.entries(matching: "").first { $0.id == legacy.id })
    #expect(!entry.findings.isEmpty)               // sensitive in memory
    #expect(exists(pngURL(legacy.id, next: url)))  // moved out of the JSON, not dropped
    let json = fileText(url)
    #expect(json.contains(legacy.id.uuidString))
    #expect(!json.contains("imagePNG"))
    #expect(vault.removed.isEmpty)

    // Next launch: still there, loaded from images/, still sensitive, vault item still not an orphan.
    let reopened = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
    reopened.flush()
    let again = try #require(reopened.entries(matching: "").first { $0.id == legacy.id })
    #expect(again.imagePNG == png)
    #expect(!again.findings.isEmpty)
    #expect(vault.removed.isEmpty)
  }
}

/// (a) The debounced save is a cancellable work item, not a fire-and-forget `asyncAfter`.
@Suite struct HistoryStoreSaveTimerTests {
  @Test func flushCancelsThePendingSave() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = HistoryStore(fileURL: url, saveDelay: 600, purgeInterval: nil, vault: InMemoryVault())
    store.flush()
    _ = store.add(ClipboardEntry(kind: .text, text: "hello"))
    let work = try #require(store.scheduledSave)
    #expect(!work.isCancelled)
    store.flush()
    #expect(work.isCancelled)
    #expect(store.scheduledSave == nil)
    #expect(fileText(url).contains("hello"))
  }

  @Test func deinitCancelsThePendingSaveAndStillWrites() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var store: HistoryStore? = HistoryStore(fileURL: url, saveDelay: 600, purgeInterval: nil, vault: InMemoryVault())
    store?.flush()
    _ = store?.add(ClipboardEntry(kind: .text, text: "kept"))
    let work = try #require(store?.scheduledSave)
    store = nil
    #expect(work.isCancelled)
    #expect(fileText(url).contains("kept"))
  }
}
