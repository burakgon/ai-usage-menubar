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
                of: MenuBarLabelView(reading: MenuBarReading(
                    provider: .codex,
                    percent: 62,
                    displayMode: displayMode,
                    isStale: false,
                    showsPlaceholder: false
                )),
                width: 200
            )

            XCTAssertLessThan(size.width, 60)
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
                menuBarSelection: .constant(.automatic),
                menuBarWindow: .constant(.session),
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
            menuBarSelection: .constant(.codex),
            menuBarWindow: .constant(.weekly),
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
                fetchedAt: now
            ))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker()
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
