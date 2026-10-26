import Foundation

/// Thread-safe clipboard history with debounced, incremental persistence.
///
/// Secrets at rest (the safest design that still lets a flagged item be pasted while it is live):
/// - Entries with `findings` keep their plaintext **in memory only**, so the user can paste them
///   during the expiry window. Unpinned flagged entries are never written to disk at all.
/// - A pinned flagged entry is written to `history.json` only as a masked placeholder
///   (`detector.mask`, findings and expiry cleared); its plaintext goes to the `SecretVault`
///   (the login Keychain for the app's real history file), and is restored from there on load.
///
/// False positives must never destroy data irreversibly. The detector is heuristic, so "flagged"
/// does not mean "secret": an unpinned flagged entry stays fully recoverable (paste or pin it)
/// for the whole expiry window, and is only dropped when that window, which the user chose,
/// runs out; pinning is the explicit "keep this" action, and a pin keeps its exact text across
/// relaunches via the vault. Only if the vault refuses a write (e.g. Keychain access denied) does
/// a pin fall back to its masked text, because plaintext on disk is never an option. Flagged
/// entries with no expiry ("never") are memory-only and gone after a relaunch unless pinned.
/// - Vault plaintext is restored on the store's background queue, never in `init`: a Keychain read
///   can block on an access prompt (one per item after the app is re-signed). Until it finishes
///   (`isRestoringVault`), vaulted pins are listed with their masked text, and
///   `didRestoreVaultNotification` is posted when they have their plaintext.
/// - Vault items are only ever treated as orphans (and deleted) after the history file was read and
///   fully decoded and the vault could be listed. A history file that exists but cannot be read
///   leaves the store read-only for the session (`isReadOnly`): the file and the vault are untouched.
/// - Expired entries are purged at load and by a store-owned timer, independent of the popup.
/// - `history.json` and image files are 0600 inside a 0700 directory. A legacy file that still
///   holds plaintext flagged entries is rewritten (scrubbed) right after load; its pins move to
///   the vault.
///
/// Image entries (OCR): an image's `ocrText` is searched like text, and `findings` on an image index
/// into its `ocrText`. One rule decides whether an image reaches disk: **only after a successful
/// scan found no secret** (`applyOCR` with `scanned` true and no findings), or when it was loaded
/// from disk. Every other image is memory-only: still listed and pasteable this session, gone after
/// a relaunch. That covers an image whose scan has not come back yet, one the OCR backlog skipped,
/// one whose scan timed out or failed, one added while OCR is off, and one copied just before
/// quitting. `isUnscannedImage(_:)` tells the UI which images were never checked.
///
/// Flagged images are memory-only **even when pinned** (chosen over a binary vault: the Keychain is
/// not made for multi-megabyte blobs, and a separate encrypted image store would add key management
/// and access prompts for little gain). Pinning a flagged image keeps it for the session only; its
/// PNG is never written, encrypted or not, and its `ocrText` never goes to the vault. A pinned
/// flagged image left on disk by an older version is removed from disk (record and PNG) as soon as
/// the vault restore confirms it is flagged, and is gone after the next relaunch. The one exception
/// is a legacy pinned image whose vault item exists but cannot be read (e.g. Keychain access
/// denied): it is treated as sensitive (an empty-range finding, so it pastes Concealed and is
/// masked) but its files are kept (a legacy inline PNG is moved to `images/`), because only a user
/// action may destroy a pin whose vault item is unreadable. When the vault cannot even be listed,
/// nobody can tell which pins were flagged, so they are left alone. Likewise a pinned image already
/// on disk that a later scan flags (e.g. a re-copy whose OCR now reads a "secret") is flagged in
/// memory, but its files stay until the user unpins it (`flaggedPinsKeptOnDisk`); the new OCR text
/// is written masked. Its id (and nothing else) is listed in `history.flagged-pins.json`, so after a
/// relaunch it loads flagged again (an empty-range finding, like the unreadable-vault case). A side
/// file that exists but cannot be read or decoded fails closed: every pinned image loaded from disk
/// is then treated as such a pin, flagged with its files kept.
///
/// Persistence: mutations only mark the store dirty when something actually changed; writes are
/// coalesced on a background queue, and are skipped when the encoded bytes are unchanged. Images
/// live in `images/<id>.png`, written once, so they are never re-encoded into the JSON.
///
/// Corrupt files: records are decoded one by one and bad ones skipped; whenever anything could not
/// be decoded, the original file is copied to `history.corrupt-<timestamp>.json` before it is ever
/// overwritten, so pinned items in it are recoverable (see `recoveryBackupURL`). Vault items no
/// decoded record claims are recorded next to the backup (`history.retained-vault.json`) and kept
/// until that backup is deleted, also across later launches. Backups never hold
/// plaintext secrets: every string in them is scanned and detected secrets are masked first (also
/// for backups left by older versions). They are 0600, excluded from Time Machine, deleted after
/// `backupRetention`, and at most `maxBackups` are kept.
public final class HistoryStore: ClipboardHistoryStore, @unchecked Sendable {
  public static let defaultUnpinnedCap = 200
  public static let defaultSaveDelay: TimeInterval = 0.5
  public static let defaultPurgeInterval: TimeInterval = 2
  public static let backupRetention: TimeInterval = 30 * 24 * 3600
  public static let maxBackups = 5

