import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

@MainActor
final class VisualSnapshotTests: XCTestCase {
    private let panelWidth: CGFloat = 392

    func testProviderIconsAreTemplateImagesAtMenuBarSize() {
        for provider in ProviderID.allCases {
            let image = ProviderIcon.templateImage(for: provider, size: 15)

            XCTAssertEqual(image.size.width, 15)
            XCTAssertEqual(image.size.height, 15)
            XCTAssertTrue(image.isTemplate)
        }
    }

    func testUsagePaletteAdaptsToLightAndDarkAppearances() {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark

        let colors: [(String, Color)] = [
            ("accent", UsagePalette.accent),
            ("normalUsage", UsagePalette.normalUsage),
            ("success", UsagePalette.success),
            ("warning", UsagePalette.warning),
            ("critical", UsagePalette.critical)
        ]

        for (name, color) in colors {
            let lightValue = color.resolve(in: light)
            let darkValue = color.resolve(in: dark)

            XCTAssertNotEqual(
                lightValue,
                darkValue,
                "\(name) must use the system's appearance-aware variant"
            )
            XCTAssertEqual(lightValue.opacity, 1, accuracy: 0.001)
            XCTAssertEqual(darkValue.opacity, 1, accuracy: 0.001)
        }
    }

    func testRefreshFeedbackStaysInsideTheFooterButton() {
        let idleSize = measuredSize(
            of: RefreshButtonLabel(isRefreshing: false),
            width: 100
        )
        let refreshingSize = measuredSize(
            of: RefreshButtonLabel(isRefreshing: true),
            width: 100
        )
        let settingsSize = measuredSize(
            of: SettingsButtonLabel(),
            width: 100
        )

        XCTAssertEqual(idleSize, refreshingSize)
        XCTAssertEqual(idleSize, settingsSize)
        XCTAssertEqual(idleSize.width, RefreshButtonLabel.size, accuracy: 0.5)
        XCTAssertEqual(idleSize.height, RefreshButtonLabel.size, accuracy: 0.5)
    }

    func testMenuBarLabelKeepsUsageMeaningOutOfVisibleText() {
        for displayMode in UsageDisplayMode.allCases {
            let size = measuredSize(
                of: MenuBarProviderLabelView(
                    group: MenuBarProviderReadings(
                        provider: .codex,
                        selectedMetrics: [.weekly],
                        readings: [
                            MenuBarReading(
                                provider: .codex,
                                metric: .weekly,
                                value: .percentage(62),
                                displayMode: displayMode,
                                isStale: false
                            )
                        ]
                    )
                ),
                width: 200
            )

            XCTAssertLessThan(size.width, 75)
        }
    }

    func testDashboardFitsCompactPanelInLightAndDark() async {
        let store = await makePopulatedStore()
        let configurations: [(ColorScheme, Bool)] = [
            (.light, false),
            (.dark, false),
            (.light, true)
        ]

        for (colorScheme, reducesTransparency) in configurations {
            let view = DashboardView(
                store: store,
                launchAtLogin: LaunchAtLoginController(service: SnapshotLoginService()),
                usageDisplayMode: .constant(.used),
                refreshInterval: .constant(.fiveMinutes),
                availableUpdateVersion: nil,
                isCheckingForUpdates: false
            )
            .environment(\.colorScheme, colorScheme)
            .environment(\._accessibilityReduceTransparency, reducesTransparency)

            let size = measuredSize(of: view, width: panelWidth)
            XCTAssertEqual(size.width, panelWidth, accuracy: 0.5)
            XCTAssertLessThan(size.height, 500)
            XCTAssertGreaterThan(size.height, 250)
        }
    }

    func testDashboardStaysCompactWithRemainingUsageAndUpdateAction() async {
        let store = await makePopulatedStore()
        let view = DashboardView(
            store: store,
            launchAtLogin: LaunchAtLoginController(service: SnapshotLoginService()),
            usageDisplayMode: .constant(.remaining),
            refreshInterval: .constant(.fifteenMinutes),
            availableUpdateVersion: "0.2.0",
            isCheckingForUpdates: false
        )
        .environment(\.colorScheme, .dark)

        let size = measuredSize(of: view, width: panelWidth)

        XCTAssertEqual(size.width, panelWidth, accuracy: 0.5)
        XCTAssertLessThan(size.height, 500)
        XCTAssertGreaterThan(size.height, 250)
    }

    func testSettingsShowsEveryProviderInLightAndDark() async {
        let store = await makeFullyPopulatedStore()
        let suiteName = "VisualSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = AppPreferences(defaults: defaults)
        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: store.availableMenuBarItemsByProvider
        )

