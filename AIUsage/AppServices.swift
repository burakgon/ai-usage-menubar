@MainActor
final class AppServices {
    let preferences: AppPreferences
    let store: UsageStore
    let launchAtLogin: LaunchAtLoginController
    let updateController: UpdateController

    init(startingUpdater: Bool = true) {
        let preferences = AppPreferences()
        self.preferences = preferences
        store = UsageStore(
            refreshInterval: preferences.refreshInterval,
            trackedProviderIDs: preferences.trackedProviderIDs
        )
        launchAtLogin = LaunchAtLoginController()
        updateController = UpdateController(startingUpdater: startingUpdater)
    }
}
