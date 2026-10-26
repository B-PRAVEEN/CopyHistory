import Foundation
import Testing
@testable import CopyHistoryCore

final class FakePasteboardWriter: PasteboardWriting {
  var changeCount = 0
  var contents: [String: Data] = [:]
  var writeOrder: [String] = []
  var lastClearWasCurrentHostOnly = false
  func clearContents(currentHostOnly: Bool) {
    contents = [:]; writeOrder = []; changeCount += 1; lastClearWasCurrentHostOnly = currentHostOnly
  }
  func setString(_ string: String, forType type: String) { contents[type] = Data(string.utf8); writeOrder.append(type) }
  func setData(_ data: Data, forType type: String) { contents[type] = data; writeOrder.append(type) }
}

@MainActor @Suite struct SecretPasteboardWriterTests {
  static let fakeSecret = "sk-proj-FAKEFAKEFAKEFAKEFAKE1234"

  func make() -> (SecretPasteboardWriter, FakePasteboardWriter, () -> [(TimeInterval, @MainActor () -> Void)]) {
    let pb = FakePasteboardWriter()
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
    let w = SecretPasteboardWriter(pasteboard: pb, schedule: { scheduled.append(($0, $1)) })
    return (w, pb, { scheduled })
  }

  @Test func secretsAreConcealedTransientLocalAndCleared() {
    let (w, pb, scheduled) = make()
    #expect(w.write(text: Self.fakeSecret, clearAfter: 2))
    #expect(pb.contents["public.utf8-plain-text"] == Data(Self.fakeSecret.utf8))
    #expect(pb.contents[SecretPasteboardWriter.concealedType] != nil)
    #expect(pb.contents[SecretPasteboardWriter.transientType] != nil)
    #expect(pb.contents[SecretPasteboardWriter.internalType] != nil)
    #expect(pb.lastClearWasCurrentHostOnly)
    // Markers must already be present when the payload appears.
    #expect(pb.writeOrder.last == "public.utf8-plain-text")
    #expect(scheduled().map(\.0) == [2])
    scheduled()[0].1()
    #expect(pb.contents.isEmpty)
  }

  @Test func clearSkippedIfUserCopiedSomethingElse() {
    let (w, pb, scheduled) = make()
    w.write(text: Self.fakeSecret, clearAfter: 2)
    pb.clearContents(currentHostOnly: false); pb.setString("user's new copy", forType: "public.utf8-plain-text")
    scheduled()[0].1()
    #expect(pb.contents["public.utf8-plain-text"] == Data("user's new copy".utf8))
  }

  @Test func explicitSensitiveFlagMarksUndetectedText() {
    let (w, pb, scheduled) = make()
    #expect(w.write(text: "btoa(\"user:pass\")", sensitive: true, clearAfter: 30))
    #expect(pb.contents[SecretPasteboardWriter.concealedType] != nil)
    #expect(scheduled().count == 1)
  }

  @Test func ordinaryTextAndImagesAreNotMarkedOrCleared() {
    let (w, pb, scheduled) = make()
    #expect(!w.write(text: "hello world", clearAfter: 2))
    #expect(pb.contents[SecretPasteboardWriter.concealedType] == nil)
    #expect(pb.contents[SecretPasteboardWriter.transientType] == nil)
    #expect(pb.contents[SecretPasteboardWriter.internalType] != nil)
    #expect(!pb.lastClearWasCurrentHostOnly)
    w.write(png: Data([1, 2]))
    #expect(pb.contents["public.png"] == Data([1, 2]))
    #expect(pb.contents[SecretPasteboardWriter.concealedType] == nil)
    #expect(scheduled().isEmpty)
  }

  /// An image flagged through its recognised text is concealed, local-only and cleared like secret text.
  @Test func sensitiveImagesAreConcealedTransientLocalAndCleared() {
    let (w, pb, scheduled) = make()
    w.write(png: Data([1, 2]), sensitive: true, clearAfter: 2)
    #expect(pb.contents["public.png"] == Data([1, 2]))
    #expect(pb.contents[SecretPasteboardWriter.concealedType] != nil)
    #expect(pb.contents[SecretPasteboardWriter.transientType] != nil)
    #expect(pb.lastClearWasCurrentHostOnly)
    #expect(pb.writeOrder.last == "public.png")
    #expect(scheduled().map(\.0) == [2])
    scheduled()[0].1()
    #expect(pb.contents.isEmpty)
  }

  /// Text too long to scan on the main thread is written as a secret instead of being scanned.
  @Test func oversizedUnscannedTextFailsClosedWithoutScanning() {
    let (w, pb, scheduled) = make()
    let big = String(repeating: "a\u{301}", count: SecretDetector.maxScanLength)  // > cap in UTF-16 units
    let start = DispatchTime.now().uptimeNanoseconds
    #expect(w.write(text: big, clearAfter: 30))
    #expect(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 < 1)
    #expect(pb.contents[SecretPasteboardWriter.concealedType] != nil)
    #expect(scheduled().map(\.0) == [30])
    // Just under the cap is still scanned normally.
    #expect(!w.write(text: String(repeating: "a", count: 1000), clearAfter: 30))
  }

  /// Large ordinary output (e.g. a 600 KB table) ends up as ordinary text once the background
  /// scan finds nothing: not concealed and not cleared (review R10).
  @Test func oversizedCleanTextIsDowngradedAfterBackgroundScan() async {
    let (w, pb, scheduled) = make()
    let big = String(repeating: "| col a | col b |\n", count: 40_000)
    #expect(big.utf16.count > SecretDetector.maxScanLength)
    #expect(w.write(text: big, clearAfter: 2))  // fail closed at first
    await w.largeScan?.value
    #expect(pb.contents[SecretPasteboardWriter.concealedType] == nil)
    #expect(pb.contents["public.utf8-plain-text"] == Data(big.utf8))
    #expect(!pb.lastClearWasCurrentHostOnly)
    for (_, clear) in scheduled() { clear() }
    #expect(pb.contents["public.utf8-plain-text"] == Data(big.utf8))
  }

  @Test func oversizedTextWithASecretStaysConcealed() async {
    let (w, pb, scheduled) = make()
    let big = String(repeating: "row\n", count: 140_000) + "Authorization: Bearer FAKEtoken1234FAKEtoken5678\n"
    #expect(w.write(text: big, clearAfter: 2))
    await w.largeScan?.value
    #expect(pb.contents[SecretPasteboardWriter.concealedType] != nil)
    scheduled()[0].1()
    #expect(pb.contents.isEmpty)
  }

  @Test func backgroundScanNeverOverwritesALaterCopy() async {
    let (w, pb, _) = make()
    let big = String(repeating: "plain text ", count: 60_000)
    w.write(text: big, clearAfter: 2)
    pb.clearContents(currentHostOnly: false); pb.setString("user's new copy", forType: "public.utf8-plain-text")
    await w.largeScan?.value
    #expect(pb.contents["public.utf8-plain-text"] == Data("user's new copy".utf8))
  }
}
