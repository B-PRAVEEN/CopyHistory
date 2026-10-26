import Foundation
import Testing
@testable import CopyHistoryCore

private let ocrSecret = "sk-proj-OCRFAKEOCRFAKEOCRFAKE1234"
private let pngA = makeImage(width: 3, height: 2, type: "public.png")
private let pngB = makeImage(width: 2, height: 3, type: "public.png")

private extension FakePasteboard {
  func copyImage(_ png: Data) { text = nil; image = .png(png); self.png = nil; types = ["public.png"]; changeCount += 1 }
}

@MainActor @Suite struct ClipboardMonitorOCRTests {
  final class Log {
    var entries: [(ClipboardEntry, Bool)] = []
    var updates: [OCRUpdate] = []
    var events: [String] = []
  }

  func make(_ pb: FakePasteboard, ocr: (any OCRRecognizing)?, detector: SecretDetecting = SecretDetector(),
            expiry: TimeInterval = 60) -> (ClipboardMonitor, Log) {
    let m = ClipboardMonitor(pasteboard: pb, detector: detector, secretExpiry: expiry,
                             now: { Date(timeIntervalSince1970: 1000) })
    m.ocr = ocr
    let log = Log()
    m.onCapture = { e, awaiting in log.entries.append((e, awaiting)); log.events.append("entry:\(e.kind)") }
    m.onOCR = { log.updates.append($0); log.events.append("ocr") }
    return (m, log)
  }

  @Test func imageIsDeliveredAtOnceAndTextFollows() async throws {
    let pb = FakePasteboard()
    let ocr = FakeOCR([pngA: "Quarterly report"], delay: 2)
    let (m, log) = make(pb, ocr: ocr)
    pb.copyImage(pngA); m.poll()
    pb.copy("typed after the screenshot"); m.poll()
    // Both entries arrive long before OCR finishes: OCR never holds up later copies.
    let deadline = Date().addingTimeInterval(1.5)
    while log.entries.count < 2 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(log.entries.count == 2)
    #expect(log.updates.isEmpty)
    await m.waitUntilIdle()
    #expect(log.events == ["entry:image", "entry:text", "ocr"])
    let (image, awaiting) = try #require(log.entries.first)
    #expect(awaiting && image.ocrText == nil)
    #expect(!log.entries[1].1)
    let update = try #require(log.updates.first)
    #expect(update.entryID == image.id && update.imagePNG == pngA)
    #expect(update.ocrText == "Quarterly report" && update.scanned)
    #expect(update.findings.isEmpty && update.expiresAt == nil)
    #expect(ocr.calledOnMain == [false])
  }

  @Test func recognisedSecretIsFlaggedOffTheMainThread() async throws {
    let pb = FakePasteboard()
    let spy = SpyDetector(delay: 0)
    let (m, log) = make(pb, ocr: FakeOCR(fallback: "API key\n\(ocrSecret)"), detector: spy, expiry: 45)
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    let update = try #require(log.updates.first)
    #expect(!update.findings.isEmpty)
    #expect(update.expiresAt == Date(timeIntervalSince1970: 1045))
    #expect(spy.scannedOnMain == [false])
  }

  @Test func noExpiryWhenAutoExpireIsOff() async throws {
    let pb = FakePasteboard()
    let (m, log) = make(pb, ocr: FakeOCR(fallback: ocrSecret), expiry: 0)
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    let update = try #require(log.updates.first)
    #expect(!update.findings.isEmpty && update.expiresAt == nil)
  }

  @Test func oversizedTextIsCut() async throws {
    let pb = FakePasteboard()
    let (m, log) = make(pb, ocr: FakeOCR(fallback: String(repeating: "word ", count: 10_000)))
    m.maxOCRTextLength = 100
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    #expect(log.updates.first?.ocrText?.count == 100)
  }

