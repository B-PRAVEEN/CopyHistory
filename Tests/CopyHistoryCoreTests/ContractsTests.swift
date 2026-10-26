import Testing
@testable import CopyHistoryCore

@Test func entryDefaultsAreUnpinnedAndUnflagged() {
  let e = ClipboardEntry(kind: .text, text: "hello")
  #expect(!e.pinned && e.findings.isEmpty && e.copyCount == 1)
}