  private let lock = NSLock()
  private let fileURL: URL?
  private let unpinnedCap: Int
  private let detector: SecretDetecting
  private let now: @Sendable () -> Date
  private let saveDelay: TimeInterval
  private let vault: SecretVault?
  private var items: [ClipboardEntry] = []

  // Guarded by `lock`.
  /// Image entries that may be written to disk: scanned with no secret found, or loaded from disk.
  private var scannedImages: Set<UUID> = []
  /// Pinned images that were cleared for disk and later flagged by a scan: their files are kept.
  private var keptFlaggedPins: Set<UUID> = []
  /// Those of `keptFlaggedPins` whose record and PNG are on disk: loaded flagged at launch, then
  /// as the last write kept them.
  private var keptFlaggedPinsOnDisk: Set<UUID> = []
  private var generation = 0
  private var saveScheduled = false
  /// The debounced save, cancelled when a write makes it redundant and on deinit.
  private var saveWork: DispatchWorkItem?

  // Only touched on `ioQueue`.
  private var writtenGeneration = 0
  private var lastWrittenJSON: Data?
  private var writtenImageIDs: Set<UUID> = []
  /// Every image loaded from disk (in `images/` or inline in a legacy file). Set in `init`.
  private var loadedImageIDs: Set<UUID> = []
  /// The ids `history.flagged-pins.json` holds; nil when it is unreadable and must be rewritten.
  private var writtenFlaggedPins: Set<UUID>? = []
  private var vaultedIDs: Set<UUID> = []
  /// Vault items that only a user action may delete: pins whose vault read failed at load (e.g.
  /// Keychain access denied after a re-sign). Set by `restoreVault`, then read on `ioQueue`.
  private var unreadableVaultIDs: Set<UUID> = []
  /// Vault items no decoded record claims while a recovery backup may still hold their pins.
  private var retainedVaultIDs: Set<UUID> = []
  /// False when the vault could not be listed: nothing is deleted from it this session.
  private var vaultRemovalsAllowed = true

  private let ioQueue = DispatchQueue(label: "CopyHistory.HistoryStore.io")
  private static let ioQueueKey = DispatchSpecificKey<Bool>()
  private var purgeTimer: DispatchSourceTimer?
  private var terminateObserver: NSObjectProtocol?

  /// Set when the history file could not be fully decoded; the original (secrets masked) was copied here.
  public var recoveryBackupURL: URL? { lock.lock(); defer { lock.unlock() }; return _recoveryBackupURL }
  private var _recoveryBackupURL: URL?  // guarded by `lock`
  /// Records were lost and the backup is not written yet (or failed), or the file could not be read
  /// at all: never overwrite the original, or its pins are gone. Set in `init`, then only touched on `ioQueue`.
  private var writesBlocked = false

  /// The history file exists but could not be read (permissions, I/O error): nothing is written to
  /// it or removed from the vault this session, and history is in memory only.
  public var isReadOnly: Bool { lock.lock(); defer { lock.unlock() }; return _isReadOnly }
  private var _isReadOnly = false  // guarded by `lock`
  /// True until the plaintext of vaulted pins has been read back (on a background queue).
  public var isRestoringVault: Bool { lock.lock(); defer { lock.unlock() }; return _isRestoringVault }
  private var _isRestoringVault = false  // guarded by `lock`
  /// Posted (on the store's queue) once vaulted pins have their plaintext back.
  public static let didRestoreVaultNotification = Notification.Name("HistoryStore.didRestoreVault")
  /// Pinned secrets the vault refused to store: their file copy is masked, so their exact text only
  /// lives in memory this session. See `retryVaultWrites()`.
  public var pinsNotSavedToVault: Set<UUID> { lock.lock(); defer { lock.unlock() }; return _pinsNotSavedToVault }
  private var _pinsNotSavedToVault: Set<UUID> = []  // guarded by `lock`