  @Test func hungRecogniserStillProducesAnUpdate() async throws {
    let pb = FakePasteboard()
    let (m, log) = make(pb, ocr: FakeOCR(hang: true))
    m.ocrTimeBudget = 0.2
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    #expect(log.updates.count == 1)
    #expect(log.updates.first?.ocrText == nil)
    #expect(log.updates.first?.scanned == false)
  }

  @Test func onlyACompletedScanCountsAsScanned() async throws {
    for (ocr, scanned) in [(FakeOCR() as any OCRRecognizing, false),  // plain nil: maybe skipped
                           (FakeScanner(result: .failed), false),
                           (FakeScanner(result: .noText), true),
                           (FakeScanner(result: .text("hello")), true)] {
      let pb = FakePasteboard()
      let (m, log) = make(pb, ocr: ocr)
      pb.copyImage(pngA); m.poll()
      await m.waitUntilIdle()
      #expect(log.updates.map(\.scanned) == [scanned])
    }
  }

  @Test func backlogIsBounded() async throws {
    let pb = FakePasteboard()
    let (m, log) = make(pb, ocr: FakeOCR(fallback: "x", delay: 1))
    m.maxOCRBacklog = 1
    // One running, one queued; the third finds the backlog full and gets no OCR.
    for i in 0..<3 { pb.copyImage(makeImage(width: 2 + i, height: 2, type: "public.png")); m.poll() }
    await m.waitUntilIdle()
    #expect(log.entries.map(\.1) == [true, true, false])
    #expect(log.updates.count == 2 && log.updates.allSatisfy(\.scanned))
    #expect(Set(log.updates.map(\.entryID)) == Set(log.entries.prefix(2).map(\.0.id)))
  }

  @Test func noOCRWithoutARecogniser() async {
    let pb = FakePasteboard()
    let (m, log) = make(pb, ocr: nil)
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    #expect(log.entries.map(\.1) == [false])
    #expect(log.updates.isEmpty)
  }

  @Test func onEntryStillFires() async {
    let pb = FakePasteboard()
    let (m, _) = make(pb, ocr: FakeOCR(fallback: "x"))
    var got: [ClipboardEntry] = []
    m.onEntry = { got.append($0) }
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    #expect(got.count == 1)
  }

