import XCTest
@testable import AIUsage

@MainActor
final class UsageStoreTests: XCTestCase {
    func testTransientFailureRetainsLastGoodAndMarksItStale() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planName: "Pro",
            windows: [QuotaWindow(kind: .session, usedPercent: 72, resetsAt: nil)],
            fetchedAt: now
        )
        let claude = SequencedProvider(
            id: .claude,
            results: [
                .success(snapshot),
                .failure(ProviderFailure(.transient, "Offline"))
            ]
        )
        let store = UsageStore(
            providers: [claude],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.states[.claude]?.snapshot, snapshot)
        XCTAssertTrue(store.states[.claude]?.isStale == true)
        XCTAssertEqual(
            store.menuBarReading(for: .automatic),
            MenuBarReading(
                provider: .claude,
                percent: 72,
                displayMode: .used,
                isStale: true,
                showsPlaceholder: false
            )
        )
    }

    func testAuthenticationFailureClearsLastGood() async {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            planName: nil,
            windows: [QuotaWindow(kind: .session, usedPercent: 18, resetsAt: nil)],
            fetchedAt: Date()
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [
                .success(snapshot),
                .failure(ProviderFailure(.authentication, "Logged out"))
            ]
        )
        let store = UsageStore(
            providers: [codex],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()
        await store.refresh()

        XCTAssertNil(store.states[.codex]?.snapshot)
        XCTAssertEqual(
            store.menuBarReading(for: .codex),
            MenuBarReading(
                provider: .codex,
                percent: nil,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: true
            )
        )
    }

    func testAutomaticIndicatorChoosesHighestAvailableSession() async {
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(snapshot(provider: .claude, percent: 20))]
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(snapshot(provider: .codex, percent: 81))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()

        XCTAssertEqual(store.menuBarReading(for: .automatic).percent, 81)
        XCTAssertEqual(store.menuBarReading(for: .automatic).provider, .codex)
        XCTAssertEqual(store.menuBarReading(for: .claude).percent, 20)
        XCTAssertEqual(
            store.menuBarReading(
                for: .automatic,
                window: .session,
                displayMode: .remaining
            ),
            MenuBarReading(
                provider: .codex,
                percent: 19,
                displayMode: .remaining,
                isStale: false,
                showsPlaceholder: false
            )
        )
    }

    func testAllSelectionReturnsEveryAvailableProviderInStableOrder() async {
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(snapshot(provider: .claude, percent: 20))]
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(snapshot(provider: .codex, percent: 81))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()

        XCTAssertEqual(
            store.menuBarReadings(for: .all),
            [
                MenuBarReading(
                    provider: .claude,
                    percent: 20,
                    displayMode: .used,
                    isStale: false,
                    showsPlaceholder: false
                ),
                MenuBarReading(
                    provider: .codex,
                    percent: 81,
                    displayMode: .used,
                    isStale: false,
                    showsPlaceholder: false
                )
            ]
        )
    }

    func testAllSelectionOmitsUnavailableProviders() async {
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(snapshot(provider: .claude, percent: 20))]
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(snapshot(provider: .codex, percent: 81))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )

        await store.refresh()

        XCTAssertEqual(
            store.menuBarReadings(for: .all).map(\.provider),
            [.claude]
        )
    }

    func testPinnedCodexFallsBackToAvailableWeeklyPeriod() async {
        let weeklyOnly = ProviderSnapshot(
            provider: .codex,
            planName: "Pro",
            windows: [
                QuotaWindow(kind: .weekly, usedPercent: 43, resetsAt: nil),
                QuotaWindow(kind: .sparkWeekly, usedPercent: 12, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        let store = UsageStore(
            providers: [
                SequencedProvider(
                    id: .codex,
                    results: [.success(weeklyOnly)]
                )
            ],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()

        XCTAssertEqual(
            store.menuBarReading(for: .codex),
            MenuBarReading(
                provider: .codex,
                percent: 43,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: false
            )
        )
        XCTAssertEqual(
            store.menuBarReading(for: .codex, window: .weekly),
            MenuBarReading(
                provider: .codex,
                percent: 43,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: false
            )
        )
    }

    func testPinnedProviderPrefersTheExactSelectedPeriod() async {
        let store = UsageStore(
            providers: [
                SequencedProvider(
                    id: .codex,
                    results: [.success(ProviderSnapshot(
                        provider: .codex,
                        planName: "Pro",
                        windows: [
                            QuotaWindow(
                                kind: .session,
                                usedPercent: 17,
                                resetsAt: nil
                            ),
                            QuotaWindow(
                                kind: .weekly,
                                usedPercent: 43,
                                resetsAt: nil
                            )
                        ],
                        fetchedAt: Date()
                    ))]
                )
            ],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()

        XCTAssertEqual(store.menuBarReading(for: .codex).percent, 17)
        XCTAssertEqual(
            store.menuBarReading(for: .codex, window: .weekly).percent,
            43
        )
    }

    func testPinnedProviderFallsBackFromWeeklyToSession() async {
        let store = UsageStore(
            providers: [
                SequencedProvider(
                    id: .codex,
                    results: [.success(snapshot(provider: .codex, percent: 17))]
                )
            ],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()

        XCTAssertEqual(
            store.menuBarReading(for: .codex, window: .weekly),
            MenuBarReading(
                provider: .codex,
                percent: 17,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: false
            )
        )
    }

    func testPinnedProviderShowsPlaceholderWithoutPrimaryWindows() async {
        let store = UsageStore(
            providers: [
                SequencedProvider(
                    id: .codex,
                    results: [.success(ProviderSnapshot(
                        provider: .codex,
                        planName: "Pro",
                        windows: [
                            QuotaWindow(
                                kind: .sparkWeekly,
                                usedPercent: 12,
                                resetsAt: nil
                            )
                        ],
                        fetchedAt: Date()
                    ))]
                )
            ],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()

        XCTAssertEqual(
            store.menuBarReading(for: .codex),
            MenuBarReading(
                provider: .codex,
                percent: nil,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: true
            )
        )
    }

    func testAutomaticIndicatorDoesNotFallbackAcrossPeriods() async {
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(snapshot(provider: .claude, percent: 20))]
        )
        let weeklyCodex = ProviderSnapshot(
            provider: .codex,
            planName: "Pro",
            windows: [
                QuotaWindow(kind: .weekly, usedPercent: 81, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(weeklyCodex)]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        await store.refresh()

        XCTAssertEqual(
            store.menuBarReading(for: .automatic, window: .session),
            MenuBarReading(
                provider: .claude,
                percent: 20,
                displayMode: .used,
                isStale: false,
                showsPlaceholder: false
            )
        )
    }

    func testRefreshIntervalCanBeChangedWithoutRecreatingTheStore() {
        let store = UsageStore(
            providers: [],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        XCTAssertEqual(store.refreshInterval, .fiveMinutes)

        store.setRefreshInterval(.thirtyMinutes)

        XCTAssertEqual(store.refreshInterval, .thirtyMinutes)
    }

    func testRemainingUsageIsBoundedToARealPercentage() {
        XCTAssertEqual(
            UsageDisplayMode.remaining.displayedPercent(from: 62),
            38
        )
        XCTAssertEqual(
            UsageDisplayMode.remaining.displayedPercent(from: 140),
            0
        )
        XCTAssertEqual(
            UsageDisplayMode.remaining.displayedPercent(from: -10),
            100
        )
    }

    func testRemainingUsageIsTheFirstAndDefaultDisplayOption() {
        XCTAssertEqual(UsageDisplayMode.defaultSelection, .remaining)
        XCTAssertEqual(UsageDisplayMode.allCases, [.remaining, .used])
    }

    func testToolAvailabilityIsIndependentFromLoginStatus() async {
        let store = UsageStore(
            providers: [
                SequencedProvider(
                    id: .claude,
                    results: [.failure(ProviderFailure(
                        .authentication,
                        "Not logged in. Run `claude` to authenticate."
                    ))]
                ),
                SequencedProvider(
                    id: .codex,
                    results: [.failure(ProviderFailure(
                        .authentication,
                        "Not logged in. Run `codex` to authenticate."
                    ))]
                )
            ],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )

        await store.refresh()

        XCTAssertTrue(store.states[.claude]?.isVisibleInDashboard == true)
        XCTAssertEqual(
            store.states[.claude]?.failure?.message,
            "Not logged in. Run `claude` to authenticate."
        )
        XCTAssertTrue(store.states[.codex]?.isVisibleInDashboard == false)
    }

    private func snapshot(provider: ProviderID, percent: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: [QuotaWindow(kind: .session, usedPercent: percent, resetsAt: nil)],
            fetchedAt: Date()
        )
    }
}