  /// - Parameters:
  ///   - fileURL: pass nil for an in-memory store (tests); the default is Application Support.
  ///   - saveDelay: debounce for disk writes; call `flush()` to write immediately.
  ///   - purgeInterval: how often expired entries are removed; nil disables the timer.
  ///   - vault: where pinned secrets' plaintext lives; nil means the Keychain for the default
  ///     history file and a process-lifetime in-memory vault for any other file.
  public init(fileURL: URL? = HistoryStore.defaultFileURL(),
              unpinnedCap: Int = HistoryStore.defaultUnpinnedCap,
              detector: SecretDetecting = SecretDetector(),
              saveDelay: TimeInterval = HistoryStore.defaultSaveDelay,
              purgeInterval: TimeInterval? = HistoryStore.defaultPurgeInterval,
              vault: SecretVault? = nil,
              now: @escaping @Sendable () -> Date = Date.init) {
    self.fileURL = fileURL
    self.unpinnedCap = unpinnedCap
    self.detector = detector
    self.saveDelay = saveDelay
    self.now = now
    if let vault { self.vault = vault }
    else if let fileURL { self.vault = fileURL == Self.defaultFileURL() ? KeychainVault() : InMemoryVault() }
    else { self.vault = nil }
    ioQueue.setSpecific(key: Self.ioQueueKey, value: true)

    if let fileURL {
      // No Keychain access here: `init` runs on the main thread at launch.
      let loaded = load(from: fileURL)
      items = loaded.items
      // Already on disk, so already through this rule (or from before OCR existed).
      scannedImages = Set(items.lazy.filter { $0.kind == .image }.map(\.id))
      // Saved pins a later scan flagged load flagged again; an unreadable list fails closed.
      let listed = Self.readFlaggedPins(next: fileURL)
      writtenFlaggedPins = listed
      let pinnedImages = Set(items.lazy.filter { $0.pinned && $0.kind == .image && $0.findings.isEmpty }.map(\.id))
      let flagged = listed.map { $0.intersection(pinnedImages) } ?? pinnedImages
      for i in items.indices where flagged.contains(items[i].id) {
        let end = items[i].ocrText?.count ?? 0
        items[i].findings = [SecretFinding(category: .genericSecret, range: end..<end)]
      }
      scannedImages.subtract(flagged)
      keptFlaggedPins = flagged
      keptFlaggedPinsOnDisk = flagged
      let before = items.count
      items.removeAll { Self.isExpired($0, at: now()) }
      // Scrub legacy plaintext secrets / expired rows / inline images right away.
      if loaded.needsRewrite || items.count != before { generation = 1 }
      if loaded.readFailed { writesBlocked = true; _isReadOnly = true }
      _isRestoringVault = self.vault != nil
      // Queue order matters: the vault is restored (and orphans found) before any write, and the
      // backup is written before anything can overwrite the original.
      let restore = loaded.vaultCandidates
      ioQueue.async {
        self.restoreVault(candidates: restore, decodedIDs: loaded.decodedIDs,
                          fullyDecoded: !loaded.readFailed && loaded.backupData == nil, next: fileURL)
      }
      if let backup = loaded.backupData {
        writesBlocked = true
        ioQueue.async { self.writeBackup(of: backup, next: fileURL) }
      }
      ioQueue.async { self.maintainBackups(next: fileURL) }
      ioQueue.async { self.writePending() }

      terminateObserver = NotificationCenter.default.addObserver(
        forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil
      ) { [weak self] _ in self?.flush() }
    }

    if let purgeInterval, purgeInterval > 0 {
      let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
      timer.schedule(deadline: .now() + purgeInterval, repeating: purgeInterval, leeway: .milliseconds(250))
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        self.removeExpired(now: self.now())
      }
      timer.resume()
      purgeTimer = timer
    }
  }

  deinit {
    purgeTimer?.cancel()
    lock.lock(); saveWork?.cancel(); saveWork = nil; lock.unlock()
    if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    flush()
  }

  public static func defaultFileURL() -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    return base.appendingPathComponent("CopyHistory", isDirectory: true).appendingPathComponent("history.json")
  }

  public func entries(matching query: String) -> [ClipboardEntry] {
    lock.lock(); defer { lock.unlock() }
    let sorted = items.sorted {
      $0.pinned != $1.pinned ? $0.pinned : $0.lastCopiedAt > $1.lastCopiedAt
    }
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return sorted }
    // Flagged entries are matched against their masked text so search cannot probe hidden characters.
    return sorted.filter { e in
      Self.searchableText(e).map { Self.fuzzyMatch(q, in: e.findings.isEmpty ? $0 : detector.mask($0, findings: e.findings)) } ?? false
    }
  }

  /// The string an entry's search and findings refer to: `text`, or `ocrText` for images.
  private static func searchableText(_ e: ClipboardEntry) -> String? { e.kind == .text ? e.text : e.ocrText }

  public func add(_ entry: ClipboardEntry) -> ClipboardEntry { add(entry, awaitingOCR: false) }

  /// `awaitingOCR`: an `applyOCR` update for this image will follow. Informational: a new image stays
  /// off disk until a successful scan of it found no secret, whether or not one is coming.
  public func add(_ entry: ClipboardEntry, awaitingOCR: Bool) -> ClipboardEntry {
    lock.lock(); defer { lock.unlock() }
    var result = entry
    if let i = items.firstIndex(where: { Self.sameContent($0, entry) }) {
      var existing = items[i]
      existing.copyCount += max(entry.copyCount, 1)
      existing.lastCopiedAt = max(existing.lastCopiedAt, entry.lastCopiedAt)
      // Never unflag what is flagged: a restored pin's findings may be synthetic (today's detector
      // no longer matches), and clearing them would write its plaintext to disk.
      if existing.findings.isEmpty || !entry.findings.isEmpty {
        existing.findings = entry.findings
        // A pin does not expire; a fresh expiry would make a later unpin drop it at once.
        if !existing.pinned { existing.expiresAt = entry.expiresAt }
      }
      if let app = entry.sourceApp { existing.sourceApp = app }
      items[i] = existing
      result = existing
    } else {
      items.append(entry)
      trimToCap()
    }
    markDirty()
    return result
  }

  /// Records the text recognised in an image entry (see `ClipboardMonitor.onOCR`). Matches the entry
  /// by id, or else an image with the same bytes (the copy was folded into it). Does nothing for an
  /// entry that is gone; never unflags an entry, and leaves the copy count and dates alone. Clean text
  /// never replaces existing text, but a scan that finds a secret flags an unflagged image (and takes
  /// it off disk). A flagged copy of an already flagged, unpinned image extends its expiry, as
  /// re-copying flagged text does. Only a `scanned` update without findings lets the image reach disk.
  public func applyOCR(_ update: OCRUpdate) {
    lock.lock(); defer { lock.unlock() }
    guard let i = items.firstIndex(where: { $0.id == update.entryID && $0.kind == .image })
      ?? items.firstIndex(where: { $0.kind == .image && $0.imagePNG == update.imagePNG }) else { return }
    var changed = false
    var e = items[i]
    if !e.findings.isEmpty {
      if !e.pinned, !update.findings.isEmpty, let old = e.expiresAt, let new = update.expiresAt, new > old {
        e.expiresAt = new
        changed = true
      }
    } else if !update.findings.isEmpty {
      if let text = update.ocrText { e.ocrText = text }
      e.findings = update.findings
      if !e.pinned { e.expiresAt = update.expiresAt }
      // A pin that was cleared for disk keeps its files until the user unpins it (see the class doc).
      if e.pinned, scannedImages.contains(e.id) { keptFlaggedPins.insert(e.id) }
      scannedImages.remove(e.id)
      changed = true
    } else if update.scanned {
      if e.ocrText == nil, let text = update.ocrText { e.ocrText = text; changed = true }
      if scannedImages.insert(e.id).inserted { changed = true }
    }
    items[i] = e
    if changed { markDirty() }
  }

  /// True for an image that was never successfully scanned for secrets (its scan is pending, timed
  /// out, failed or was skipped): it is memory-only, and a paste should treat it as sensitive.
  /// False for flagged images (their `findings` already say so) and for anything that is not an image.
  public func isUnscannedImage(_ id: UUID) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard let e = items.first(where: { $0.id == id }), e.kind == .image, e.findings.isEmpty else { return false }
    return !scannedImages.contains(id)
  }

  /// The entry as stored now, and `isUnscannedImage` for it, read together. A paste decides from
  /// this rather than from a UI snapshot, which a late OCR result may have flagged since. nil when
  /// the entry is gone.
  public func pasteState(of id: UUID) -> (entry: ClipboardEntry, unscanned: Bool)? {
    lock.lock(); defer { lock.unlock() }
    guard let e = items.first(where: { $0.id == id }) else { return nil }
    return (e, e.kind == .image && e.findings.isEmpty && !scannedImages.contains(id))
  }

  /// Pinned images flagged by a scan after they were saved: flagged (masked, pasted concealed), also
  /// after a relaunch, and their files stay on disk until unpinned. Only ids whose files are on disk:
  /// loaded flagged at launch, or kept by a write (never one whose PNG was not written yet, nor on a
  /// read-only store). The UI can say so.
  public var flaggedPinsKeptOnDisk: Set<UUID> { lock.lock(); defer { lock.unlock() }; return keptFlaggedPinsOnDisk }

  public func togglePin(_ id: UUID) {
    mutate { items in
      if let i = items.firstIndex(where: { $0.id == id }) { items[i].pinned.toggle() }
    }
    lock.lock()
    if items.first(where: { $0.id == id })?.pinned != true {
      keptFlaggedPins.remove(id)
      keptFlaggedPinsOnDisk.remove(id)
    }
    lock.unlock()
    lock.lock(); let before = items.count; trimToCap(); if items.count != before { markDirty() }; lock.unlock()
  }

  public func remove(_ id: UUID) {
    mutate { $0.removeAll { $0.id == id } }
  }

  public func removeExpired(now: Date) {
    mutate { $0.removeAll { Self.isExpired($0, at: now) } }
  }

  public func clearUnpinned() { mutate { $0.removeAll { !$0.pinned } } }

  /// Writes any pending changes synchronously.
  public func flush() {
    if DispatchQueue.getSpecific(key: Self.ioQueueKey) == true { writePending() } else { ioQueue.sync { writePending() } }
  }

  // MARK: - Internals

  /// Applies `body` and schedules a save only if the items actually changed.
  private func mutate(_ body: (inout [ClipboardEntry]) -> Void) {
    lock.lock(); defer { lock.unlock() }
    let before = items
    body(&items)
    if items != before { markDirty() }
  }

  /// Must be called with `lock` held.
  private func markDirty() {
    guard fileURL != nil else { return }
    generation += 1
    guard !saveScheduled else { return }
    saveScheduled = true
    let work = DispatchWorkItem { [weak self] in self?.writePending() }
    saveWork = work
    ioQueue.asyncAfter(deadline: .now() + saveDelay, execute: work)
  }

  /// The pending debounced save, if any (for tests).
  var scheduledSave: DispatchWorkItem? { lock.lock(); defer { lock.unlock() }; return saveWork }

  private static func isExpired(_ e: ClipboardEntry, at date: Date) -> Bool {
    !e.pinned && (e.expiresAt.map { $0 <= date } ?? false)
  }

  private func trimToCap() {
    let unpinned = items.filter { !$0.pinned }
    guard unpinned.count > unpinnedCap else { return }
    let drop = Set(unpinned.sorted { $0.lastCopiedAt < $1.lastCopiedAt }.prefix(unpinned.count - unpinnedCap).map(\.id))
    items.removeAll { drop.contains($0.id) }
  }

  private var imagesDirectory: URL? {
    fileURL?.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
  }

  private func imageURL(_ id: UUID) -> URL? { imagesDirectory?.appendingPathComponent("\(id.uuidString).png") }

  /// The on-disk form of an entry: no image bytes, and no plaintext for flagged entries. nil means
  /// memory only, which for an image also keeps its PNG off disk. `scanned`: the image may be written.
  /// `keptFlagged`: a pinned image flagged after it was saved (see `flaggedPinsKeptOnDisk`).
  /// Runs on `ioQueue`.
  private func diskRecord(_ e: ClipboardEntry, scanned: Bool, keptFlagged: Bool = false) -> ClipboardEntry? {
    var r = e
    r.imagePNG = nil
    if e.kind == .image {
      // A pinned legacy image whose vault item is unreadable: sensitive in memory, its files kept.
      // Only ids loaded from disk are here; a legacy inline PNG is written to `images/` now.
      if e.pinned, unreadableVaultIDs.contains(e.id) {
        r.findings = []; r.expiresAt = nil
        return r
      }
      // A saved pin a later scan flagged: its files stay until unpinned, its OCR text only masked.
      if e.pinned, keptFlagged, writtenImageIDs.contains(e.id) || loadedImageIDs.contains(e.id) {
        r.ocrText = e.ocrText.map { masked(detector.mask($0, findings: e.findings)) }
        r.findings = []; r.expiresAt = nil
        return r
      }
      // Unscanned or flagged images are memory-only, pinned or not.
      return e.findings.isEmpty && scanned ? r : nil
    }
    guard !e.findings.isEmpty else { return r }
    guard e.pinned, let text = e.text else { return nil }  // unpinned secrets: memory only
    r.text = detector.mask(text, findings: e.findings)
    r.findings = []
    r.expiresAt = nil
    return r
  }

  /// `text` with anything the detector still finds masked too (fail closed).
  private func masked(_ text: String) -> String {
    let missed = detector.scan(text)
    return missed.isEmpty ? text : detector.mask(text, findings: missed)
  }

  /// Runs on `ioQueue`.
  private func writePending() {
    lock.lock()
    saveScheduled = false
    saveWork?.cancel()  // this write covers it
    saveWork = nil
    let gen = generation
    let live = Set(items.lazy.filter { $0.kind == .image }.map(\.id))
    scannedImages.formIntersection(live)
    keptFlaggedPins.formIntersection(live)
    let scanned = scannedImages
    let keptFlagged = keptFlaggedPins
    let snapshot = items
    lock.unlock()
    guard let fileURL, gen != writtenGeneration, !writesBlocked else { return }
    // What reaches disk: never an image without a clean scan, a flagged image, or an unpinned secret.
    let records = snapshot.compactMap { e in
      diskRecord(e, scanned: scanned.contains(e.id), keptFlagged: keptFlagged.contains(e.id)).map { (entry: e, record: $0) }
    }

    let fm = FileManager.default
    let dir = fileURL.deletingLastPathComponent()
    guard Self.ensurePrivateDirectory(dir) else { return }

    var liveImages: Set<UUID> = []
    if let imagesDir = imagesDirectory, records.contains(where: { $0.entry.kind == .image }) || !writtenImageIDs.isEmpty {
      guard Self.ensurePrivateDirectory(imagesDir) else { return }
      for (e, _) in records where e.kind == .image {
        guard let png = e.imagePNG, let url = imageURL(e.id) else { continue }
        liveImages.insert(e.id)
        if writtenImageIDs.contains(e.id) { continue }
        if !fm.fileExists(atPath: url.path) { guard Self.writePrivate(png, to: url) else { return } }
        writtenImageIDs.insert(e.id)
      }
    }

    // Pinned secrets reach the vault before the JSON that only holds their masked text.
    var vaultShouldHold: Set<UUID> = []
    var notSaved: Set<UUID> = []
    if let vault {
      // Text only: a flagged image is never on disk, so its text has nothing to be restored into.
      for (e, _) in records where e.kind == .text && e.pinned && !e.findings.isEmpty {
        guard let text = e.text else { continue }
        vaultShouldHold.insert(e.id)
        if vaultedIDs.contains(e.id) { continue }
        if vault.store(text, for: e.id) { vaultedIDs.insert(e.id) } else { notSaved.insert(e.id) }
      }
    }
    lock.lock(); _pinsNotSavedToVault = notSaved; lock.unlock()

    // Kept flagged pins are listed before the JSON holds their masked record, and leave the list
    // only after it no longer does, so a relaunch never loads one unflagged.
    let keptOnDisk = keptFlagged.filter { id in writtenImageIDs.contains(id) && records.contains { $0.entry.id == id } }
    if writtenFlaggedPins.map({ !keptOnDisk.isSubset(of: $0) }) ?? true {
      let listed = keptOnDisk.union(writtenFlaggedPins ?? [])
      guard Self.writeFlaggedPins(listed, next: fileURL) else { return }
      writtenFlaggedPins = listed
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(records.map(\.record)) else { return }
    if data != lastWrittenJSON || !fm.fileExists(atPath: fileURL.path) {
      guard Self.writePrivate(data, to: fileURL) else { return }
      lastWrittenJSON = data
    }
    writtenGeneration = gen
    if writtenFlaggedPins != keptOnDisk, Self.writeFlaggedPins(keptOnDisk, next: fileURL) { writtenFlaggedPins = keptOnDisk }
    lock.lock(); keptFlaggedPinsOnDisk = keptOnDisk.intersection(keptFlaggedPins); lock.unlock()

    // Unpinned, removed or cleared secrets leave the vault once the JSON no longer lists them as pins.
    if let vault, vaultRemovalsAllowed {
      for id in vaultedIDs.subtracting(vaultShouldHold.union(vaultIDsToKeep(snapshot))) {
        vault.remove(id)
        vaultedIDs.remove(id)
      }
    }

    // Remove image files that are no longer referenced (only after the JSON no longer points at them).
    for id in writtenImageIDs.subtracting(liveImages) {
      if let url = imageURL(id) { try? fm.removeItem(at: url) }
      writtenImageIDs.remove(id)
    }
  }

  /// Asks for another attempt to store `pinsNotSavedToVault` (e.g. after the user allowed Keychain access).
  public func retryVaultWrites() {
    lock.lock(); defer { lock.unlock() }
    guard !_pinsNotSavedToVault.isEmpty else { return }
    markDirty()
  }

  /// Vault ids that must survive a write of `snapshot`: live flagged pins, pins whose plaintext could
  /// not be read back (still the only copy), and items retained because records were lost.
  private func vaultIDsToKeep(_ snapshot: [ClipboardEntry]) -> Set<UUID> {
    var keep = retainedVaultIDs
    for e in snapshot where e.pinned && (!e.findings.isEmpty || unreadableVaultIDs.contains(e.id)) { keep.insert(e.id) }
    return keep
  }

  private struct Loaded {
    var items: [ClipboardEntry] = []
    var needsRewrite = false
    var backupData: Data?
    /// The file exists but could not be read.
    var readFailed = false
    /// Pins stored masked whose plaintext may be in the vault.
    var vaultCandidates: Set<UUID> = []
    /// Ids of every record decoded, including expired ones (their vault items are not orphans of a lost record).
    var decodedIDs: Set<UUID> = []
  }

  /// Decodes record by record, without touching the vault. Anything undecodable makes `backupData`
  /// the original bytes; only a missing file counts as empty history.
  private func load(from fileURL: URL) -> Loaded {
    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch {
      return Loaded(readFailed: !Self.isNoSuchFile(error))
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var loaded = Loaded()
    var lostRecords = false
    if let records = try? decoder.decode([Failable].self, from: data) {
      for r in records {
        guard var e = r.entry else { lostRecords = true; continue }
        loaded.decodedIDs.insert(e.id)
        if e.kind == .image { loadedImageIDs.insert(e.id) }
        if e.kind == .image, e.imagePNG == nil {
          guard let url = imageURL(e.id), let png = try? Data(contentsOf: url) else { lostRecords = true; continue }
          e.imagePNG = png
          writtenImageIDs.insert(e.id)
        } else if e.kind == .image {
          loaded.needsRewrite = true  // legacy inline image
        }
        // The current format never writes findings, so a record that has them holds legacy plaintext.
        if !e.findings.isEmpty { loaded.needsRewrite = true }
        if e.pinned, e.findings.isEmpty, Self.searchableText(e) != nil { loaded.vaultCandidates.insert(e.id) }
        loaded.items.append(e)
      }
    } else {
      lostRecords = true
    }
    if lostRecords { loaded.backupData = data }
    return loaded
  }

  private static func isNoSuchFile(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain, ns.code == CocoaError.fileReadNoSuchFile.rawValue { return true }
    if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) { return true }
    return (ns.userInfo[NSUnderlyingErrorKey] as? Error).map(isNoSuchFile) ?? false
  }

  /// Runs on `ioQueue`, first: lists the vault, gives vaulted pins their plaintext back, and decides
  /// which vault items are orphans. Nothing is an orphan unless the file was read and fully decoded,
  /// the vault could be listed, and no recovery backup still references the item.
  private func restoreVault(candidates: Set<UUID>, decodedIDs: Set<UUID>, fullyDecoded: Bool, next url: URL) {
    defer {
      lock.lock(); _isRestoringVault = false; lock.unlock()
      NotificationCenter.default.post(name: Self.didRestoreVaultNotification, object: self)
    }
    guard let vault else { return }
    let listed = vault.ids()
    let toLoad = listed.map { candidates.intersection($0) } ?? candidates
    let texts = vault.loadAll(toLoad)
    vaultedIDs = listed ?? Set(texts.keys)
    vaultRemovalsAllowed = listed != nil
    if listed != nil { unreadableVaultIDs = toLoad.subtracting(texts.keys) }

    var retained = Self.readRetained(next: url).values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
    // Records were lost: any vault item not claimed by a decoded record may belong to one of them.
    if !fullyDecoded { retained.formUnion(vaultedIDs.subtracting(decodedIDs)) }
    retainedVaultIDs = retained

    lock.lock()
    var changed = false
    // A pinned image whose vault item exists but cannot be read showed a secret: treat it as
    // sensitive without touching its (masked) text. Its files stay as they are (see `diskRecord`).
    for id in unreadableVaultIDs {
      guard let i = items.firstIndex(where: { $0.id == id }), items[i].kind == .image, items[i].findings.isEmpty else { continue }
      let end = items[i].ocrText?.count ?? 0
      items[i].findings = [SecretFinding(category: .genericSecret, range: end..<end)]
    }
    for (id, plain) in texts {
      guard let i = items.firstIndex(where: { $0.id == id }), items[i].findings.isEmpty else { continue }
      var e = items[i]
      if e.kind == .image {
        e.ocrText = plain
        changed = true  // a legacy flagged image pin: now memory-only, so its files must go
      } else {
        e.text = plain
      }
      let found = detector.scan(plain)
      // Still treated as flagged if today's detector no longer matches, so it never lands on disk.
      e.findings = found.isEmpty ? [SecretFinding(category: .genericSecret, range: 0..<plain.count)] : found
      // The same text copied again while the pin was masked: fold that copy into the pin.
      let dups = e.kind == .text ? items.filter { $0.id != id && !$0.pinned && $0.kind == .text && $0.text == plain } : []
      for d in dups {
        e.copyCount += d.copyCount
        e.lastCopiedAt = max(e.lastCopiedAt, d.lastCopiedAt)
      }
      items[i] = e
      if !dups.isEmpty {
        let dupIDs = Set(dups.map(\.id))
        items.removeAll { dupIDs.contains($0.id) }
        changed = true
      }
    }
    let orphans = vaultedIDs.subtracting(vaultIDsToKeep(items))
    if changed || (fullyDecoded && vaultRemovalsAllowed && !orphans.isEmpty) { generation += 1 }
    lock.unlock()
  }

  // MARK: - Retained vault items (backup file name -> vault ids it may hold pins for)

  private static func retainedURL(next url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent("history.retained-vault.json")
  }

  private static func readRetained(next url: URL) -> [String: Set<UUID>] {
    guard let data = try? Data(contentsOf: retainedURL(next: url)),
          let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
    let dir = url.deletingLastPathComponent()
    var out: [String: Set<UUID>] = [:]
    // Only while the backup itself still exists.
    for (name, ids) in raw where FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
      out[name] = Set(ids.compactMap(UUID.init(uuidString:)))
    }
    return out
  }

  private static func writeRetained(_ map: [String: Set<UUID>], next url: URL) -> Bool {
    let file = retainedURL(next: url)
    guard !map.isEmpty else {
      try? FileManager.default.removeItem(at: file)
      return !FileManager.default.fileExists(atPath: file.path)
    }
    guard let data = try? JSONEncoder().encode(map.mapValues { $0.map(\.uuidString).sorted() }) else { return false }
    return writePrivate(data, to: file)
  }

  // MARK: - Kept flagged pins (ids only: no text, findings or image data)

  private static func flaggedPinsURL(next url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent("history.flagged-pins.json")
  }

  /// The listed ids; empty when there is no file, nil when it exists but cannot be read or holds
  /// anything but ids (the caller fails closed).
  private static func readFlaggedPins(next url: URL) -> Set<UUID>? {
    let data: Data
    do { data = try Data(contentsOf: flaggedPinsURL(next: url)) } catch { return isNoSuchFile(error) ? [] : nil }
    guard let raw = try? JSONDecoder().decode([String].self, from: data) else { return nil }
    let ids = raw.compactMap(UUID.init(uuidString:))
    return ids.count == raw.count ? Set(ids) : nil
  }

  private static func writeFlaggedPins(_ ids: Set<UUID>, next url: URL) -> Bool {
    let file = flaggedPinsURL(next: url)
    guard !ids.isEmpty else {
      try? FileManager.default.removeItem(at: file)
      return !FileManager.default.fileExists(atPath: file.path)
    }
    guard let data = try? JSONEncoder().encode(ids.map(\.uuidString).sorted()) else { return false }
    return writePrivate(data, to: file)
  }

  private struct Failable: Decodable {
    let entry: ClipboardEntry?
    init(from decoder: Decoder) throws { entry = try? ClipboardEntry(from: decoder) }
  }

  // MARK: - Recovery backups

  static let backupPrefix = "history.corrupt-"

  /// Runs on `ioQueue`, before any write of the history file.
  private func writeBackup(of data: Data, next url: URL) {
    let dir = url.deletingLastPathComponent()
    guard Self.ensurePrivateDirectory(dir) else { return }
    let scrubbed = Self.scrubbedBackup(data, detector: detector)
    // The same file is still undecodable (nothing was written since): reuse its backup.
    let existing = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix(Self.backupPrefix) && $0.pathExtension == "json" }
      .first { (try? Data(contentsOf: $0)) == scrubbed }
    let backup: URL
    if let existing {
      backup = existing
    } else {
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
      var candidate = dir.appendingPathComponent("\(Self.backupPrefix)\(stamp).json")
      var n = 1
      while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent("\(Self.backupPrefix)\(stamp)-\(n).json"); n += 1
      }
      guard Self.writePrivate(scrubbed, to: candidate) else { return }
      backup = candidate
    }
    Self.excludeFromTimeMachine(backup)
    lock.lock(); _recoveryBackupURL = backup; lock.unlock()
    // Vault items its lost records may own outlive this launch, as long as the backup does.
    if !retainedVaultIDs.isEmpty {
      var map = Self.readRetained(next: url)
      map[backup.lastPathComponent, default: []].formUnion(retainedVaultIDs)
      guard Self.writeRetained(map, next: url) else { return }
    }
    writesBlocked = false
  }

  /// Runs on `ioQueue`: deletes old or surplus backups, and masks secrets (and fixes permissions)
  /// in the ones kept, including backups written in plaintext by older versions.
  private func maintainBackups(next url: URL) {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    let current = recoveryBackupURL?.lastPathComponent
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    let backups = files
      .filter { $0.lastPathComponent.hasPrefix(Self.backupPrefix) && $0.pathExtension == "json" }
      .map { (url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
      .sorted { $0.date > $1.date }
    let cutoff = now().addingTimeInterval(-Self.backupRetention)
    let retainedBefore = Self.readRetained(next: url)
    var retained = retainedBefore
    defer { if retained != retainedBefore { _ = Self.writeRetained(retained, next: url) } }
    for (i, b) in backups.enumerated() {
      // The backup made by this launch always survives, so `recoveryBackupURL` stays valid.
      if b.url.lastPathComponent != current, i >= Self.maxBackups || b.date < cutoff {
        try? fm.removeItem(at: b.url)
        if !fm.fileExists(atPath: b.url.path) { retained[b.url.lastPathComponent] = nil }
        continue
      }
      if let data = try? Data(contentsOf: b.url) {
        let clean = Self.scrubbedBackup(data, detector: detector)
        if clean != data, Self.writePrivate(clean, to: b.url) {
          try? fm.setAttributes([.modificationDate: b.date], ofItemAtPath: b.url.path)
        }
      }
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: b.url.path)
      Self.excludeFromTimeMachine(b.url)
    }
  }

  /// The backup with every detected secret masked: each string of a JSON file (record text, and
  /// anything else an undecodable record may hold), or the raw text of a file that is not JSON.
  /// Returns the input bytes untouched when nothing was found.
  static func scrubbedBackup(_ data: Data, detector: SecretDetecting) -> Data {
    if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
      var changed = false
      let clean = scrub(json, detector: detector, changed: &changed)
      guard changed else { return data }
      return (try? JSONSerialization.data(withJSONObject: clean, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]))
        ?? Data("[]".utf8)  // never fall back to the plaintext
    }
    // Not JSON: scan the raw text. Undo `\/` escaping first, or base64 secrets containing `/` slip by.
    let raw = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    let findings = detector.scan(raw)
    return findings.isEmpty ? data : Data(detector.mask(raw, findings: findings).utf8)
  }

  private static func scrub(_ value: Any, detector: SecretDetecting, changed: inout Bool) -> Any {
    switch value {
    case let s as String:
      let findings = detector.scan(s)
      guard !findings.isEmpty else { return s }
      changed = true
      return detector.mask(s, findings: findings)
    case let array as [Any]:
      return array.map { scrub($0, detector: detector, changed: &changed) }
    case var dict as [String: Any]:
      // A record's stored findings also count (they may come from an older, broader detector).
      var stored: [SecretFinding] = []
      if let f = dict["findings"], JSONSerialization.isValidJSONObject(f),
         let fData = try? JSONSerialization.data(withJSONObject: f),
         let decoded = try? JSONDecoder().decode([SecretFinding].self, from: fData) {
        stored = decoded
      }
      for (key, v) in dict where key != "imagePNG" {
        if key == "text" || key == "ocrText", let text = v as? String, !stored.isEmpty {
          dict[key] = detector.mask(text, findings: stored + detector.scan(text))
          dict["findings"] = [Any]()
          changed = true
        } else if key != "findings" || stored.isEmpty {
          dict[key] = scrub(v, detector: detector, changed: &changed)
        }
      }
      return dict
    default:
      return value
    }
  }

  private static func excludeFromTimeMachine(_ url: URL) {
    var u = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? u.setResourceValues(values)
  }

  /// Creates `dir` (and parents) if needed and forces mode 0700, including on pre-existing directories.
  private static func ensurePrivateDirectory(_ dir: URL) -> Bool {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      return true
    } catch { return false }
  }

  /// Atomically replaces `url` with `data`; the file is created 0600 so it is never briefly world-readable.
  private static func writePrivate(_ data: Data, to url: URL) -> Bool {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
    guard rename(tmp.path, url.path) == 0 else { try? FileManager.default.removeItem(at: tmp); return false }
    return true
  }

  private static func sameContent(_ a: ClipboardEntry, _ b: ClipboardEntry) -> Bool {
    a.kind == b.kind && (a.kind == .text ? a.text == b.text : a.imagePNG == b.imagePNG)
  }

  /// Case-insensitive subsequence match.
  static func fuzzyMatch(_ query: String, in text: String) -> Bool {
    var q = query.lowercased().makeIterator()
    guard var want = q.next() else { return true }
    for ch in text.lowercased() where ch == want {
      guard let next = q.next() else { return true }
      want = next
    }
    return false
  }
}
