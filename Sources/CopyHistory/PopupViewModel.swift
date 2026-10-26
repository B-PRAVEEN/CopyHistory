import AppKit
import CopyHistoryCore

@MainActor
final class PopupViewModel: ObservableObject {
  enum Mode { case list, transforms }

  @Published var query = "" {
    didSet { if oldValue != query { reload(resetSelection: true) } }
  }
  @Published private(set) var items: [ClipboardEntry] = []
  @Published var selection = 0
  @Published private(set) var mode: Mode = .list
  @Published private(set) var transforms: [any Transform] = []
  @Published var transformSelection = 0
  @Published private(set) var isTransforming = false
  private let transformSession = TransformSession()
  /// Non-activating, so showing it never takes focus from the paste target.
  private let hud = PasteStackHUD()
  private var transformEntry: ClipboardEntry?  // fixed when the picker opens; a reload can't retarget it
  @Published private(set) var message: String?
  @Published private(set) var focusTick = 0

  let services: AppServices
  let settings: AppSettings
  let pasteService: PasteService
  var onClose: () -> Void = {}
  /// The concrete store behind `services.store`, for vault state; nil for other stores.
  private let historyStore: HistoryStore?
  // Main-thread confined; nonisolated so deinit can always remove it.
  nonisolated(unsafe) private var restoreObserver: NSObjectProtocol?
  nonisolated(unsafe) private var updateObserver: NSObjectProtocol?

