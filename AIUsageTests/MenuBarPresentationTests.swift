import XCTest
@testable import AIUsage

final class MenuBarPresentationTests: XCTestCase {
    func testPercentageStaysCompactAndMeaningRemainsAccessible() {
        let presentation = MenuBarPresentation(reading: MenuBarReading(
            provider: .codex,
            percent: 62.4,
            displayMode: .remaining,
            isStale: true,
            showsPlaceholder: false
        ))

        XCTAssertEqual(presentation.valueText, "62%")
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Codex 62 percent left, stale"
        )
        XCTAssertTrue(presentation.showsStaleIndicator)
    }

    func testPinnedProviderWithoutUsageShowsPlaceholder() {
        let presentation = MenuBarPresentation(reading: MenuBarReading(
            provider: .claude,
            percent: nil,
            displayMode: .used,
            isStale: false,
            showsPlaceholder: true
        ))

        XCTAssertEqual(presentation.valueText, "--")
        XCTAssertEqual(presentation.accessibilityLabel, "Claude Code")
    }

    func testAutomaticSelectionWithoutUsageShowsOnlyGauge() {
        let presentation = MenuBarPresentation(reading: MenuBarReading(
            provider: nil,
            percent: nil,
            displayMode: .remaining,
            isStale: false,
            showsPlaceholder: false
        ))

        XCTAssertNil(presentation.valueText)
        XCTAssertEqual(presentation.accessibilityLabel, "AI usage")
    }
}
