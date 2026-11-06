import AppKit
import XCTest
@testable import AIUsage

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testStatusImageUsesOnlySmallBitmapRepresentations() {
        let image = MenuBarStatusImageRenderer.image(
            for: [statusGroup(percent: 42)],
            font: .menuBarFont(ofSize: 0)
        )

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.representations.count, 2)
        XCTAssertLessThan(image.size.width, 200)
        for representation in image.representations {
            XCTAssertTrue(representation is NSBitmapImageRep)
            XCTAssertLessThan(representation.pixelsWide, 400)
            XCTAssertLessThan(representation.pixelsHigh, 100)
        }
        let bitmap = image.representations.last as! NSBitmapImageRep
        let pixels = UnsafeBufferPointer(
            start: bitmap.bitmapData,
            count: bitmap.bytesPerRow * bitmap.pixelsHigh
        )
        XCTAssertTrue(
            stride(from: 3, to: pixels.count, by: 4)
                .contains { pixels[$0] > 0 }
        )
    }

    private func statusGroup(percent: Double) -> MenuBarProviderReadings {
        MenuBarProviderReadings(
            provider: .codex,
            selectedMetrics: [.weekly],
            readings: [MenuBarReading(
                provider: .codex,
                metric: .weekly,
                value: .percentage(percent),
                displayMode: .used,
                isStale: false
            )]
        )
    }

    func testCloseSuppressesOnlyTheMatchingToggleEvent() {
        var gate = PanelToggleGate()

        gate.panelDidClose()

        XCTAssertTrue(gate.consumeSuppression())
        XCTAssertFalse(gate.consumeSuppression())
    }

    func testOutsideCloseSuppressionCanExpireBeforeAnotherToggle() {
        var gate = PanelToggleGate()

        gate.panelDidClose()
        gate.clearSuppression()

        XCTAssertFalse(gate.consumeSuppression())
    }

    func testSettingsRouteExpandsTheSameCompactMenuBarPanel() {
        XCTAssertEqual(MenuBarPanelRoute.dashboard.width, 392)
        XCTAssertEqual(MenuBarPanelRoute.settings.width, 560)
        XCTAssertGreaterThan(
            MenuBarPanelRoute.settings.width,
            MenuBarPanelRoute.dashboard.width
        )
        XCTAssertLessThan(MenuBarPanelRoute.settings.width, 600)
    }

    func testOpeningPanelActivatesApplicationBeforePresentation() {
        let suiteName = "MenuBarControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let application = RecordingApplicationActivator()
        let controller = MenuBarController(
            store: UsageStore(
                providers: [],
                availabilityChecker: FixedProviderAvailabilityChecker(
                    installed: []
                )
            ),
            preferences: AppPreferences(defaults: defaults),
            launchAtLogin: LaunchAtLoginController(
                service: MenuBarControllerLoginService()
            ),
            updateController: UpdateController(startingUpdater: false),
            application: application
        )

        controller.start()
        controller.showSettings()

        XCTAssertEqual(application.activationCount, 1)

        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class RecordingApplicationActivator:
    ApplicationActivating
{
    private(set) var activationCount = 0

    func activate() {
        activationCount += 1
    }
}

@MainActor
private struct MenuBarControllerLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { .notRegistered }

    func register() throws {}
    func unregister() throws {}
}