  init(services: AppServices, settings: AppSettings, pasteService: PasteService) {
    self.services = services
    self.settings = settings
    self.pasteService = pasteService
    historyStore = services.store as? HistoryStore
    // Posted on the store's queue once vaulted pins have their plaintext back; until then they are
    // listed masked. A restore that finished before this point is picked up by the next show.
    // Both observers hop to main themselves (`queue: nil`): with `queue: .main` a post from the
    // store's queue waits for the main thread, which deadlocks while main is in `flush()`.
    if let historyStore {
      restoreObserver = NotificationCenter.default.addObserver(
        forName: HistoryStore.didRestoreVaultNotification, object: historyStore, queue: nil
      ) { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.vaultRestored() } } }
      // A late OCR result can flag a listed image: reload so its row is masked and its pixels hidden.
      updateObserver = NotificationCenter.default.addObserver(
        forName: HistoryStore.didUpdateEntriesNotification, object: historyStore, queue: nil
      ) { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.reloadKeepingSelection() } } }
    }
    settings.attach(store: historyStore)  // after observing, so a restore in between still refreshes it
  }

  deinit {
    if let restoreObserver { NotificationCenter.default.removeObserver(restoreObserver) }
    if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
  }

  private var isRestoringVault: Bool { historyStore?.isRestoringVault ?? false }

  private func vaultRestored() {
    reloadKeepingSelection()
    if message == PopupPolicy.restoringVaultMessage { message = nil }
    settings.refreshVaultStatus()
  }

  // MARK: State

  /// Called every time the popup is summoned.
  func prepareForShow() {
    cancelTransform()
    mode = .list
    message = nil
    if !query.isEmpty { query = "" } else { reload(resetSelection: true) }
    focusTick += 1
  }

  /// Called every time the popup is hidden, however that happens (Esc, paste, resign key, Settings).
  /// A running transform is cancelled so its result can never paste into an app the user did not pick.
  func didHide() {
    cancelTransform()
    transformEntry = nil
    mode = .list
    message = nil
  }

  func reload(resetSelection: Bool = false) {
    services.store.removeExpired(now: Date())
    let all = services.store.entries(matching: query)
    items = all.filter(\.pinned) + all.filter { !$0.pinned }
    if resetSelection { selection = 0 }
    selection = items.isEmpty ? 0 : min(selection, items.count - 1)
  }

  /// A reload the user did not ask for (an OCR result, the expiry timer): the selection stays on the
  /// same entry. If that entry is gone nothing is selected, so Return never pastes another one.
  func reloadKeepingSelection() {
    let hadSelection = selectedEntry != nil
    let selectedID = selectedEntry?.id
    reload()
    guard hadSelection else { return }
    if let i = PopupPolicy.selection(afterReloadOf: selectedID, in: items.map(\.id)) {
      selection = i
    } else {
      selection = -1
      if mode == .list { message = PopupPolicy.entryGoneMessage }
    }
  }

  var selectedEntry: ClipboardEntry? { items.indices.contains(selection) ? items[selection] : nil }

  func displayText(for entry: ClipboardEntry) -> String {
    guard entry.kind == .text, let text = entry.text else { return "Image" }
    let shown = entry.findings.isEmpty ? text : services.detector.mask(text, findings: entry.findings)
    return PopupPolicy.oneLine(shown)
  }

  /// Snippet of the text recognised in an image entry (masked when flagged), or nil.
  func ocrSnippet(for entry: ClipboardEntry) -> String? {
    guard entry.kind == .image else { return nil }
    return PopupPolicy.ocrSnippet(for: historyStore?.pasteState(of: entry.id)?.entry ?? entry, detector: services.detector)
  }

  /// Tooltip for an image row whose pixels are hidden (flagged, or never checked for secrets).
  /// Decided from the store as it is now: the row's snapshot may predate an OCR result that flagged
  /// it. Other stores cannot say whether the image was scanned (nil): fail closed.
  func hiddenThumbnailHelp(for entry: ClipboardEntry) -> String? {
    guard entry.kind == .image else { return nil }
    return PopupPolicy.hiddenThumbnailHelp(for: entry, live: historyStore?.pasteState(of: entry.id))
  }

  /// A warning shown on the row, e.g. a saved pin flagged later (it is kept on disk until unpinned).
  func rowNote(for entry: ClipboardEntry) -> String? {
    guard entry.kind == .image, entry.pinned, let historyStore,
          historyStore.pasteState(of: entry.id)?.entry.findings.isEmpty == false,
          historyStore.flaggedPinsKeptOnDisk.contains(entry.id) else { return nil }
    return PopupPolicy.flaggedPinKeptOnDiskNote
  }

  /// Whether ⇧⌘↩ has text to paste for the selected entry (drives the footer hint).
  var selectedHasOCRText: Bool { selectedEntry.flatMap(PopupPolicy.ocrText(of:)) != nil }

  // MARK: Keyboard

  /// Returns true when the event was consumed.
  func handleKey(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
    var mods: PopupKeyMap.Modifiers = []
    if flags.contains(.command) { mods.insert(.command) }
    if flags.contains(.option) { mods.insert(.option) }
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.control) { mods.insert(.control) }
    guard let command = PopupKeyMap.command(keyCode: keyCode, modifiers: mods, characters: characters,
                                            mode: mode == .transforms ? .transforms : .list) else { return false }
    switch command {
    case .close: onClose()
    case .leaveTransforms: leaveTransforms()
    case .move(let delta): move(delta)
    case .applyTransform: applySelectedTransform()
    case .copyOnly: copyOnly()
    case .paste(let flipPlain): pasteSelected(flipPlain: flipPlain)
    case .pasteOCRText: pasteSelectedOCRText()
    case .openTransforms: openTransforms()
    case .togglePin: togglePinSelected()
    case .delete: deleteSelected()
    case .pasteItem(let index, let flipPlain): pasteItem(at: index, flipPlain: flipPlain)
    }
    return true
  }

  private func move(_ delta: Int) {
    if mode == .transforms {
      guard !transforms.isEmpty else { return }
      transformSelection = (transformSelection + delta + transforms.count) % transforms.count
    } else {
      guard !items.isEmpty else { return }
      selection = max(0, min(items.count - 1, selection + delta))
    }
  }

  // MARK: Actions

  /// `flipPlain` inverts the plain-text default (Shift+Return, Option-click, Opt+Cmd+N).
  /// Entries are stored as plain text, so plain-only only matters for images: it skips them.
  private func isPlainOnly(flip: Bool) -> Bool { settings.plainTextDefault != flip }

  func pasteItem(at index: Int, flipPlain: Bool) {
    guard items.indices.contains(index) else { return }
    selection = index
    pasteSelected(flipPlain: flipPlain)
  }

  func pasteSelected(flipPlain: Bool) {
    guard let entry = selectedEntry, let current = pasteState(of: entry) else { return }
    perform(PopupPolicy.decide(current.entry, request: .entry, plainOnly: isPlainOnly(flip: flipPlain),
                               isRestoringVault: isRestoringVault, unscanned: current.unscanned),
            copyOnly: false, unscanned: current.unscanned)
  }

  /// ⇧⌘↩: pastes only the text recognised in the selected image (as a secret if the image is flagged).
  func pasteSelectedOCRText() {
    guard mode == .list, let entry = selectedEntry, let current = pasteState(of: entry) else { return }
    perform(PopupPolicy.decide(current.entry, request: .ocrText, plainOnly: false,
                               isRestoringVault: isRestoringVault, unscanned: current.unscanned),
            copyOnly: false, unscanned: current.unscanned)
  }

  func copyOnly() {
    guard let entry = selectedEntry, let current = pasteState(of: entry) else { return }
    perform(PopupPolicy.decide(current.entry, request: .entry, plainOnly: false,
                               isRestoringVault: isRestoringVault, unscanned: current.unscanned),
            copyOnly: true, unscanned: current.unscanned)
  }

  /// The entry as stored now (a late OCR result may have flagged it since the list was loaded) and
  /// whether it is an image never checked for secrets. nil, with a message, when it is gone.
  private func pasteState(of entry: ClipboardEntry) -> (entry: ClipboardEntry, unscanned: Bool)? {
    // Other stores: every image counts as unscanned (fail closed).
    switch PopupPolicy.actionTarget(snapshot: entry, storeKnowsScans: historyStore != nil,
                                    live: historyStore?.pasteState(of: entry.id)) {
    case .entry(let current, let unscanned):
      return (current, unscanned)
    case .gone:
      message = PopupPolicy.entryGoneMessage
      reload()
      return nil
    }
  }

  /// `unscanned`: the content comes from an image never checked for secrets. It is written as
  /// concealed and cleared shortly, so a copy the user pastes by hand keeps the popup open to say so.
  private func perform(_ decision: PasteDecision, copyOnly: Bool, unscanned: Bool = false) {
    switch decision {
    case .none:
      return
    case .refuse(let text):
      message = text
    case .deliver(let content, let sensitive):
      if copyOnly {
        pasteService.copy(content, sensitive: sensitive)
        follow(PopupPolicy.followUpAfterCopy(unscanned: unscanned))
      } else {
        deliver(content, sensitive: sensitive, unscanned: unscanned)
      }
    }
  }

  /// Pastes into the captured app, or — when there is none (CopyHistory itself was frontmost) —
  /// copies and keeps the popup open to say so instead of typing ⌘V into a stale target.
  private func deliver(_ content: PasteContent, sensitive: Bool?, unscanned: Bool = false) {
    guard pasteService.hasPasteTarget else {
      pasteService.copy(content, sensitive: sensitive)
      follow(PopupPolicy.followUpWithoutTarget(unscanned: unscanned))
      return
    }
    onClose()
    let route = pasteService.paste(content, sensitive: sensitive)
    if case .closeWithHUD(let text, let seconds) = PopupPolicy.followUpAfterPaste(route: route, unscanned: unscanned) {
      hud.show(text, duration: seconds)  // the popup is already closed
    }
  }

  private func follow(_ followUp: PopupFollowUp) {
    switch followUp {
    case .close: onClose()
    case .stay(let text): message = text
    case .closeWithHUD(let text, let seconds):
      onClose()
      hud.show(text, duration: seconds)
    }
  }

  func togglePinSelected() {
    guard let entry = selectedEntry else { return }
    services.store.togglePin(entry.id)
    reload()
    if let i = items.firstIndex(where: { $0.id == entry.id }) { selection = i }
  }

  func deleteSelected() {
    guard let entry = selectedEntry else { return }
    services.store.remove(entry.id)
    reload()
  }

  // MARK: Transforms

  func openTransforms() {
    guard let entry = selectedEntry, entry.kind == .text, let text = entry.text else { return }
    // A vaulted pin still holds its masked placeholder: transforming it would paste bullets.
    if PopupPolicy.isBlockedByVaultRestore(entry, request: .entry, isRestoringVault: isRestoringVault) {
      message = PopupPolicy.restoringVaultMessage
      return
    }
    cancelTransform()
    transformEntry = entry
    transforms = TransformRegistry.all.filter { $0.canApply(to: text) }
    transformSelection = 0
    message = nil
    mode = .transforms
  }

  func leaveTransforms() {
    cancelTransform()
    transformEntry = nil
    mode = .list
    message = nil
    focusTick += 1
  }

  /// Runs off the main actor with a time budget; Esc (leaving the picker) and hiding the popup
  /// cancel. Output derived from a flagged entry is pasted as a secret whatever it looks like.
  func applySelectedTransform() {
    guard mode == .transforms, let entry = transformEntry,
          transforms.indices.contains(transformSelection) else { return }
    let started = transformSession.start(transforms[transformSelection], on: entry) { [weak self] outcome in
      guard let self else { return }
      self.isTransforming = false
      guard self.mode == .transforms else { return }
      switch outcome.result {
      case .success(let output):
        self.message = nil
        self.deliver(.text(output), sensitive: outcome.sensitive)
      case .failure(let error):
        self.message = "Transform failed: \(error.localizedDescription)"
      }
    }
    guard started else { return }
    isTransforming = true
    message = "Transforming… (esc to cancel)"
  }

  private func cancelTransform() {
    transformSession.cancel()
    isTransforming = false
  }
}
