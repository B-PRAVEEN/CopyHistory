import Foundation

/// Runs a transform off the caller's thread with a time budget and cancellation.
///
/// Transforms are synchronous, so a run that times out or is cancelled cannot be interrupted: its
/// thread's `RunCancellation` flag is set and its result is discarded. The heavy transforms poll
/// `TransformRunner.isCancelled` (via `CancellationPoll`) in their long loops and then throw, so an
/// abandoned thread exits within milliseconds. Until it exits it keeps holding a slot of `limiter`,
/// so retries cannot pile up threads that each burn a core: once `maxConcurrentRuns` threads are
/// alive, new runs fail with `TransformRunnerError.busy`.
public enum TransformRunner {
  public static let defaultTimeout: TimeInterval = 5
  /// Threads (running or abandoned) allowed at once by the shared limiter.
  public static let maxConcurrentRuns = 2

  /// True inside a transform whose run has timed out or been cancelled; long loops may poll it.
  /// Also true on a helper thread started by `runWithLargeStack` from such a thread.
  public static var isCancelled: Bool { isCancelled(Thread.current) }

  private static func isCancelled(_ t: Thread) -> Bool {
    if t.isCancelled { return true }
    if let flag = t.threadDictionary[flagKey] as? RunCancellation { return flag.isSet }
    if let parent = t.threadDictionary[parentKey] as? Thread { return isCancelled(parent) }
    return false
  }

  /// `threadDictionary` keys: the run's own flag, and the thread a helper inherits it from.
  /// The runner never calls `Thread.cancel()`: a thread cancelled before it begins executing
  /// never runs its body, so the body's `limiter.release()` would never happen.
  private static let flagKey = "CopyHistoryCore.TransformRunner.cancellation"
  private static let parentKey = "CopyHistoryCore.TransformRunner.cancellationParent"

  /// Makes `child` (not yet started) report the calling thread's cancellation as its own.
  static func inheritCancellation(into child: Thread) {
    child.threadDictionary[parentKey] = Thread.current
  }

  /// Counts live transform threads. Tests pass their own instance so their slots stay separate.
  public final class Limiter: @unchecked Sendable {
    public static let shared = Limiter(maxConcurrent: TransformRunner.maxConcurrentRuns)

    private let lock = NSLock()
    private let maxConcurrent: Int
    private var live = 0

    public init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    /// Threads currently holding a slot, including abandoned ones that are still running.
    public var liveCount: Int { lock.lock(); defer { lock.unlock() }; return live }

    func acquire() -> Bool {
      lock.lock(); defer { lock.unlock() }
      guard live < maxConcurrent else { return false }
      live += 1
      return true
    }

    func release() { lock.lock(); live -= 1; lock.unlock() }
  }

  public static func run(_ transform: any Transform, on text: String,
                         timeout: TimeInterval = defaultTimeout,
                         limiter: Limiter = .shared) async throws -> String {
    let once = TransformRunOnce()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        guard once.install(continuation) else { return }
        guard limiter.acquire() else { once.resume(.failure(TransformRunnerError.busy)); return }
        // A dedicated thread, not the cooperative pool: the work blocks for its whole duration.
        // The slot is released when the work really ends, not when the caller stops waiting.
        let thread = Thread {
          defer { limiter.release() }
          once.resume(Result {
            if once.cancellation.isSet { throw CancellationError() }
            return try transform.apply(to: text)
          })
        }
        thread.stackSize = 32 * 1024 * 1024
        thread.threadDictionary[flagKey] = once.cancellation
        thread.start()
        let timer = DispatchWorkItem { once.resume(.failure(TransformError.timedOut)) }
        once.setTimer(timer)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
      }
    } onCancel: {
      once.resume(.failure(CancellationError()))
    }
  }
}

/// Polls `TransformRunner.isCancelled` every `interval` calls, so hot loops pay almost nothing.
struct CancellationPoll {
  private let interval: Int
  private var count = 0

  init(every interval: Int = 4096) { self.interval = interval }

  /// Throws `CancellationError` once the run has been cancelled or has timed out.
  mutating func check() throws {
    count &+= 1
    guard count >= interval else { return }
    count = 0
    if TransformRunner.isCancelled { throw CancellationError() }
  }
}

public enum TransformRunnerError: Error, Equatable, LocalizedError, Sendable {
  /// Too many earlier runs (usually abandoned after a timeout) are still finishing.
  case busy

  public var errorDescription: String? {
    switch self {
    case .busy: return "Still finishing a previous transform; try again in a moment"
    }
  }
}

/// Set once a run is abandoned; read by `TransformRunner.isCancelled` on the worker thread.
final class RunCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var set = false

  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
  func cancel() { lock.lock(); set = true; lock.unlock() }
}

/// Resumes a continuation exactly once, whichever of work, deadline or cancellation comes first.
/// When the deadline or cancellation wins, `cancellation` is set so the worker stops early. The
/// deadline timer is cancelled once a result is in.
final class TransformRunOnce: @unchecked Sendable {
  let cancellation = RunCancellation()
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String, Error>?
  private var timer: DispatchWorkItem?
  private var early: Result<String, Error>?  // cancellation that arrived before `install`
  private var done = false

  /// Returns false when the continuation was already resumed (cancelled before it started).
  func install(_ c: CheckedContinuation<String, Error>) -> Bool {
    lock.lock()
    if let early {
      done = true
      lock.unlock()
      c.resume(with: early)
      return false
    }
    continuation = c
    lock.unlock()
    return true
  }

  /// Cancelled when the result is in (at once if it already is).
  func setTimer(_ t: DispatchWorkItem) {
    lock.lock()
    guard !done else { lock.unlock(); t.cancel(); return }
    timer = t
    lock.unlock()
  }

  func resume(_ result: Result<String, Error>) {
    lock.lock()
    guard !done else { lock.unlock(); return }
    guard let c = continuation else {
      if early == nil { early = result }
      lock.unlock()
      return
    }
    done = true
    continuation = nil
    let t = timer
    timer = nil
    lock.unlock()
    t?.cancel()
    // Harmless when the work itself finished: the thread is about to exit.
    cancellation.cancel()
    c.resume(with: result)
  }
}