  /// With default settings: a key at or past the stored-text cut must still flag the image.
  @Test(arguments: [12_000, ClipboardMonitor.defaultMaxOCRTextLength - 10])
  func secretBeyondTheStoredTextIsStillFound(at offset: Int) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CHTest-\(UUID())/history.json")
    let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, vault: InMemoryVault())
    let pb = FakePasteboard()
    let m = ClipboardMonitor(pasteboard: pb, now: Date.init)
    let filler = String(repeating: "lorem ipsum ", count: offset / 12 + 1).prefix(offset - 1)
    m.ocr = FakeOCR(fallback: filler + " " + ocrSecret)
    m.connect(to: store)
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    store.flush()
    let e = try #require(store.entries(matching: "").first)
    #expect(!e.findings.isEmpty)
    #expect((e.ocrText?.count ?? 0) <= ClipboardMonitor.defaultMaxOCRTextLength)
    let bytes = HistoryStoreOCRTests.allBytes(under: dir)
    #expect(!bytes.contains(pngA))
    #expect(!bytes.contains { String(decoding: $0, as: UTF8.self).contains("OCRFAKE") })
  }

  @Test func connectedStoreGetsFlaggedImage() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CHTest-\(UUID())/history.json")
    let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, vault: InMemoryVault())
    let pb = FakePasteboard()
    let m = ClipboardMonitor(pasteboard: pb, now: Date.init)
    m.ocr = FakeOCR([pngA: "Q3 notes", pngB: "key \(ocrSecret)"], delay: 0.1)
    m.connect(to: store)
    pb.copyImage(pngA); m.poll()
    pb.copyImage(pngB); m.poll()
    await m.waitUntilIdle()
    store.flush()
    let all = store.entries(matching: "")
    #expect(all.count == 2)
    let flagged = try #require(all.first { $0.imagePNG == pngB })
    #expect(!flagged.findings.isEmpty && flagged.expiresAt != nil && flagged.ocrText?.contains(ocrSecret) == true)
    #expect(store.entries(matching: "q3 nts").map(\.imagePNG) == [pngA])
    let bytes = HistoryStoreOCRTests.allBytes(under: dir)
    #expect(!bytes.contains { String(decoding: $0, as: UTF8.self).contains("OCRFAKE") })
    #expect(!bytes.contains(pngB))
    #expect(bytes.contains(pngA))
  }

  func connectedStore() -> (HistoryStore, ClipboardMonitor, FakePasteboard, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CHTest-\(UUID())/history.json")
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, vault: InMemoryVault())
    let pb = FakePasteboard()
    let m = ClipboardMonitor(pasteboard: pb, now: Date.init)
    m.connect(to: store)
    return (store, m, pb, url.deletingLastPathComponent())
  }

  /// Phase 2 review M1 (E2): an image beyond the OCR backlog was written to disk unscanned.
  @Test func imageSkippedByTheBacklogNeverReachesDisk() async throws {
    let (store, m, pb, dir) = connectedStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    m.ocr = FakeOCR(fallback: "nothing secret", delay: 0.3)
    m.maxOCRBacklog = 1
    let pngs = (0..<3).map { makeImage(width: 4 + $0, height: 4, type: "public.png") }
    for png in pngs { pb.copyImage(png); m.poll() }
    // Before any scan finished: nothing on disk.
    try await Task.sleep(nanoseconds: 100_000_000)
    store.flush()
    #expect(!HistoryStoreOCRTests.allBytes(under: dir).contains { pngs.contains($0) })
    await m.waitUntilIdle()
    store.flush()
    let bytes = HistoryStoreOCRTests.allBytes(under: dir)
    #expect(bytes.contains(pngs[0]) && bytes.contains(pngs[1]))  // scanned clean
    #expect(!bytes.contains(pngs[2]))  // never scanned: memory only
    let skipped = try #require(store.entries(matching: "").first { $0.imagePNG == pngs[2] })
    #expect(store.isUnscannedImage(skipped.id))  // still listed this session
  }

  /// Phase 2 review M1: a timed-out (or failed) scan released the hold and persisted the PNG.
  @Test func imageWhoseScanTimesOutOrFailsNeverReachesDisk() async throws {
    for ocr in [FakeOCR(hang: true) as any OCRRecognizing, FakeScanner(result: .failed), FakeOCR()] {
      let (store, m, pb, dir) = connectedStore()
      defer { try? FileManager.default.removeItem(at: dir) }
      m.ocr = ocr
      m.ocrTimeBudget = 0.2
      pb.copyImage(pngA); m.poll()
      await m.waitUntilIdle()
      store.flush()
      #expect(!HistoryStoreOCRTests.allBytes(under: dir).contains(pngA))
      #expect(store.entries(matching: "").first?.imagePNG == pngA)
    }
  }

  /// The plan's acceptance criterion end to end with real Vision (Phase 2 review E1): a 6K
  /// screenshot of a fake key is flagged and never reaches disk.
  @Test func sixKScreenshotOfAKeyIsFlaggedAndNeverOnDisk() async throws {
    let (store, m, pb, dir) = connectedStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    m.ocr = VisionOCR()
    let png = try #require(makeTextCanvas(width: 6016, height: 3384, lines: [(VisionOCRTests.fakeKeyLine, 3000)],
                                          fontSize: 40))
    pb.copyImage(png); m.poll()
    await m.waitUntilIdle()
    store.flush()
    let e = try #require(store.entries(matching: "").first)
    #expect(!e.findings.isEmpty)
    let bytes = HistoryStoreOCRTests.allBytes(under: dir)
    #expect(!bytes.contains(png))
    #expect(!bytes.contains { String(decoding: $0, as: UTF8.self).contains("abcdefghjk") })
  }

  @Test func imageScannedWithNoTextIsPersisted() async throws {
    let (store, m, pb, dir) = connectedStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    m.ocr = FakeScanner(result: .noText)
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    store.flush()
    #expect(HistoryStoreOCRTests.allBytes(under: dir).contains(pngA))
    #expect(!store.isUnscannedImage(try #require(store.entries(matching: "").first).id))
  }

  @Test func imageCopiedWithOCROffStaysInMemory() async throws {
    let (store, m, pb, dir) = connectedStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    pb.copyImage(pngA); m.poll()
    await m.waitUntilIdle()
    store.flush()
    #expect(!HistoryStoreOCRTests.allBytes(under: dir).contains(pngA))
    #expect(store.entries(matching: "").count == 1)
  }
}

