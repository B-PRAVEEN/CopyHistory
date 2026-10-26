import Foundation
import Testing
@testable import CopyHistoryCore

// R-L3 follow-up: a saved pin that a later scan flagged stays flagged across a relaunch, through the
// `history.flagged-pins.json` side file. Temporary directories and in-memory vaults only: never the
// real Keychain or Application Support.

private let fakeKeyLine = "API_KEY=sk-proj-abcdefghjkmnpqrstuvwxyzABCDEFGH"  // fake fixture, not a real key
private let fakeKeyBody = "sk-proj-abcdefghjkmnpqrstuvwxyz"

private func tempURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("CHSideFileTest-\(UUID())/history.json")
}

private func sideURL(next url: URL) -> URL {
  url.deletingLastPathComponent().appendingPathComponent("history.flagged-pins.json")
}

private func pngURL(_ id: UUID, next url: URL) -> URL {
  url.deletingLastPathComponent().appendingPathComponent("images/\(id.uuidString).png")
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func fileText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

private func permissions(_ url: URL) -> Int? {
  (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

/// The side file's ids, or nil when it is missing or not a list of UUID strings.
private func listedIDs(next url: URL) -> Set<UUID>? {
  guard let data = try? Data(contentsOf: sideURL(next: url)),
        let raw = try? JSONDecoder().decode([String].self, from: data) else { return nil }
  let ids = raw.compactMap(UUID.init(uuidString:))
  return ids.count == raw.count ? Set(ids) : nil
}

private func open(_ url: URL) -> HistoryStore {
  let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
  store.flush()  // after the launch-time vault restore and write
  return store
}

/// A pinned image saved clean ("Release notes"), then flagged by the OCR of a re-copy of its bytes.
private func savedPinFlaggedLater(url: URL) -> (HistoryStore, ClipboardEntry) {
  let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
  let png = makeImage(width: 40, height: 20, type: "public.png")
  let pin = store.add(ClipboardEntry(kind: .image, imagePNG: png, pinned: true), awaitingOCR: true)
  store.applyOCR(OCRUpdate(entryID: pin.id, imagePNG: png, scanned: true, ocrText: "Release notes"))
  store.flush()
  let findings = SecretDetector().scan(fakeKeyLine)
  store.applyOCR(OCRUpdate(entryID: UUID(), imagePNG: png, scanned: true, ocrText: fakeKeyLine, findings: findings))
  store.flush()
  return (store, pin)
}

/// A pinned image saved clean and never flagged.
private func savedCleanPin(url: URL) -> ClipboardEntry {
  let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
  let png = makeImage(width: 30, height: 30, type: "public.png")
  let pin = store.add(ClipboardEntry(kind: .image, imagePNG: png, pinned: true), awaitingOCR: true)
  store.applyOCR(OCRUpdate(entryID: pin.id, imagePNG: png, scanned: true, ocrText: "Release notes"))
  store.flush()
  return pin
}

/// Expects `id` to be loaded as a flagged pin whose files are kept.
private func expectFlaggedKeptPin(_ store: HistoryStore, _ id: UUID, url: URL) throws {
  let entry = try #require(store.entries(matching: "").first { $0.id == id })
  #expect(entry.pinned)
  #expect(!entry.findings.isEmpty)                                   // masked row
  #expect(PastePolicy.sensitivity(of: entry) == true)                // pasted concealed / transient
  #expect(!PopupPolicy.showsThumbnail(of: entry, unscanned: store.isUnscannedImage(id)))  // no raw thumbnail
  #expect(store.pasteState(of: id)?.unscanned == false)
  #expect(store.flaggedPinsKeptOnDisk.contains(id))                  // the ⚠︎ note is still shown
  #expect(exists(pngURL(id, next: url)))
  #expect(fileText(url).contains(id.uuidString))
}

@Suite struct FlaggedPinSideFileTests {
  @Test func relaunchLoadsTheKeptPinFlagged() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (_, pin) = savedPinFlaggedLater(url: url)
    #expect(listedIDs(next: url) == [pin.id])

    // No mutation in between: the state comes from the files alone.
    let reopened = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    try expectFlaggedKeptPin(reopened, pin.id, url: url)
    reopened.flush()
    try expectFlaggedKeptPin(reopened, pin.id, url: url)
    let entry = try #require(reopened.entries(matching: "").first { $0.id == pin.id })
    #expect(entry.imagePNG == pin.imagePNG)
    #expect(!(entry.ocrText ?? "").contains(fakeKeyBody))
    #expect(reopened.entries(matching: "sk-proj-abc").isEmpty)  // search cannot probe it either
    #expect(listedIDs(next: url) == [pin.id])

    // And again on the launch after that.
    try expectFlaggedKeptPin(open(url), pin.id, url: url)
  }

  @Test func unpinAfterRelaunchRemovesItsFilesAndItsID() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (_, pin) = savedPinFlaggedLater(url: url)
    let reopened = open(url)
    reopened.togglePin(pin.id)
    #expect(reopened.flaggedPinsKeptOnDisk.isEmpty)
    reopened.flush()
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!fileText(url).contains(pin.id.uuidString))
    #expect(!exists(sideURL(next: url)))  // the last id gone, so is the file

    let again = open(url)
    #expect(!again.entries(matching: "").contains { $0.id == pin.id && $0.pinned })
  }

  @Test func deleteRemovesItsFilesAndItsID() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, pin) = savedPinFlaggedLater(url: url)
    store.remove(pin.id)
    store.flush()
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!fileText(url).contains(pin.id.uuidString))
    #expect(!exists(sideURL(next: url)))
    #expect(open(url).entries(matching: "").isEmpty)
  }

  /// Only the unpinned id leaves the list; another kept pin stays listed and flagged.
  @Test func unpinningOneKeepsTheOthersListed() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (store, first) = savedPinFlaggedLater(url: url)
    let png = makeImage(width: 50, height: 10, type: "public.png")
    let second = store.add(ClipboardEntry(kind: .image, imagePNG: png, pinned: true), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: second.id, imagePNG: png, scanned: true, ocrText: "Notes"))
    store.flush()
    store.applyOCR(OCRUpdate(entryID: second.id, imagePNG: png, scanned: true, ocrText: fakeKeyLine,
                             findings: SecretDetector().scan(fakeKeyLine)))
    store.flush()
    #expect(listedIDs(next: url) == [first.id, second.id])
    store.togglePin(first.id)
    store.flush()
    #expect(listedIDs(next: url) == [second.id])
    let reopened = open(url)
    try expectFlaggedKeptPin(reopened, second.id, url: url)
    #expect(!reopened.entries(matching: "").contains { $0.id == first.id })
  }

  @Test func neitherFileHoldsPlaintextAndTheSideFileHoldsOnlyIDs() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let (_, pin) = savedPinFlaggedLater(url: url)
    let reopened = open(url)
    _ = reopened.add(ClipboardEntry(kind: .text, text: "touch"))  // force another write after the relaunch
    reopened.flush()
    let json = fileText(url)
    #expect(!json.contains(fakeKeyBody))
    #expect(!json.contains("\"findings\":[{"))  // findings never reach disk
    let side = fileText(sideURL(next: url))
    #expect(!side.contains(fakeKeyBody))
    #expect(!side.contains("API_KEY"))
    #expect(!side.contains("Release"))
    let raw = try JSONDecoder().decode([String].self, from: Data(contentsOf: sideURL(next: url)))
    #expect(raw == [pin.id.uuidString])
  }

  @Test func sideFileIsPrivate() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = savedPinFlaggedLater(url: url)
    #expect(permissions(sideURL(next: url)) == 0o600)
    #expect(permissions(url.deletingLastPathComponent()) == 0o700)
    // No temporary files left behind by the atomic write.
    let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    #expect(!names.contains { $0.hasSuffix(".tmp") })
  }

  /// A clean pin is never listed, and ids that match no pinned image are ignored and dropped.
  @Test func cleanPinsAreNotListedAndStaleIDsAreIgnored() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let pin = savedCleanPin(url: url)
    #expect(!exists(sideURL(next: url)))
    try JSONEncoder().encode([UUID().uuidString]).write(to: sideURL(next: url))

    let reopened = open(url)
    let entry = try #require(reopened.entries(matching: "").first { $0.id == pin.id })
    #expect(entry.findings.isEmpty)
    #expect(reopened.flaggedPinsKeptOnDisk.isEmpty)
    _ = reopened.add(ClipboardEntry(kind: .text, text: "touch"))
    reopened.flush()
    #expect(!exists(sideURL(next: url)))
  }

  /// A read-only store (unreadable history file) never writes or removes the side file.
  @Test func readOnlyStoreLeavesTheSideFileAlone() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = savedPinFlaggedLater(url: url)
    let before = try Data(contentsOf: sideURL(next: url))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    _ = store.add(ClipboardEntry(kind: .text, text: "copied this session"))
    store.flush()
    #expect(store.isReadOnly)
    #expect(try Data(contentsOf: sideURL(next: url)) == before)
  }

  @Test func readOnlyStoreDoesNotCreateTheSideFile() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    _ = savedCleanPin(url: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let png = makeImage(width: 12, height: 12, type: "public.png")
    let pin = store.add(ClipboardEntry(kind: .image, imagePNG: png, pinned: true), awaitingOCR: true)
    store.applyOCR(OCRUpdate(entryID: pin.id, imagePNG: png, scanned: true, ocrText: fakeKeyLine,
                             findings: SecretDetector().scan(fakeKeyLine)))
    store.flush()
    #expect(store.isReadOnly)
    #expect(!exists(sideURL(next: url)))
  }
}

