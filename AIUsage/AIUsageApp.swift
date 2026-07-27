import Foundation
import SwiftUI

@main
@MainActor
struct AIUsageApp: App {
    @State private var store: UsageStore
    @State private var launchAtLogin: LaunchAtLoginController
    private let updateController: UpdateController
    @AppStorage("menuBarSelection")
    private var menuBarSelection: MenuBarSelection = .automatic

    init() {
        let isTesting =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let store = UsageStore()
        if !isTesting {
            store.start()
        }
        _store = State(initialValue: store)
        _launchAtLogin = State(initialValue: LaunchAtLoginController())
        updateController = UpdateController(startingUpdater: !isTesting)
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                store: store,
                launchAtLogin: launchAtLogin,
                menuBarSelection: $menuBarSelection,
                checkForUpdates: updateController.checkForUpdates
            )
        } label: {
            MenuBarLabelView(reading: store.menuBarReading(for: menuBarSelection))
        }
        .menuBarExtraStyle(.window)
    }
}
