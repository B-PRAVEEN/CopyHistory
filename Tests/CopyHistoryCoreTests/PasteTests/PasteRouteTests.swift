import Testing
@testable import CopyHistoryCore

@Suite struct PasteRouteTests {
  /// Every combination: ⌘V is posted only with both a target and Accessibility.
  @Test(arguments: [(false, false, PasteRoute.copyOnly), (false, true, .copyOnly),
                    (true, false, .copyOnly), (true, true, .paste)])
  func routeTable(hasTarget: Bool, trusted: Bool, expected: PasteRoute) {
    #expect(PastePolicy.route(hasTarget: hasTarget, accessibilityTrusted: trusted) == expected)
  }
}
