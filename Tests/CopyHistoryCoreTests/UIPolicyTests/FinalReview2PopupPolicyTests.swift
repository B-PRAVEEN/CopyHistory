import Foundation
import Testing
@testable import CopyHistoryCore

// Final review 2: FF-L2 (a reload the user did not ask for keeps the selection on the same entry,
// and selects nothing when it is gone) and FF-M2 (Settings can retry a kept pin the flagged-pins
// file could not list).

@Suite struct SelectionAfterReloadTests {
  private let a = UUID(), b = UUID(), c = UUID()

  @Test func followsTheEntryWhenRowsMove() {
    #expect(PopupPolicy.selection(afterReloadOf: b, in: [a, b, c]) == 1)
    #expect(PopupPolicy.selection(afterReloadOf: b, in: [c, a, b]) == 2)  // a row above it was added
    #expect(PopupPolicy.selection(afterReloadOf: c, in: [c]) == 0)       // rows above it went away
  }

  /// The selected row expired: nothing is selected, never the row that slid into its index.
  @Test func goneEntrySelectsNothing() {
    #expect(PopupPolicy.selection(afterReloadOf: b, in: [a, c]) == nil)
    #expect(PopupPolicy.selection(afterReloadOf: b, in: []) == nil)
  }

  @Test func noPreviousSelectionStartsAtTheTop() {
    #expect(PopupPolicy.selection(afterReloadOf: nil, in: [a, b]) == 0)
    #expect(PopupPolicy.selection(afterReloadOf: nil, in: []) == 0)
  }

  /// End to end with a real store: an expiring selected row is purged by the reload.
  @Test func expiredSelectedEntryIsGone() {
    let start = Date()
    let store = HistoryStore(fileURL: nil, purgeInterval: nil, now: { start })
    let keep = store.add(ClipboardEntry(kind: .text, text: "stays"))
    let expiring = store.add(ClipboardEntry(kind: .text, text: "API_KEY=sk-proj-abcdefghjkmnpqrstuvwxyzABCDEFGH",
                                            findings: [SecretFinding(category: .genericSecret, range: 0..<7)],
                                            expiresAt: start.addingTimeInterval(30)))
    let before = store.entries(matching: "").map(\.id)
    #expect(before.contains(expiring.id))
    store.removeExpired(now: start.addingTimeInterval(31))
    let after = store.entries(matching: "").map(\.id)
    #expect(after == [keep.id])
    #expect(PopupPolicy.selection(afterReloadOf: expiring.id, in: after) == nil)
  }
}

@Suite struct UnsavedFlaggedImageRetryTests {
  @Test func retryIsOfferedForEitherKind() {
    #expect(VaultStatus(unsavedFlaggedImageCount: 1).canRetry)
    #expect(VaultStatus(unsavedPinCount: 1).canRetry)
    #expect(!VaultStatus(isReadOnly: true).canRetry)
    #expect(!VaultStatus(isRestoring: true).canRetry)
    #expect(!VaultStatus().canRetry)
  }
}