@Suite struct HistoryStoreOCRTests {
  func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CHTest-\(UUID())/history.json")
  }

  static func allBytes(under dir: URL) -> [Data] {
    let fm = FileManager.default
    guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
    return e.compactMap { ($0 as? URL).flatMap { try? Data(contentsOf: $0) } }
  }

  func imageFiles(_ dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("images").path)) ?? []
  }

  func image(_ png: Data, at t: TimeInterval = 0) -> ClipboardEntry {
    ClipboardEntry(kind: .image, imagePNG: png, now: Date(timeIntervalSince1970: t))
  }

  func update(_ e: ClipboardEntry, _ text: String?, expiresAt: Date? = nil, scanned: Bool = true) -> OCRUpdate {
    OCRUpdate(entryID: e.id, imagePNG: e.imagePNG ?? Data(), scanned: scanned, ocrText: text,
              findings: text.map { SecretDetector().scan($0) } ?? [], expiresAt: expiresAt)
  }

  func jsonString(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

  @Test func searchMatchesOCRTextFuzzily() {
    let store = HistoryStore(fileURL: nil)
    let a = store.add(image(pngA), awaitingOCR: true)
    _ = store.add(image(pngB))
    _ = store.add(ClipboardEntry(kind: .text, text: "Weekly Notes"))
    store.applyOCR(update(a, "Invoice 4271 due Friday"))
    #expect(store.entries(matching: "inv 4271").map(\.id) == [a.id])
    #expect(store.entries(matching: "notes").map(\.kind) == [.text])
    #expect(store.entries(matching: "").count == 3)
  }

  @Test func searchDoesNotProbeHiddenCharactersOfAFlaggedImage() {
    let store = HistoryStore(fileURL: nil)
    let a = store.add(image(pngA), awaitingOCR: true)
    store.applyOCR(update(a, "key \(ocrSecret)", expiresAt: Date().addingTimeInterval(60)))
    #expect(store.entries(matching: "OCRFAKE").isEmpty)
    #expect(store.entries(matching: "key").map(\.id) == [a.id])
  }

  @Test func applyOCRRules() throws {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let exp = Date(timeIntervalSince1970: 500)
    // Gone entries are not resurrected and nothing is bumped.
    let gone = store.add(image(pngB)); store.remove(gone.id)
    store.applyOCR(update(gone, "late"))
    #expect(store.entries(matching: "").isEmpty)

    let a = store.add(image(pngA, at: 10), awaitingOCR: true)
    store.applyOCR(update(a, "key \(ocrSecret)", expiresAt: exp))
    var e = try #require(store.entries(matching: "").first)
    #expect(!e.findings.isEmpty && e.expiresAt == exp && e.copyCount == 1)
    #expect(e.lastCopiedAt == Date(timeIntervalSince1970: 10))
    // Never unflagged or overwritten by a later, clean result.
    store.applyOCR(update(a, "something else"))
    store.applyOCR(update(a, nil))
    e = try #require(store.entries(matching: "").first)
    #expect(e.ocrText == "key \(ocrSecret)" && !e.findings.isEmpty)
  }

  @Test func recopyingAFlaggedImageExtendsItsExpiry() throws {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let a = store.add(image(pngA, at: 1), awaitingOCR: true)
    store.applyOCR(update(a, ocrSecret, expiresAt: Date(timeIntervalSince1970: 61)))
    let copy = image(pngA, at: 30)
    _ = store.add(copy, awaitingOCR: true)
    store.applyOCR(update(copy, ocrSecret, expiresAt: Date(timeIntervalSince1970: 90)))
    let e = try #require(store.entries(matching: "").first)
    #expect(e.expiresAt == Date(timeIntervalSince1970: 90) && e.copyCount == 2)
  }

  @Test func pinnedImageGetsNoExpiry() throws {
    let store = HistoryStore(fileURL: nil, purgeInterval: nil)
    let a = store.add(image(pngA), awaitingOCR: true)
    store.togglePin(a.id)
    store.applyOCR(update(a, ocrSecret, expiresAt: Date(timeIntervalSince1970: 1)))
    let e = try #require(store.entries(matching: "").first)
    #expect(!e.findings.isEmpty && e.expiresAt == nil)
  }

  @Test func updateForAFoldedCopyFindsTheOlderEntry() throws {
    let store = HistoryStore(fileURL: nil)
    let old = store.add(image(pngA, at: 1))
    let copy = image(pngA, at: 2)
    let stored = store.add(copy, awaitingOCR: true)
    #expect(stored.id == old.id && stored.copyCount == 2)
    store.applyOCR(update(copy, "hello"))  // the monitor only knows the copy's id
    let e = try #require(store.entries(matching: "").first)
    #expect(e.id == old.id && e.ocrText == "hello" && e.copyCount == 2)
  }

  @Test func imageStaysOffDiskUntilItsTextWasScanned() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil)
    let a = store.add(image(pngA), awaitingOCR: true)
    _ = store.add(ClipboardEntry(kind: .text, text: "plain"))
    store.flush()
    #expect(imageFiles(dir).isEmpty)
    #expect(!jsonString(url).contains(a.id.uuidString))
    store.applyOCR(update(a, "Quarterly report"))
    store.flush()
    #expect(imageFiles(dir) == ["\(a.id.uuidString).png"])
    #expect(jsonString(url).contains("Quarterly report"))
    // Relaunch: text is searchable again.
    let reloaded = HistoryStore(fileURL: url, purgeInterval: nil)
    #expect(reloaded.entries(matching: "quarterly").map(\.id) == [a.id])
    #expect(reloaded.entries(matching: "quarterly").first?.imagePNG == pngA)
  }

  @Test func flaggedImageNeverReachesDisk() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil)
    let a = store.add(image(pngA), awaitingOCR: true)
    store.applyOCR(update(a, "key \(ocrSecret)", expiresAt: Date().addingTimeInterval(60)))
    store.flush()
    #expect(imageFiles(dir).isEmpty)
    let bytes = Self.allBytes(under: dir)
    #expect(!bytes.contains { String(decoding: $0, as: UTF8.self).contains("OCRFAKE") })
    #expect(!bytes.contains(pngA))
    #expect(!jsonString(url).contains(a.id.uuidString))
    // Still in memory, pasteable during the expiry window.
    #expect(store.entries(matching: "").first?.imagePNG == pngA)
    #expect(HistoryStore(fileURL: url, purgeInterval: nil).entries(matching: "").isEmpty)
  }

  @Test func imageWrittenBeforeItWasFlaggedIsDeleted() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil)
    let a = store.add(image(pngA), awaitingOCR: true)
    store.applyOCR(update(a, nil))  // scanned, no text
    store.flush()
    #expect(imageFiles(dir).count == 1)
    // A later copy of the same bytes is read differently and shows a key: flagged, off disk.
    let copy = image(pngA, at: 5)
    _ = store.add(copy, awaitingOCR: true)
    store.applyOCR(update(copy, ocrSecret, expiresAt: Date().addingTimeInterval(60)))
    store.flush()
    #expect(imageFiles(dir).isEmpty)
    #expect(!jsonString(url).contains(a.id.uuidString))
    #expect(store.entries(matching: "").first?.findings.isEmpty == false)
  }

  @Test func failedScanNeverLetsAnImageReachDisk() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil)
    let a = store.add(image(pngA), awaitingOCR: true)
    #expect(store.isUnscannedImage(a.id))
    store.applyOCR(update(a, nil, scanned: false))
    store.togglePin(a.id)  // not even a pin persists an unchecked image
    store.flush()
    #expect(imageFiles(dir).isEmpty)
    #expect(!jsonString(url).contains(a.id.uuidString))
    #expect(store.isUnscannedImage(a.id))
    #expect(store.entries(matching: "").first?.imagePNG == pngA)
    // A later successful scan of the same bytes lets it through.
    store.applyOCR(update(image(pngA), "Quarterly report"))
    store.flush()
    #expect(imageFiles(dir) == ["\(a.id.uuidString).png"])
    #expect(!store.isUnscannedImage(a.id))
  }

  /// Known issue from the Phase 2 review: a pinned flagged image left its PNG on disk unencrypted.
  @Test func pinnedFlaggedImageIsMemoryOnly() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = InMemoryVault()
    let text = "staging key: \(ocrSecret)"
    let s1 = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, vault: vault)
    let a = s1.add(image(pngA), awaitingOCR: true)
    s1.applyOCR(update(a, text, expiresAt: Date().addingTimeInterval(60)))
    s1.togglePin(a.id)
    _ = s1.add(ClipboardEntry(kind: .text, text: "plain"))
    s1.flush()
    #expect(imageFiles(dir).isEmpty)
    #expect(!Self.allBytes(under: dir).contains(pngA))
    #expect(!jsonString(url).contains(a.id.uuidString))
    #expect(vault.ids()?.isEmpty == true)
    // Kept, pinned and flagged for this session.
    let e = try #require(s1.entries(matching: "").first)
    #expect(e.id == a.id && e.pinned && e.imagePNG == pngA && e.ocrText == text && !e.findings.isEmpty)
    #expect(PastePolicy.sensitivity(of: e) == true)
    // Gone after a relaunch, by design.
    let s2 = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
    s2.flush()
    #expect(s2.entries(matching: "").map(\.text) == ["plain"])
  }

  /// Writes a pinned image record as the pre-fix code did: masked `ocrText` in the JSON, PNG in `images/`.
  func legacyPinnedImage(at url: URL, ocrText: String) throws -> UUID {
    let id = UUID()
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
    try pngA.write(to: dir.appendingPathComponent("images/\(id.uuidString).png"))
    let json = """
    [{"id":"\(id.uuidString)","kind":"image","pinned":true,"copyCount":1,"ocrText":"\(ocrText)",
      "firstCopiedAt":"2026-01-01T00:00:00Z","lastCopiedAt":"2026-01-01T00:00:00Z","findings":[]}]
    """
    try Data(json.utf8).write(to: url)
    return id
  }

  /// Review F2-L5: like a saved pin a later scan flagged, a legacy flagged image pin keeps its files
  /// until unpinned (its OCR text only masked on disk); see `LegacyVaultImagePinTests`.
  @Test func legacyPinnedFlaggedImageIsKeptOnDiskOnceConfirmed() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = try legacyPinnedImage(at: url, ocrText: "staging key: sk-proj-••••••••")
    let vault = InMemoryVault()
    _ = vault.store("staging key: \(ocrSecret)", for: id)
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, vault: vault)
    store.flush(); store.flush()  // restore, then the write it scheduled
    let e = try #require(store.entries(matching: "").first)
    #expect(e.id == id && e.pinned && !e.findings.isEmpty && e.imagePNG == pngA)
    #expect(imageFiles(dir) == ["\(id.uuidString).png"])
    #expect(jsonString(url).contains(id.uuidString))
    #expect(!jsonString(url).contains(ocrSecret))
    #expect(store.flaggedPinsKeptOnDisk == [id])
  }

  /// Known issue from the Phase 2 review: a pinned image whose vault read failed pasted unmarked.
  @Test func pinnedImageWithUnreadableVaultItemIsSensitiveAndKept() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let masked = "staging key: sk-proj-••••••••"
    let id = try legacyPinnedImage(at: url, ocrText: masked)
    let vault = HistoryStoreTests.DeniedVault([id])
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, vault: vault)
    store.flush()
    let e = try #require(store.entries(matching: "").first)
    #expect(PastePolicy.sensitivity(of: e) == true)
    #expect(e.ocrText == masked && e.imagePNG == pngA)
    // Only a user action may destroy it: its files and vault item stay.
    _ = store.add(ClipboardEntry(kind: .text, text: "other")); store.flush()
    #expect(imageFiles(dir) == ["\(id.uuidString).png"])
    #expect(jsonString(url).contains(id.uuidString))
    #expect(vault.removed.isEmpty)
    let again = HistoryStore(fileURL: url, purgeInterval: nil, vault: vault)
    again.flush()
    #expect(again.entries(matching: "").first.map(PastePolicy.sensitivity(of:)) == true)
  }

  @Test func pinnedImagesAreLeftAloneWhenTheVaultCannotBeListed() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    final class UnlistableVault: SecretVault, @unchecked Sendable {
      func store(_ text: String, for id: UUID) -> Bool { false }
      func load(_ id: UUID) -> String? { nil }
      func remove(_ id: UUID) {}
      func ids() -> Set<UUID>? { nil }
    }
    let id = try legacyPinnedImage(at: url, ocrText: "Quarterly report")
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, vault: UnlistableVault())
    _ = store.add(ClipboardEntry(kind: .text, text: "other")); store.flush()
    #expect(imageFiles(dir) == ["\(id.uuidString).png"])
    #expect(store.entries(matching: "quarterly").map(\.id) == [id])
  }

  @Test func historyWithoutOCRTextStillLoads() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    let id = UUID()
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
    try pngA.write(to: dir.appendingPathComponent("images/\(id.uuidString).png"))
    // The pre-OCR format: no `ocrText` key at all.
    let json = """
    [{"id":"\(id.uuidString)","kind":"image","pinned":true,"copyCount":1,
      "firstCopiedAt":"2026-01-01T00:00:00Z","lastCopiedAt":"2026-01-01T00:00:00Z","findings":[]},
     {"id":"\(UUID().uuidString)","kind":"text","text":"old note","pinned":false,"copyCount":2,
      "firstCopiedAt":"2026-01-01T00:00:00Z","lastCopiedAt":"2026-01-01T00:00:01Z","findings":[]}]
    """
    try Data(json.utf8).write(to: url)
    let store = HistoryStore(fileURL: url, purgeInterval: nil, vault: InMemoryVault())
    let all = store.entries(matching: "")
    #expect(all.count == 2)
    #expect(store.recoveryBackupURL == nil)
    let img = try #require(all.first { $0.kind == .image })
    #expect(img.id == id && img.ocrText == nil && img.imagePNG == pngA)
  }

  /// Phase 2 review H1/M1: the hold used to run out and write the image unscanned.
  @Test func imageWithoutAScanIsNeverWrittenHoweverLongItWaits() throws {
    let url = tempURL(); let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }
    final class Clock: @unchecked Sendable { var t = Date() }
    let clock = Clock()
    let store = HistoryStore(fileURL: url, saveDelay: 0, purgeInterval: nil, now: { clock.t })
    let a = store.add(image(pngA), awaitingOCR: true)
    store.flush()
    #expect(imageFiles(dir).isEmpty)
    clock.t = clock.t.addingTimeInterval(3600)
    _ = store.add(ClipboardEntry(kind: .text, text: "next"))
    store.flush()
    #expect(imageFiles(dir).isEmpty)
    #expect(!jsonString(url).contains(a.id.uuidString))
    #expect(store.entries(matching: "").contains { $0.id == a.id })
  }
}
