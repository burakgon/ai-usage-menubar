import Foundation
import XCTest
@testable import AIUsage

@MainActor
final class AppPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsMatchProductChoices() {
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.menuBarSelection, .automatic)
        XCTAssertEqual(preferences.menuBarWindow, .session)
        XCTAssertEqual(preferences.usageDisplayMode, .remaining)
        XCTAssertEqual(preferences.refreshInterval, .fiveMinutes)
    }

    func testPreferencesPersistUsingExistingKeys() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.menuBarSelection = .codex
        preferences.menuBarWindow = .weekly
        preferences.usageDisplayMode = .used
        preferences.refreshInterval = .thirtyMinutes

        let restored = AppPreferences(defaults: defaults)

        XCTAssertEqual(restored.menuBarSelection, .codex)
        XCTAssertEqual(restored.menuBarWindow, .weekly)
        XCTAssertEqual(restored.usageDisplayMode, .used)
        XCTAssertEqual(restored.refreshInterval, .thirtyMinutes)
    }

    func testInvalidStoredValuesFallBackSafely() {
        defaults.set("unknown", forKey: "menuBarSelection")
        defaults.set("unknown", forKey: "menuBarWindow")
        defaults.set("unknown", forKey: "usageDisplayMode")
        defaults.set("unknown", forKey: "refreshInterval")

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(preferences.menuBarSelection, .automatic)
        XCTAssertEqual(preferences.menuBarWindow, .session)
        XCTAssertEqual(preferences.usageDisplayMode, .remaining)
        XCTAssertEqual(preferences.refreshInterval, .fiveMinutes)
    }
}
