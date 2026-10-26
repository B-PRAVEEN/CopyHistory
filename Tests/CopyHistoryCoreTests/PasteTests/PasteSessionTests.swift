import Foundation
import Testing
@testable import CopyHistoryCore

private final class RecordingPasteboard: PasteboardWriting {
  var changeCount = 0
  var contents: [String: Data] = [:]
  var lastClearWasCurrentHostOnly = false
  func clearContents(currentHostOnly: Bool) {
    contents = [:]; changeCount += 1; lastClearWasCurrentHostOnly = currentHostOnly
  }
  func setString(_ string: String, forType type: String) { contents[type] = Data(string.utf8) }
  func setData(_ data: Data, forType type: String) { contents[type] = data }
}

private struct EchoTransform: Transform {
  let id = "echo"
  let title = "Echo"
  func canApply(to text: String) -> Bool { true }
  func apply(to text: String) throws -> String { "plain output" }
}

/// Finishes after `delay` even when cancelled, like a transform thread that cannot be interrupted.
private func slowRunner(_ delay: Duration) -> TransformSession.Runner {
  { _, _ in
    try? await Task.sleep(for: delay)
    return "late output"
  }
}

private func flagged(_ text: String) -> ClipboardEntry {
  ClipboardEntry(kind: .text, text: text, findings: [SecretFinding(category: .genericSecret, range: 0..<text.count)])
}

// MARK: F3 / app M1 — stale paste target

@Suite struct PastePolicyTests {
  @Test func selfFrontmostClearsStaleTarget() {
    let isSelf: (String) -> Bool = { $0 == "CopyHistory" }
    var target = PastePolicy.captureTarget(frontmost: "Slack", isSelf: isSelf)
    #expect(target == "Slack")
    // Settings was used, so CopyHistory is frontmost on the next summon: Slack must not stay the target.
    target = PastePolicy.captureTarget(frontmost: "CopyHistory", isSelf: isSelf)
    #expect(target == nil)
    target = PastePolicy.captureTarget(frontmost: nil, isSelf: isSelf)
    #expect(target == nil)
  }

  @Test func noTargetMeansCopyOnly() {
    #expect(PastePolicy.route(hasTarget: false, accessibilityTrusted: true) == .copyOnly)
    #expect(PastePolicy.route(hasTarget: true, accessibilityTrusted: false) == .copyOnly)
    #expect(PastePolicy.route(hasTarget: true, accessibilityTrusted: true) == .paste)
  }

  @Test func commandVOnlyIntoTheCapturedTarget() {
    #expect(PastePolicy.mayPostPaste(targetPID: 42, frontmostPID: 42))
    #expect(!PastePolicy.mayPostPaste(targetPID: 42, frontmostPID: 7))
    #expect(!PastePolicy.mayPostPaste(targetPID: nil, frontmostPID: 7))
    #expect(!PastePolicy.mayPostPaste(targetPID: 42, frontmostPID: nil))
  }

  // F2: the paste/copy decision for a flagged entry must not depend on re-scanning.
  @Test func flaggedEntriesAreAlwaysSensitive() {
    #expect(PastePolicy.sensitivity(of: flagged("fake-not-detectable")) == true)
    #expect(PastePolicy.sensitivity(of: ClipboardEntry(kind: .text, text: "hello")) == nil)
  }
}

// MARK: F1 / app M8 — hiding cancels; F2 / app H5 — transform output of a flagged entry

@MainActor @Suite struct TransformSessionTests {
  @Test func deliversOutcomeForUncancelledRun() async throws {
    let session = TransformSession(runner: slowRunner(.milliseconds(20)))
    var outcomes: [TransformOutcome] = []
    let entry = ClipboardEntry(kind: .text, text: "abc")
    #expect(session.start(EchoTransform(), on: entry) { outcomes.append($0) })
    #expect(session.isRunning)
    try await Task.sleep(for: .milliseconds(300))
    #expect(outcomes.count == 1)
    #expect(outcomes.first?.entryID == entry.id)
    #expect(try outcomes.first?.result.get() == "late output")
    #expect(outcomes.first?.sensitive == nil)
    #expect(!session.isRunning)
  }

