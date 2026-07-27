import Foundation
import SwiftUI

@main
@MainActor
struct AIUsageApp: App {
    @State private var store: UsageStore
    @State private var launchAtLogin: LaunchAtLoginController
    @AppStorage("menuBarSelection")
    private var menuBarSelection: MenuBarSelection = .automatic

    init() {
        let store = UsageStore()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            store.start()
        }
        _store = State(initialValue: store)
        _launchAtLogin = State(initialValue: LaunchAtLoginController())
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                store: store,
                launchAtLogin: launchAtLogin,
                menuBarSelection: $menuBarSelection
            )
        } label: {
            MenuBarLabelView(reading: store.menuBarReading(for: menuBarSelection))
        }
        .menuBarExtraStyle(.window)
    }
}
