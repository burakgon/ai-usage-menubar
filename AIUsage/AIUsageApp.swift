import Foundation
import SwiftUI

@main
@MainActor
struct AIUsageApp: App {
    @State private var store: UsageStore
    @State private var launchAtLogin: LaunchAtLoginController
    @State private var updateController: UpdateController
    @AppStorage("menuBarSelection")
    private var menuBarSelection: MenuBarSelection = .automatic
    @AppStorage("menuBarWindow")
    private var menuBarWindow: MenuBarWindow = .session
    @AppStorage("usageDisplayMode")
    private var usageDisplayMode: UsageDisplayMode =
        UsageDisplayMode.defaultSelection
    @AppStorage("refreshInterval")
    private var refreshInterval: RefreshIntervalOption = .fiveMinutes

    init() {
        let isTesting =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let savedRefreshInterval = UserDefaults.standard
            .string(forKey: "refreshInterval")
            .flatMap(RefreshIntervalOption.init(rawValue:))
            ?? .fiveMinutes
        let store = UsageStore(refreshInterval: savedRefreshInterval)
        let launchAtLogin = LaunchAtLoginController()
        if !isTesting {
            if Self.isInstalledInApplicationsFolder {
                launchAtLogin.enableByDefaultIfNeeded()
            }
            store.start()
        }
        _store = State(initialValue: store)
        _launchAtLogin = State(initialValue: launchAtLogin)
        _updateController = State(
            initialValue: UpdateController(startingUpdater: !isTesting)
        )
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                store: store,
                launchAtLogin: launchAtLogin,
                menuBarSelection: $menuBarSelection,
                menuBarWindow: $menuBarWindow,
                usageDisplayMode: $usageDisplayMode,
                refreshInterval: $refreshInterval,
                availableUpdateVersion: updateController.availableVersion,
                isCheckingForUpdates: updateController.isChecking,
                checkForUpdates: updateController.checkForUpdates
            )
        } label: {
            MenuBarLabelView(
                reading: store.menuBarReading(
                    for: menuBarSelection,
                    window: menuBarWindow,
                    displayMode: usageDisplayMode
                )
            )
        }
        .menuBarExtraStyle(.window)
    }

    private static var isInstalledInApplicationsFolder: Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let homeApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
            .path

        return bundlePath.hasPrefix("/Applications/") ||
            bundlePath.hasPrefix("\(homeApplicationsPath)/")
    }
}
