import XCTest
@testable import AIUsage

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
}