  /// The popup calls `cancel()` from hide(): a run that finishes after dismissal must not paste.
  @Test func cancelOnHideDropsLateResult() async throws {
    let session = TransformSession(runner: slowRunner(.milliseconds(150)))
    var delivered = 0
    #expect(session.start(EchoTransform(), on: ClipboardEntry(kind: .text, text: "abc")) { _ in delivered += 1 })
    session.cancel()
    #expect(!session.isRunning)
    try await Task.sleep(for: .milliseconds(400))
    #expect(delivered == 0)
  }

  /// A cancelled run must also not deliver into a run started afterwards (popup re-summoned).
  @Test func cancelledRunDoesNotDeliverIntoNextRun() async throws {
    let session = TransformSession(runner: slowRunner(.milliseconds(150)))
    var delivered: [UUID] = []
    let first = ClipboardEntry(kind: .text, text: "first")
    let second = ClipboardEntry(kind: .text, text: "second")
    session.start(EchoTransform(), on: first) { delivered.append($0.entryID) }
    session.cancel()
    session.start(EchoTransform(), on: second) { delivered.append($0.entryID) }
    try await Task.sleep(for: .milliseconds(500))
    #expect(delivered == [second.id])
  }

  @Test func refusesSecondRunWhileRunning() {
    let session = TransformSession(runner: slowRunner(.milliseconds(100)))
    let entry = ClipboardEntry(kind: .text, text: "abc")
    #expect(session.start(EchoTransform(), on: entry) { _ in })
    #expect(!session.start(EchoTransform(), on: entry) { _ in })
    #expect(!session.start(EchoTransform(), on: ClipboardEntry(kind: .image, imagePNG: Data([1]))) { _ in })
    session.cancel()
  }

  /// curl with URL credentials is flagged, but its fetch() output hides the password inside
  /// `btoa("admin:…")`, which the detector does not flag. The output must still be written as a secret.
  @Test func transformOutputOfFlaggedEntryIsWrittenAsSecret() async throws {
    let curl = "curl https://admin:fakepass1234@db.example.com/"
    let detector = SecretDetector()
    let entry = ClipboardEntry(kind: .text, text: curl, findings: detector.scan(curl))
    try #require(!entry.findings.isEmpty)

    let session = TransformSession()  // real TransformRunner
    var outcome: TransformOutcome?
    #expect(session.start(CurlToFetch(), on: entry) { outcome = $0 })
    for _ in 0..<100 where outcome == nil { try await Task.sleep(for: .milliseconds(20)) }
    let output = try #require(try outcome?.result.get())
    #expect(output.contains("fakepass1234"))
    #expect(detector.scan(output).isEmpty)  // re-detection alone would miss it
    #expect(outcome?.sensitive == true)

    let pb = RecordingPasteboard()
    var scheduled: [TimeInterval] = []
    let writer = SecretPasteboardWriter(pasteboard: pb, schedule: { delay, _ in scheduled.append(delay) })
    #expect(writer.write(text: output, sensitive: outcome?.sensitive, clearAfter: 2))
    #expect(pb.contents[SecretPasteboardWriter.concealedType] != nil)
    #expect(pb.contents[SecretPasteboardWriter.transientType] != nil)
    #expect(pb.lastClearWasCurrentHostOnly)
    #expect(scheduled == [2])
  }

  /// Any transform of a flagged entry is flagged, whatever the output looks like.
  @Test func anyTransformOfFlaggedEntryIsSensitive() async throws {
    let session = TransformSession(runner: { _, _ in "nothing secret here" })
    var outcome: TransformOutcome?
    session.start(EchoTransform(), on: flagged("fake-flagged-value")) { outcome = $0 }
    for _ in 0..<100 where outcome == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(outcome?.sensitive == true)
  }
}
