import Foundation
import Testing
@testable import CopyHistoryCore

@MainActor @Suite struct UpdateLifecycleTests {
  @Test func loopEndsWhenTheCheckerIsReleased() async {
    var checker: UpdateChecker? = UpdateChecker(currentVersion: "1.1.0", fetcher: FakeUpdateFetcher(),
                                                store: MemoryUpdateCheckTimeStore(),
                                                sleep: { _ in await Task.yield() })
    checker?.isEnabled = true
    let loop = checker?.loop
    checker = nil
    await loop?.value  // would never finish if the loop outlived its checker
  }

  @Test func ownInternalMarkerAndTheOldOneAreSkipped() {
    #expect(ClipboardMonitor.skippedTypePrefixes.contains(SecretPasteboardWriter.internalType))
    #expect(ClipboardMonitor.skippedTypePrefixes.contains("com.example.copyhistory.internal"))
    #expect(SecretPasteboardWriter.internalType == "io.github.b-praveen.copyhistory.internal")
  }
}