        for colorScheme in [ColorScheme.light, .dark] {
            let view = SettingsView(
                store: store,
                preferences: preferences,
                launchAtLogin: LaunchAtLoginController(
                    service: SnapshotLoginService()
                ),
                updateController: UpdateController(startingUpdater: false)
            )
            .environment(\.colorScheme, colorScheme)

            let width = MenuBarPanelRoute.settings.width
            let size = measuredSize(of: view, width: width)
            XCTAssertEqual(size.width, width, accuracy: 0.5)
            XCTAssertLessThan(size.height, 720)
            XCTAssertGreaterThan(size.height, 620)
        }

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testProviderSurfaceKeepsOddQuotaCountCompact() {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planName: "Pro",
            windows: [
                QuotaWindow(kind: .session, usedPercent: 28, resetsAt: Date().addingTimeInterval(3_600)),
                QuotaWindow(kind: .weekly, usedPercent: 52, resetsAt: Date().addingTimeInterval(86_400)),
                QuotaWindow(kind: .sonnet, usedPercent: 76, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        let state = ProviderState(provider: .claude, snapshot: snapshot)
        let size = measuredSize(of: ProviderSectionView(state: state), width: panelWidth - 20)

        XCTAssertEqual(size.width, panelWidth - 20, accuracy: 0.5)
        XCTAssertLessThan(size.height, 200)
        XCTAssertGreaterThan(size.height, 130)
    }

    func testBillingUsagePresentationKeepsProviderSemanticsDistinct() {
        let locale = Locale(identifier: "en_US")
        let bounded = BillingUsage.boundedSpend(
            usedAmount: 5,
            limitAmount: 10,
            currencyCode: "USD"
        )
        let used = BillingUsagePresentation(
            usage: bounded,
            displayMode: .used,
            locale: locale
        )
        let remaining = BillingUsagePresentation(
            usage: bounded,
            displayMode: .remaining,
            locale: locale
        )
        let uncapped = BillingUsagePresentation(
            usage: .unboundedSpend(
                usedAmount: 1234.56,
                currencyCode: "USD"
            ),
            displayMode: .remaining,
            locale: locale
        )
        let credits = BillingUsagePresentation(
            usage: .flexCreditBalance(
                remainingCredits: 820,
                usdValue: 32.8
            ),
            displayMode: .used,
            locale: locale
        )

        XCTAssertEqual(used.title, "Extra usage")
        XCTAssertEqual(used.valueText, "$5.00 / $10.00 spent")
        XCTAssertEqual(remaining.valueText, "$5.00 / $10.00 left")
        XCTAssertEqual(uncapped.valueText, "$1,234.56 spent")
        XCTAssertEqual(credits.title, "Credits")
        XCTAssertEqual(credits.valueText, "$32.80 · 820 credits left")
        XCTAssertTrue(credits.accessibilityValue.contains("remaining"))
    }

    func testProviderLoadingAndTransientFailureStatesStayInsideOneCompactSurface() {
        var loadingState = ProviderState(provider: .claude)
        loadingState.isRefreshing = true
        let loadingSize = measuredSize(
            of: ProviderSectionView(state: loadingState),
            width: panelWidth - 20
        )

        let failureState = ProviderState(
            provider: .codex,
            failure: ProviderFailure(.transient, "Codex could not be reached.")
        )
        let failureSize = measuredSize(
            of: ProviderSectionView(state: failureState),
            width: panelWidth - 20
        )

        XCTAssertLessThan(loadingSize.height, 110)
        XCTAssertLessThan(failureSize.height, 120)
        XCTAssertGreaterThan(loadingSize.height, 55)
        XCTAssertGreaterThan(failureSize.height, 55)
    }

    func testToolAvailabilityControlsVisibilityIndependentlyOfLogin() {
        let missingTool = ProviderState(
            provider: .claude,
            failure: ProviderFailure(.authentication, "Not logged in."),
            isToolInstalled: false
        )
        let loggedOut = ProviderState(
            provider: .codex,
            failure: ProviderFailure(.authentication, "Not logged in."),
            isToolInstalled: true
        )

        XCTAssertFalse(missingTool.isVisibleInDashboard)
        XCTAssertTrue(loggedOut.isVisibleInDashboard)
    }

    private func makePopulatedStore() async -> UsageStore {
        let now = Date()
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(ProviderSnapshot(
                provider: .claude,
                planName: "Pro 20x",
                windows: [
                    QuotaWindow(
                        kind: .session,
                        usedPercent: 62,
                        resetsAt: now.addingTimeInterval(2_400)
                    ),
                    QuotaWindow(
                        kind: .weekly,
                        usedPercent: 37,
                        resetsAt: now.addingTimeInterval(172_800)
                    ),
                    QuotaWindow(
                        kind: .sonnet,
                        usedPercent: 86,
                        resetsAt: now.addingTimeInterval(259_200)
                    ),
                    QuotaWindow(
                        kind: .fable,
                        usedPercent: 14,
                        resetsAt: now.addingTimeInterval(345_600)
                    )
                ],
                billingUsage: .boundedSpend(
                    usedAmount: 5,
                    limitAmount: 10,
                    currencyCode: "USD"
                ),
                fetchedAt: now
            ))]
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(ProviderSnapshot(
                provider: .codex,
                planName: "Pro 5x",
                windows: [
                    QuotaWindow(
                        kind: .session,
                        usedPercent: 28,
                        resetsAt: now.addingTimeInterval(7_200)
                    ),
                    QuotaWindow(
                        kind: .weekly,
                        usedPercent: 74,
                        resetsAt: now.addingTimeInterval(345_600)
                    ),
                    QuotaWindow(
                        kind: .sparkSession,
                        usedPercent: 11,
                        resetsAt: now.addingTimeInterval(10_800)
                    ),
                    QuotaWindow(
                        kind: .sparkWeekly,
                        usedPercent: 52,
                        resetsAt: now.addingTimeInterval(432_000)
                    )
                ],
                billingUsage: .flexCreditBalance(
                    remainingCredits: 820,
                    usdValue: 32.8
                ),
                fetchedAt: now
            ))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude, .codex]
            )
        )
        await store.refresh()
        return store
    }

    private func makeFullyPopulatedStore() async -> UsageStore {
        let now = Date()
        let snapshots: [ProviderID: ProviderSnapshot] = [
            .claude: ProviderSnapshot(
                provider: .claude,
                planName: "Pro 20x",
                windows: [
                    QuotaWindow(kind: .session, usedPercent: 62, resetsAt: nil),
                    QuotaWindow(kind: .weekly, usedPercent: 37, resetsAt: nil),
                    QuotaWindow(kind: .sonnet, usedPercent: 86, resetsAt: nil),
                    QuotaWindow(kind: .fable, usedPercent: 14, resetsAt: nil)
                ],
                billingUsage: .boundedSpend(
                    usedAmount: 5,
                    limitAmount: 10,
                    currencyCode: "USD"
                ),
                fetchedAt: now
            ),
            .codex: ProviderSnapshot(
                provider: .codex,
                planName: "Pro 5x",
                windows: [
                    QuotaWindow(kind: .weekly, usedPercent: 74, resetsAt: nil),
                    QuotaWindow(
                        kind: .sparkSession,
                        usedPercent: 11,
                        resetsAt: nil
                    ),
                    QuotaWindow(
                        kind: .sparkWeekly,
                        usedPercent: 52,
                        resetsAt: nil
                    )
                ],
                billingUsage: .flexCreditBalance(
                    remainingCredits: 820,
                    usdValue: 32.8
                ),
                fetchedAt: now
            ),
            .cursor: ProviderSnapshot(
                provider: .cursor,
                planName: "Pro",
                windows: [
                    QuotaWindow(
                        kind: .totalUsage,
                        usedPercent: 25,
                        resetsAt: nil
                    ),
                    QuotaWindow(
                        kind: .autoUsage,
                        usedPercent: 40,
                        resetsAt: nil
                    ),
                    QuotaWindow(
                        kind: .apiUsage,
                        usedPercent: 12,
                        resetsAt: nil
                    )
                ],
                fetchedAt: now
            ),
            .antigravity: ProviderSnapshot(
                provider: .antigravity,
                planName: "Pro",
                windows: [
                    QuotaWindow(kind: .weekly, usedPercent: 34, resetsAt: nil),
                    QuotaWindow(
                        kind: .claudePool,
                        usedPercent: 48,
                        resetsAt: nil
                    )
                ],
                fetchedAt: now
            ),
            .copilot: ProviderSnapshot(
                provider: .copilot,
                planName: "Individual Pro",
                windows: [
                    QuotaWindow(kind: .credits, usedPercent: 25, resetsAt: nil),
                    QuotaWindow(kind: .chat, usedPercent: 20, resetsAt: nil),
                    QuotaWindow(
                        kind: .completions,
                        usedPercent: 8,
                        resetsAt: nil
                    )
                ],
                fetchedAt: now
            ),
            .devin: ProviderSnapshot(
                provider: .devin,
                planName: "Teams",
                windows: [
                    QuotaWindow(kind: .daily, usedPercent: 20, resetsAt: nil),
                    QuotaWindow(kind: .weekly, usedPercent: 65, resetsAt: nil)
                ],
                fetchedAt: now
            ),
            .grok: ProviderSnapshot(
                provider: .grok,
                planName: "SuperGrok",
                windows: [
                    QuotaWindow(kind: .weekly, usedPercent: 48, resetsAt: nil)
                ],
                fetchedAt: now
            )
        ]
        let providers = ProviderID.allCases.compactMap { provider in
            snapshots[provider].map {
                SequencedProvider(id: provider, results: [.success($0)])
            }
        }
        let store = UsageStore(
            providers: providers,
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: Set(ProviderID.allCases)
            )
        )
        await store.refresh()
        return store
    }

    private func measuredSize<Content: View>(
        of view: Content,
        width: CGFloat
    ) -> CGSize {
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
    }
}

@MainActor
private struct SnapshotLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}
