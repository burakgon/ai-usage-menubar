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
        let store = UsageStore(providers: [claude])

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
        let store = UsageStore(providers: [codex])

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
        let store = UsageStore(providers: [claude, codex])

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

    func testPinnedCodexUsesTheExplicitlySelectedPeriod() async {
        let weeklyOnly = ProviderSnapshot(
            provider: .codex,
            planName: "Pro",
            windows: [
                QuotaWindow(kind: .weekly, usedPercent: 43, resetsAt: nil),
                QuotaWindow(kind: .sparkWeekly, usedPercent: 12, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        let store = UsageStore(providers: [
            SequencedProvider(id: .codex, results: [.success(weeklyOnly)])
        ])

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

    func testRefreshIntervalCanBeChangedWithoutRecreatingTheStore() {
        let store = UsageStore(providers: [])

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

    private func snapshot(provider: ProviderID, percent: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: [QuotaWindow(kind: .session, usedPercent: percent, resetsAt: nil)],
            fetchedAt: Date()
        )
    }
}
