import XCTest
@testable import AIUsage

@MainActor
final class MenuBarControllerTests: XCTestCase {
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