/// A side file that exists but cannot be used fails closed: every pinned image loaded from disk is
/// treated as a kept flagged pin. Nothing crashes and nothing is lost.
@Suite struct FlaggedPinSideFileFailClosedTests {
  private func expectFailsClosed(corrupt: (URL) throws -> Void, restore: (URL) -> Void = { _ in }) throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let pin = savedCleanPin(url: url)
    // An unpinned clean image is not a pin: it stays clean.
    let seed = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let png = makeImage(width: 22, height: 22, type: "public.png")
    let loose = seed.add(ClipboardEntry(kind: .image, imagePNG: png), awaitingOCR: true)
    seed.applyOCR(OCRUpdate(entryID: loose.id, imagePNG: png, scanned: true, ocrText: nil))
    seed.flush()
    try corrupt(sideURL(next: url))

    let reopened = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    try expectFlaggedKeptPin(reopened, pin.id, url: url)
    let looseEntry = try #require(reopened.entries(matching: "").first { $0.id == loose.id })
    #expect(looseEntry.findings.isEmpty)
    restore(sideURL(next: url))
    reopened.flush()
    try expectFlaggedKeptPin(reopened, pin.id, url: url)
    #expect(exists(pngURL(loose.id, next: url)))

    // The next write replaces the bad file with a valid list, so the next launch agrees.
    _ = reopened.add(ClipboardEntry(kind: .text, text: "touch"))
    reopened.flush()
    #expect(listedIDs(next: url) == [pin.id])
    #expect(permissions(sideURL(next: url)) == 0o600)
    try expectFlaggedKeptPin(open(url), pin.id, url: url)

