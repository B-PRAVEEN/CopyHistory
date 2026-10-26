import Foundation
import Testing
@testable import CopyHistoryCore

/// Review R-M3: the monitor says which pasteboard generation each delivered entry was read from.
@MainActor @Suite struct ClipboardMonitorChangeCountTests {
  final class Log { var counts: [Int?] = []; var texts: [String?] = [] }

  func make(_ pb: FakePasteboard) -> (ClipboardMonitor, Log) {
    let m = ClipboardMonitor(pasteboard: pb)
    let log = Log()
    m.onCapture = { [unowned m] e, _ in log.counts.append(m.capturingChangeCount); log.texts.append(e.text) }
    return (m, log)
  }

  @Test func deliveredEntryCarriesTheGenerationItWasReadFrom() async {
    let pb = FakePasteboard()
    let (m, log) = make(pb)
    pb.copy("one"); m.poll()
    let first = pb.changeCount
    pb.copy("two")  // a newer copy lands before "one" is delivered
    await m.waitUntilIdle()
    #expect(log.texts == ["one"])
    #expect(log.counts == [first])
    #expect(pb.changeCount != first)
    m.poll()
    await m.waitUntilIdle()
    #expect(log.counts == [first, pb.changeCount])
  }

  @Test func imageEntryCarriesItsGeneration() async {
    let pb = FakePasteboard()
    let (m, log) = make(pb)
    pb.text = nil; pb.image = .png(makeImage(width: 2, height: 2, type: "public.png"))
    pb.types = ["public.png"]; pb.changeCount += 1
    let captured = pb.changeCount
    m.poll()
    await m.waitUntilIdle()
    #expect(log.counts == [captured])
  }

  @Test func generationIsOnlySetDuringDelivery() async {
    let pb = FakePasteboard()
    let (m, _) = make(pb)
    #expect(m.capturingChangeCount == nil)
    pb.copy("x"); m.poll()
    await m.waitUntilIdle()
    #expect(m.capturingChangeCount == nil)
  }
}
