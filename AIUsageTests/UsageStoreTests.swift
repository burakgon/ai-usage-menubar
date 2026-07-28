import XCTest
@testable import AIUsage

@MainActor
final class UsageStoreTests: XCTestCase {
    func testTransientFailureRetainsLastGoodAndMarksMetricStale() async {
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
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )
        let item = MenuBarItemID(provider: .claude, metric: .session)

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.states[.claude]?.snapshot, snapshot)
        XCTAssertTrue(store.states[.claude]?.isStale == true)
        XCTAssertEqual(
            store.menuBarReading(for: item),
            MenuBarReading(
                provider: .claude,
                metric: .session,
                value: .percentage(72),
                displayMode: .used,
                isStale: true
            )
        )
    }

    func testAuthenticationFailureClearsLastGoodAndHidesUnavailableMetric() async {
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
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.codex]
            )
        )
        let item = MenuBarItemID(provider: .codex, metric: .session)

        await store.refresh()
        await store.refresh()

        XCTAssertNil(store.states[.codex]?.snapshot)
        XCTAssertNil(store.menuBarReading(for: item))
        XCTAssertEqual(store.availableMenuBarItems(for: .codex), [])
    }

    func testMenuBarReadingsUseExactMetricsInUserOrder() async {
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))]
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )
        let items = [
            MenuBarItemID(provider: .codex, metric: .weekly),
            MenuBarItemID(provider: .claude, metric: .session),
            MenuBarItemID(provider: .claude, metric: .weekly)
        ]

        await store.refresh()

        let readings = store.menuBarReadings(for: items)
        XCTAssertEqual(readings.map(\.provider), [.codex, .claude, .claude])
        XCTAssertEqual(readings.map(\.metric), [.weekly, .session, .weekly])
        XCTAssertEqual(
            readings.map(\.value),
            [.percentage(42), .percentage(20), .percentage(35)]
        )

        let groups = store.menuBarProviderReadings(
            for: [
                MenuBarProviderConfiguration(
                    provider: .codex,
                    metrics: [.weekly]
                ),
                MenuBarProviderConfiguration(
                    provider: .claude,
                    metrics: [.session, .weekly]
                )
            ]
        )
        XCTAssertEqual(groups.map(\.provider), [.codex, .claude])
        XCTAssertEqual(groups[0].readings.map(\.metric), [.weekly])
        XCTAssertEqual(
            groups[1].readings.map(\.metric),
            [.session, .weekly]
        )
    }

    func testExplicitWeeklyMetricNeverFallsBackToSession() async {
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(ProviderSnapshot(
                provider: .codex,
                planName: "Pro",
                windows: [
                    QuotaWindow(
                        kind: .session,
                        usedPercent: 17,
                        resetsAt: nil
                    )
                ],
                fetchedAt: Date()
            ))]
        )
        let store = UsageStore(
            providers: [codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.codex]
            )
        )
        let weekly = MenuBarItemID(provider: .codex, metric: .weekly)

        await store.refresh()

        XCTAssertNil(store.menuBarReading(for: weekly))
        XCTAssertFalse(store.isMenuBarItemAvailable(weekly))
    }

    func testAvailableMetricsComeOnlyFromTheLiveSnapshot() async {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            planName: "Pro",
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: 37,
                    resetsAt: nil
                ),
                QuotaWindow(
                    kind: .sparkSession,
                    usedPercent: 14,
                    resetsAt: nil
                ),
                QuotaWindow(
                    kind: .sparkWeekly,
                    usedPercent: 48,
                    resetsAt: nil
                )
            ],
            billingUsage: .flexCreditBalance(
                remainingCredits: 120,
                usdValue: 4.8
            ),
            fetchedAt: Date()
        )
        let store = UsageStore(
            providers: [
                SequencedProvider(id: .codex, results: [.success(snapshot)])
            ],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.codex]
            )
        )

        await store.refresh()

        XCTAssertEqual(
            store.availableMenuBarItems(for: .codex),
            [
                MenuBarItemID(provider: .codex, metric: .weekly),
                MenuBarItemID(provider: .codex, metric: .spark),
                MenuBarItemID(provider: .codex, metric: .sparkWeekly),
                MenuBarItemID(provider: .codex, metric: .credits)
            ]
        )
        XCTAssertFalse(store.isMenuBarItemAvailable(
            MenuBarItemID(provider: .codex, metric: .session)
        ))
        XCTAssertEqual(
            store.menuBarReading(
                for: MenuBarItemID(provider: .codex, metric: .credits)
            )?.value,
            .credits(remaining: 120, usdValue: 4.8)
        )
    }

    func testMissingToolIsNeitherFetchedNorShown() async {
        let claude = CountingProvider(
            id: .claude,
            result: .success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))
        )
        let codex = CountingProvider(
            id: .codex,
            result: .success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )

        await store.refresh()
        let claudeFetches = await claude.fetchCallCount()
        let codexFetches = await codex.fetchCallCount()

        XCTAssertEqual(claudeFetches, 1)
        XCTAssertEqual(codexFetches, 0)
        XCTAssertTrue(store.isProviderVisibleInDashboard(.claude))
        XCTAssertFalse(store.isProviderVisibleInDashboard(.codex))
        XCTAssertEqual(
            store.menuBarReadings(for: [
                MenuBarItemID(provider: .claude, metric: .session),
                MenuBarItemID(provider: .codex, metric: .session)
            ]).map(\.provider),
            [.claude]
        )
        XCTAssertEqual(
            store.menuBarProviderReadings(
                for: [
                    MenuBarProviderConfiguration(
                        provider: .claude,
                        metrics: [.session]
                    ),
                    MenuBarProviderConfiguration(
                        provider: .codex,
                        metrics: [.session]
                    )
                ]
            ).map(\.provider),
            [.claude]
        )
    }

    func testWeeklyDefaultsRenderOnlyInstalledProviders() async {
        let installCombinations: [Set<ProviderID>] = [
            [],
            [.claude],
            [.codex],
            [.claude, .codex]
        ]

        for installedProviders in installCombinations {
            let claude = CountingProvider(
                id: .claude,
                result: .success(snapshot(
                    provider: .claude,
                    session: 20,
                    weekly: 35
                ))
            )
            let codex = CountingProvider(
                id: .codex,
                result: .success(snapshot(
                    provider: .codex,
                    session: 81,
                    weekly: 42
                ))
            )
            let store = UsageStore(
                providers: [claude, codex],
                availabilityChecker: FixedProviderAvailabilityChecker(
                    installed: installedProviders
                )
            )

            await store.refresh()

            let suiteName =
                "UsageStoreTests.installation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let preferences = AppPreferences(defaults: defaults)
            preferences.configureDefaultMenuBarProviders(
                availableItemsByProvider:
                    store.availableMenuBarItemsByProvider
            )

            XCTAssertEqual(
                preferences.selectedMenuBarMetrics(for: .claude),
                [.weekly]
            )
            XCTAssertEqual(
                preferences.selectedMenuBarMetrics(for: .codex),
                [.weekly]
            )
            XCTAssertEqual(
                store.menuBarProviderReadings(
                    for: preferences.menuBarProviderConfigurations
                ).map(\.provider),
                ProviderID.allCases.filter(installedProviders.contains)
            )
            for provider in ProviderID.allCases {
                XCTAssertEqual(
                    store.isProviderVisibleInDashboard(provider),
                    installedProviders.contains(provider)
                )
            }
            let claudeFetches = await claude.fetchCallCount()
            let codexFetches = await codex.fetchCallCount()
            XCTAssertEqual(
                claudeFetches,
                installedProviders.contains(.claude) ? 1 : 0
            )
            XCTAssertEqual(
                codexFetches,
                installedProviders.contains(.codex) ? 1 : 0
            )

            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testUntrackedProviderIsNeitherFetchedNorShown() async {
        let claude = CountingProvider(
            id: .claude,
            result: .success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))
        )
        let codex = CountingProvider(
            id: .codex,
            result: .success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(),
            trackedProviderIDs: [.claude]
        )

        await store.refresh()
        let claudeFetches = await claude.fetchCallCount()
        let codexFetches = await codex.fetchCallCount()

        XCTAssertEqual(claudeFetches, 1)
        XCTAssertEqual(codexFetches, 0)
        XCTAssertTrue(store.isProviderVisibleInDashboard(.claude))
        XCTAssertFalse(store.isProviderVisibleInDashboard(.codex))
    }

    func testEnablingTrackingRefreshesOnlyTheNewProvider() async {
        let claude = CountingProvider(
            id: .claude,
            result: .success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))
        )
        let codex = CountingProvider(
            id: .codex,
            result: .success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(),
            trackedProviderIDs: [.claude]
        )
        store.start()
        await store.refresh()

        store.setTrackedProviders([.claude, .codex])
        await Task.yield()
        await store.refresh(providerIDs: [.codex])

        let claudeFetches = await claude.fetchCallCount()
        let codexFetches = await codex.fetchCallCount()
        XCTAssertEqual(claudeFetches, 1)
        XCTAssertEqual(codexFetches, 1)
        store.stop()
    }

    func testInstalledButLoggedOutProviderRemainsVisible() async {
        let store = UsageStore(
            providers: [
                SequencedProvider(
                    id: .claude,
                    results: [.failure(ProviderFailure(
                        .authentication,
                        "Not logged in. Run `claude` to authenticate."
                    ))]
                )
            ],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )

        await store.refresh()

        XCTAssertTrue(store.isProviderVisibleInDashboard(.claude))
        XCTAssertEqual(
            store.states[.claude]?.failure?.kind,
            .authentication
        )
        XCTAssertEqual(
            store.menuBarProviderReadings(
                for: [
                    MenuBarProviderConfiguration(
                        provider: .claude,
                        metrics: [.session]
                    )
                ]
            ),
            [
                MenuBarProviderReadings(
                    provider: .claude,
                    selectedMetrics: [.session],
                    readings: []
                )
            ]
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

    private func snapshot(
        provider: ProviderID,
        session: Double,
        weekly: Double
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: [
                QuotaWindow(
                    kind: .session,
                    usedPercent: session,
                    resetsAt: nil
                ),
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: weekly,
                    resetsAt: nil
                )
            ],
            fetchedAt: Date()
        )
    }
}