    // Unpinning is still what removes it.
    reopened.togglePin(pin.id)
    reopened.flush()
    #expect(!exists(pngURL(pin.id, next: url)))
    #expect(!exists(sideURL(next: url)))
  }

  @Test func garbageBytes() throws {
    try expectFailsClosed { try Data("not json {{{".utf8).write(to: $0) }
  }

  @Test func aStringThatIsNotAnID() throws {
    try expectFailsClosed { try JSONEncoder().encode([UUID().uuidString, "oops"]).write(to: $0) }
  }

  @Test func wrongJSONShape() throws {
    try expectFailsClosed { try Data("{\"ids\":[]}".utf8).write(to: $0) }
  }

  @Test func unreadableFile() throws {
    try expectFailsClosed(corrupt: { url in
      try Data("[]".utf8).write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }, restore: { url in
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    })
  }

  /// A legacy pinned image stored inline in the JSON is not lost when failing closed: it is kept,
  /// flagged, and its PNG moves to `images/`.
  @Test func legacyInlinePinIsKept() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let png = makeImage(width: 40, height: 20, type: "public.png")
    let legacy = ClipboardEntry(kind: .image, imagePNG: png, pinned: true, ocrText: "Release notes")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([legacy]).write(to: url)
    try Data("garbage".utf8).write(to: sideURL(next: url))

    let store = open(url)
    try expectFlaggedKeptPin(store, legacy.id, url: url)
    #expect(!fileText(url).contains("imagePNG"))
    #expect(listedIDs(next: url) == [legacy.id])

    let again = open(url)
    try expectFlaggedKeptPin(again, legacy.id, url: url)
    #expect(again.entries(matching: "").first { $0.id == legacy.id }?.imagePNG == png)
  }
}
