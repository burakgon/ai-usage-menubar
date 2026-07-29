import Foundation
import XCTest
@testable import AIUsage

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

    @MainActor
    func testFreshInstallDefaultsMatchProductChoices() {
        let preferences = AppPreferences(defaults: defaults)

        XCTAssertEqual(
            preferences.trackedProviderIDs,
            Set(ProviderID.allCases)
        )
        XCTAssertEqual(preferences.visibleMenuBarProviderIDs, [])
        XCTAssertEqual(preferences.menuBarMetricSelections, [:])
        XCTAssertFalse(preferences.hasConfiguredMenuBar)
        XCTAssertFalse(preferences.hasCompletedInitialSetup)
        XCTAssertEqual(preferences.usageDisplayMode, .remaining)
        XCTAssertEqual(preferences.refreshInterval, .fiveMinutes)
    }

    @MainActor
    func testFreshConfigurationPrefersWeeklyPerProvider() {
        let preferences = AppPreferences(defaults: defaults)

        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: availableItemsByProvider
        )

        XCTAssertEqual(
            preferences.visibleMenuBarProviderIDs,
            [.claude, .codex]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly]
        )
        XCTAssertTrue(preferences.hasConfiguredMenuBar)
    }

    @MainActor
    func testFreshConfigurationKeepsWeeklyWhenLiveDataOmitsIt() {
        let preferences = AppPreferences(defaults: defaults)
        let claudeItems = [
            MenuBarItemID(provider: .claude, metric: .session),
            MenuBarItemID(provider: .claude, metric: .fable)
        ]

        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: [.claude: claudeItems]
        )

        XCTAssertEqual(
            preferences.visibleMenuBarProviderIDs,
            [.claude, .codex]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly]
        )
    }

    @MainActor
    func testFreshConfigurationKeepsWeeklyReadyWithNoToolsInstalled() {
        let preferences = AppPreferences(defaults: defaults)

        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: [:]
        )

        XCTAssertEqual(
            preferences.visibleMenuBarProviderIDs,
            [.claude, .codex]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly]
        )
    }

    @MainActor
    func testProviderAndMetricSelectionsPersist() {
        let preferences = AppPreferences(defaults: defaults)
        let claudeItems = availableItemsByProvider[.claude]!

        preferences.setMenuBarMetric(
            true,
            item: claudeItems[1],
            availableItems: claudeItems
        )
        preferences.setMenuBarVisibility(
            true,
            for: .claude,
            availableItems: claudeItems
        )
        preferences.usageDisplayMode = .used
        preferences.refreshInterval = .thirtyMinutes
        preferences.markInitialSetupCompleted()

        let restored = AppPreferences(defaults: defaults)

        XCTAssertEqual(restored.visibleMenuBarProviderIDs, [.claude])
        XCTAssertEqual(
            restored.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
        XCTAssertEqual(restored.usageDisplayMode, .used)
        XCTAssertEqual(restored.refreshInterval, .thirtyMinutes)
        XCTAssertTrue(restored.hasCompletedInitialSetup)
    }

    @MainActor
    func testEnablingProviderWithNoSelectionChoosesFirstLiveMetric() {
        let preferences = AppPreferences(defaults: defaults)
        let codexItems = availableItemsByProvider[.codex]!

        preferences.setMenuBarVisibility(
            true,
            for: .codex,
            availableItems: codexItems
        )

        XCTAssertTrue(preferences.isProviderShownInMenuBar(.codex))
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly]
        )
    }

    @MainActor
    func testTurningOffProviderPreservesMetricSelections() {
        let preferences = AppPreferences(defaults: defaults)
        let claudeItems = availableItemsByProvider[.claude]!

        preferences.setMenuBarVisibility(
            true,
            for: .claude,
            availableItems: claudeItems
        )
        preferences.setMenuBarMetric(
            true,
            item: claudeItems[0],
            availableItems: claudeItems
        )
        preferences.setMenuBarVisibility(
            false,
            for: .claude,
            availableItems: claudeItems
        )

        XCTAssertFalse(preferences.isProviderShownInMenuBar(.claude))
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.session, .weekly]
        )
    }

    @MainActor
    func testTurningOffLastMetricHidesProviderButKeepsTracking() {
        let preferences = AppPreferences(defaults: defaults)
        let claudeItems = availableItemsByProvider[.claude]!
        let weekly = claudeItems[1]

        preferences.setMenuBarVisibility(
            true,
            for: .claude,
            availableItems: claudeItems
        )
        preferences.setMenuBarMetric(
            false,
            item: weekly,
            availableItems: claudeItems
        )

        XCTAssertFalse(preferences.isProviderShownInMenuBar(.claude))
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            []
        )
        XCTAssertTrue(preferences.isTracking(.claude))

        preferences.setMenuBarMetric(
            true,
            item: weekly,
            availableItems: claudeItems
        )

        XCTAssertTrue(preferences.isProviderShownInMenuBar(.claude))
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
    }

    @MainActor
    func testSelectingMetricShowsHiddenProviderAgain() {
        let preferences = AppPreferences(defaults: defaults)
        let codexItems = availableItemsByProvider[.codex]!

        preferences.setMenuBarMetric(
            true,
            item: codexItems[1],
            availableItems: codexItems
        )

        XCTAssertTrue(preferences.isProviderShownInMenuBar(.codex))
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.spark]
        )
    }

    @MainActor
    func testMetricSelectionsUseProviderLiveOrder() {
        let preferences = AppPreferences(defaults: defaults)
        let codexItems = availableItemsByProvider[.codex]!

        preferences.setMenuBarMetric(
            true,
            item: codexItems[2],
            availableItems: codexItems
        )
        preferences.setMenuBarMetric(
            true,
            item: codexItems[0],
            availableItems: codexItems
        )
        preferences.setMenuBarMetric(
            true,
            item: codexItems[1],
            availableItems: codexItems
        )

        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly, .spark, .credits]
        )
    }

    @MainActor
    func testTurningOffTrackingHidesProviderButPreservesMetrics() {
        let preferences = AppPreferences(defaults: defaults)
        let claudeItems = availableItemsByProvider[.claude]!

        preferences.setMenuBarVisibility(
            true,
            for: .claude,
            availableItems: claudeItems
        )
        preferences.setTracking(false, for: .claude)

        XCTAssertFalse(preferences.isProviderShownInMenuBar(.claude))
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
        XCTAssertFalse(preferences.isTracking(.claude))
    }

    @MainActor
    func testV2ItemsMigrateIntoProviderGroupsUsingLiveOrder() throws {
        let oldItems = [
            MenuBarItemID(provider: .codex, metric: .spark),
            MenuBarItemID(provider: .claude, metric: .weekly),
            MenuBarItemID(provider: .claude, metric: .session)
        ]
        defaults.set(
            try JSONEncoder().encode(oldItems),
            forKey: "menuBarItems.v2"
        )
        defaults.set(true, forKey: "menuBarItemsConfigured.v2")

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertFalse(preferences.hasConfiguredMenuBar)

        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: availableItemsByProvider
        )

        XCTAssertEqual(
            preferences.visibleMenuBarProviderIDs,
            [.claude, .codex]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.session, .weekly]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.spark]
        )
        XCTAssertEqual(
            preferences.menuBarProviderConfigurations.map(\.provider),
            [.claude, .codex]
        )
    }

    @MainActor
    func testUnavailableV2MetricFallsBackToFirstLiveMetric() throws {
        let oldItems = [
            MenuBarItemID(provider: .codex, metric: .session)
        ]
        defaults.set(
            try JSONEncoder().encode(oldItems),
            forKey: "menuBarItems.v2"
        )
        defaults.set(true, forKey: "menuBarItemsConfigured.v2")

        let preferences = AppPreferences(defaults: defaults)
        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: availableItemsByProvider
        )

        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly]
        )
        XCTAssertTrue(preferences.isProviderShownInMenuBar(.codex))
    }

    @MainActor
    func testV2SelectionSurvivesMigrationWhileToolIsNotInstalled() throws {
        let oldItems = [
            MenuBarItemID(provider: .codex, metric: .credits)
        ]
        defaults.set(
            try JSONEncoder().encode(oldItems),
            forKey: "menuBarItems.v2"
        )
        defaults.set(true, forKey: "menuBarItemsConfigured.v2")

        let preferences = AppPreferences(defaults: defaults)
        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: [
                .claude: availableItemsByProvider[.claude]!
            ]
        )

        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.credits]
        )
        XCTAssertTrue(preferences.isProviderShownInMenuBar(.codex))
    }

    @MainActor
    func testLegacyReleaseCanSkipVersionsAndStillGetsWeeklyForBoth() {
        defaults.set("codex", forKey: "menuBarSelection")
        defaults.set("session", forKey: "menuBarWindow")

        let preferences = AppPreferences(defaults: defaults)
        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: [:]
        )

        XCTAssertEqual(
            preferences.visibleMenuBarProviderIDs,
            [.claude, .codex]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly]
        )
    }

    @MainActor
    func testLaterUpdatesPreserveTheUsersExactMenuBarChoices() {
        let firstRun = AppPreferences(defaults: defaults)
        firstRun.configureDefaultMenuBarProviders(
            availableItemsByProvider: availableItemsByProvider
        )

        let claudeItems = availableItemsByProvider[.claude]!
        let codexItems = availableItemsByProvider[.codex]!
        firstRun.setMenuBarMetric(
            true,
            item: claudeItems[0],
            availableItems: claudeItems
        )
        firstRun.setMenuBarMetric(
            false,
            item: claudeItems[1],
            availableItems: claudeItems
        )
        firstRun.setMenuBarMetric(
            false,
            item: codexItems[0],
            availableItems: codexItems
        )

        for _ in 0..<2 {
            let afterUpdate = AppPreferences(defaults: defaults)
            afterUpdate.configureDefaultMenuBarProviders(
                availableItemsByProvider: [:]
            )

            XCTAssertEqual(
                afterUpdate.visibleMenuBarProviderIDs,
                [.claude]
            )
            XCTAssertEqual(
                afterUpdate.selectedMenuBarMetrics(for: .claude),
                [.session]
            )
            XCTAssertEqual(
                afterUpdate.selectedMenuBarMetrics(for: .codex),
                []
            )
        }
    }

    @MainActor
    func testNewProvidersAreSeededOnceWithoutUndoingOptOuts() throws {
        defaults.set(
            try JSONEncoder().encode([ProviderID.claude]),
            forKey: "trackedProviderIDs.v1"
        )

        let firstUpdatedRun = AppPreferences(defaults: defaults)
        XCTAssertEqual(
            firstUpdatedRun.trackedProviderIDs,
            [.claude, .cursor, .antigravity, .copilot, .devin, .grok]
        )

        firstUpdatedRun.setTracking(false, for: .grok)
        let laterRun = AppPreferences(defaults: defaults)

        XCTAssertFalse(laterRun.isTracking(.grok))
        XCTAssertTrue(laterRun.isTracking(.cursor))
    }

    @MainActor
    func testInvalidStoredScalarValuesFallBackSafely() {
        defaults.set("unknown", forKey: "menuBarSelection")
        defaults.set("unknown", forKey: "menuBarWindow")
        defaults.set("unknown", forKey: "usageDisplayMode")
        defaults.set("unknown", forKey: "refreshInterval")

        let preferences = AppPreferences(defaults: defaults)
        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: availableItemsByProvider
        )

        XCTAssertEqual(preferences.usageDisplayMode, .remaining)
        XCTAssertEqual(preferences.refreshInterval, .fiveMinutes)
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .claude),
            [.weekly]
        )
        XCTAssertEqual(
            preferences.selectedMenuBarMetrics(for: .codex),
            [.weekly]
        )
    }

    private var availableItemsByProvider:
        [ProviderID: [MenuBarItemID]] {
        [
            .claude: [
                MenuBarItemID(provider: .claude, metric: .session),
                MenuBarItemID(provider: .claude, metric: .weekly),
                MenuBarItemID(provider: .claude, metric: .fable)
            ],
            .codex: [
                MenuBarItemID(provider: .codex, metric: .weekly),
                MenuBarItemID(provider: .codex, metric: .spark),
                MenuBarItemID(provider: .codex, metric: .credits)
            ]
        ]
    }
}
