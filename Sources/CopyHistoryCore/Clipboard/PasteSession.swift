import Foundation

/// How a paste request is carried out.
public enum PasteRoute: Equatable, Sendable {
  case paste     // write, activate the captured target, post ⌘V
  case copyOnly  // write only; the user pastes by hand
}

/// Pure decisions behind the paste path, kept out of AppKit so they can be tested.
public enum PastePolicy {
  /// The paste target to remember when the popup is summoned. When CopyHistory itself is frontmost
  /// (e.g. Settings was just used) or nothing is, there is no valid target: a target captured on an
  /// earlier summon is stale and must not receive ⌘V, so the result is nil rather than "keep the old one".
  public static func captureTarget<App>(frontmost: App?, isSelf: (App) -> Bool) -> App? {
    guard let frontmost, !isSelf(frontmost) else { return nil }
    return frontmost
  }

  /// Without a target or without Accessibility the content is only copied.
  public static func route(hasTarget: Bool, accessibilityTrusted: Bool) -> PasteRoute {
    hasTarget && accessibilityTrusted ? .paste : .copyOnly
  }

  /// ⌘V may only be posted once the captured target is the frontmost app, never into whatever
  /// happens to be frontmost instead.
  public static func mayPostPaste(targetPID: Int32?, frontmostPID: Int32?) -> Bool {
    guard let targetPID, let frontmostPID else { return false }
    return targetPID == frontmostPID
  }

  /// After an auto-paste, a secret only needs to survive until the target app has read it.
  public static let secretClearAfterPaste: TimeInterval = 2
  /// After copy-only (or paste without Accessibility) the user pastes by hand, so allow longer.
  public static let secretClearAfterCopy: TimeInterval = 30

  /// How long a secret written for `route` stays on the pasteboard.
  public static func clearAfter(_ route: PasteRoute) -> TimeInterval {
    route == .paste ? secretClearAfterPaste : secretClearAfterCopy
  }

  /// The writer's `sensitive` argument for `content`: text passes it through (nil lets the writer
  /// scan the text); an image cannot be scanned there, so it is marked only when `sensitive` is true.
  public static func writerSensitivity(for content: PasteContent, sensitive: Bool?) -> Bool? {
    switch content {
    case .text: return sensitive
    case .image: return sensitive == true
    }
  }

  /// The `sensitive` argument for the pasteboard writer when writing `entry`, or anything derived
  /// from it: true for a flagged entry, so the decision never depends on re-scanning the written
  /// text (a transform can turn a detected secret into undetectable output); nil lets the writer scan.
  public static func sensitivity(of entry: ClipboardEntry) -> Bool? {
    entry.findings.isEmpty ? nil : true
  }
}

/// The result of a transform run, tagged with the entry it was derived from.
public struct TransformOutcome: Sendable {
  public let entryID: UUID
  public let result: Result<String, any Error>
  /// Sensitivity of the source entry, captured when the run started (see `PastePolicy.sensitivity`).
  public let sensitive: Bool?
}

/// One transform run at a time, off the main actor. A run's completion is delivered on the main
/// actor only if the session was not cancelled meanwhile; the popup cancels on Esc, on reopening
/// the picker, on every show and on every hide, so a late result can never paste into an app the
/// user did not pick.
@MainActor
public final class TransformSession {
  public typealias Runner = @Sendable (any Transform, String) async throws -> String

  public private(set) var isRunning = false
  private let runner: Runner
  private var task: Task<Void, Never>?
  private var generation = 0  // bumped per run and on cancel; stale completions are dropped

  public init(runner: @escaping Runner = { try await TransformRunner.run($0, on: $1) }) {
    self.runner = runner
  }

  /// Starts `transform` on a text `entry`. Returns false (and never calls `completion`) when a run
  /// is already in progress or the entry has no text.
  @discardableResult
  public func start(_ transform: any Transform, on entry: ClipboardEntry,
                    completion: @escaping @MainActor (TransformOutcome) -> Void) -> Bool {
    guard task == nil, entry.kind == .text, let text = entry.text else { return false }
    generation += 1
    let current = generation
    let sensitive = PastePolicy.sensitivity(of: entry)
    let entryID = entry.id
    isRunning = true
    task = Task { [weak self, runner] in
      let result: Result<String, any Error>
      do { result = .success(try await runner(transform, text)) } catch { result = .failure(error) }
      guard let self, current == self.generation else { return }
      self.task = nil
      self.isRunning = false
      completion(TransformOutcome(entryID: entryID, result: result, sensitive: sensitive))
    }
    return true
  }

  /// Cancels the running transform, if any; its result is dropped.
  public func cancel() {
    task?.cancel()
    task = nil
    generation += 1
    isRunning = false
  }
}
