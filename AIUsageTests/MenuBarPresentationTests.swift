import AppKit
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

    func testMultipleReadingsKeepProviderValuesAndAccessibilityOrder() {
        let presentation = MenuBarReadingsPresentation(readings: [
            MenuBarReading(
                provider: .claude,
                percent: 62,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: false
            ),
            MenuBarReading(
                provider: .codex,
                percent: 28,
                displayMode: .used,
                isStale: true,
                showsPlaceholder: false
            )
        ])

        XCTAssertEqual(presentation.items.map(\.valueText), ["62%", "28%"])
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Claude Code 62 percent used, Codex 28 percent used, stale"
        )
    }

    @MainActor
    func testMultipleReadingStatusImageUsesTemplateRendering() {
        let readings = [
            MenuBarReading(
                provider: .claude,
                percent: 62,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: false
            ),
            MenuBarReading(
                provider: .codex,
                percent: 28,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: false
            )
        ]

        let image = MenuBarStatusImageRenderer.image(
            for: readings,
            font: NSFont.menuBarFont(ofSize: 0)
        )

        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 50)
        XCTAssertLessThan(image.size.width, 110)
    }
}
