import AppKit
import SwiftUI

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AIUsageAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AIUsageAppDelegate: NSObject, NSApplicationDelegate {
    let services: AppServices
    private var menuBarController: MenuBarController?

    override init() {
        services = AppServices(
            startingUpdater: !Self.isRunningTests,
            defaults: Self.isRunningTests ? Self.testHostDefaults() : .standard
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        if Self.isInstalledInApplicationsFolder {
            services.launchAtLogin.enableByDefaultIfNeeded()
        }

        let services = self.services
        let menuBarController = MenuBarController(
            store: services.store,
            preferences: services.preferences,
            launchAtLogin: services.launchAtLogin,
            updateController: services.updateController
        )
        menuBarController.start()
        self.menuBarController = menuBarController
        installMainMenu()

        Task {
            await services.store.refresh()
            services.preferences.configureDefaultMenuBarProviders(
                availableItemsByProvider:
                    services.store.availableMenuBarItemsByProvider
            )
            if !services.preferences.hasCompletedInitialSetup {
                menuBarController.showSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
        menuBarController = nil
    }

    @objc
    private func openSettings(_ sender: Any?) {
        menuBarController?.showSettings()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "AI Usage")

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit AI Usage",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    /// The test host shares the app's bundle identifier, so it must never
    /// migrate or rewrite the settings of the installed app.
    private static func testHostDefaults() -> UserDefaults {
        let suiteName = "com.burakgon.aiusage.test-host"
        // A suite name distinct from the bundle identifier always succeeds.
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
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
