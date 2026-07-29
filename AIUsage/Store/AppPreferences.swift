import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private(set) var trackedProviderIDs: Set<ProviderID> {
        didSet {
            defaults.set(
                Self.encode(Array(trackedProviderIDs).sorted {
                    $0.rawValue < $1.rawValue
                }),
                forKey: Key.trackedProviderIDs
            )
        }
    }

    private(set) var visibleMenuBarProviderIDs: Set<ProviderID> {
        didSet {
            defaults.set(
                Self.encode(Array(visibleMenuBarProviderIDs).sorted {
                    $0.rawValue < $1.rawValue
                }),
                forKey: Key.visibleMenuBarProviderIDs
            )
        }
    }

    private(set) var menuBarMetricSelections:
        [ProviderID: [MenuBarMetricID]] {
        didSet {
            defaults.set(
                Self.encode(menuBarMetricSelections),
                forKey: Key.menuBarMetricSelections
            )
        }
    }

    private(set) var hasConfiguredMenuBar: Bool {
        didSet {
            defaults.set(
                hasConfiguredMenuBar,
                forKey: Key.hasConfiguredMenuBar
            )
        }
    }

    private(set) var hasCompletedInitialSetup: Bool {
        didSet {
            defaults.set(
                hasCompletedInitialSetup,
                forKey: Key.hasCompletedInitialSetup
            )
        }
    }

    var usageDisplayMode: UsageDisplayMode {
        didSet {
            defaults.set(usageDisplayMode.rawValue, forKey: Key.usageDisplayMode)
        }
    }

    var refreshInterval: RefreshIntervalOption {
        didSet {
            defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval)
        }
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let pendingMenuBarItems: [MenuBarItemID]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let restoredProviders = Self.decode(
            [ProviderID].self,
            forKey: Key.trackedProviderIDs,
            in: defaults
        )
        var initialTrackedProviders = Set(
            restoredProviders ?? ProviderID.allCases
        )
        if restoredProviders != nil,
           defaults.object(forKey: Key.openUsageProvidersAdded) == nil {
            initialTrackedProviders.formUnion(Self.openUsageProviders)
        }
        trackedProviderIDs = initialTrackedProviders
        defaults.set(true, forKey: Key.openUsageProvidersAdded)

        let storedVisibleProviders = Self.decode(
            [ProviderID].self,
            forKey: Key.visibleMenuBarProviderIDs,
            in: defaults
        )
        let storedMetricSelections = Self.decode(
            [ProviderID: [MenuBarMetricID]].self,
            forKey: Key.menuBarMetricSelections,
            in: defaults
        )
        let storedConfigurationFlag =
            defaults.object(forKey: Key.hasConfiguredMenuBar) as? Bool

        let currentItems = Self.decode(
            [MenuBarItemID].self,
            forKey: Key.currentMenuBarItems,
            in: defaults
        )
        let currentConfigurationFlag =
            defaults.object(forKey: Key.currentConfiguredMenuBarItems) as? Bool
        let previousItems = Self.decode(
            [MenuBarItemID].self,
            forKey: Key.previousMenuBarItems,
            in: defaults
        )
        let previousConfigurationFlag =
            defaults.object(forKey: Key.previousConfiguredMenuBarItems) as? Bool
        let hasLegacyInstallation = Self.hasLegacyInstallation(in: defaults)

        if storedConfigurationFlag == true ||
            storedVisibleProviders != nil ||
            storedMetricSelections != nil {
            visibleMenuBarProviderIDs = Set(
                storedVisibleProviders ?? []
            ).intersection(ProviderID.allCases)
            menuBarMetricSelections = Self.sanitizedSelections(
                storedMetricSelections ?? [:]
            )
            hasConfiguredMenuBar = true
            pendingMenuBarItems = nil
        } else if currentConfigurationFlag == true || currentItems != nil {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = Self.unique(currentItems ?? [])
        } else if previousConfigurationFlag == true || previousItems != nil {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = Self.unique(previousItems ?? [])
        } else if hasLegacyInstallation {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = nil
        } else {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = nil
        }

        if let storedCompletion =
            defaults.object(forKey: Key.hasCompletedInitialSetup) as? Bool {
            hasCompletedInitialSetup = storedCompletion
        } else {
            hasCompletedInitialSetup = hasLegacyInstallation
        }

        usageDisplayMode = Self.value(
            UsageDisplayMode.self,
            forKey: Key.usageDisplayMode,
            in: defaults
        ) ?? .defaultSelection
        refreshInterval = Self.value(
            RefreshIntervalOption.self,
            forKey: Key.refreshInterval,
            in: defaults
        ) ?? .fiveMinutes

        if hasLegacyInstallation &&
            defaults.object(forKey: Key.hasCompletedInitialSetup) == nil {
            defaults.set(true, forKey: Key.hasCompletedInitialSetup)
        }
    }

    var menuBarProviderConfigurations: [MenuBarProviderConfiguration] {
        ProviderID.allCases.compactMap { provider in
            guard visibleMenuBarProviderIDs.contains(provider) else {
                return nil
            }
            return MenuBarProviderConfiguration(
                provider: provider,
                metrics: selectedMenuBarMetrics(for: provider)
            )
        }
    }

    func isTracking(_ provider: ProviderID) -> Bool {
        trackedProviderIDs.contains(provider)
    }

    func setTracking(_ enabled: Bool, for provider: ProviderID) {
        if enabled {
            trackedProviderIDs.insert(provider)
        } else {
            trackedProviderIDs.remove(provider)
            visibleMenuBarProviderIDs.remove(provider)
        }
    }

    func isProviderShownInMenuBar(_ provider: ProviderID) -> Bool {
        visibleMenuBarProviderIDs.contains(provider)
    }

    func selectedMenuBarMetrics(
        for provider: ProviderID
    ) -> [MenuBarMetricID] {
        menuBarMetricSelections[provider] ?? []
    }

    func isMenuBarMetricSelected(_ item: MenuBarItemID) -> Bool {
        selectedMenuBarMetrics(for: item.provider).contains(item.metric)
    }

    func setMenuBarVisibility(
        _ enabled: Bool,
        for provider: ProviderID,
        availableItems: [MenuBarItemID]
    ) {
        if enabled {
            guard trackedProviderIDs.contains(provider) else { return }

            if selectedMenuBarMetrics(for: provider).isEmpty {
                guard let defaultMetric = Self.defaultMenuBarItem(
                    for: provider,
                    in: availableItems
                )?.metric else {
                    return
                }
                menuBarMetricSelections[provider] = [defaultMetric]
            }
            visibleMenuBarProviderIDs.insert(provider)
        } else {
            visibleMenuBarProviderIDs.remove(provider)
        }
        hasConfiguredMenuBar = true
    }

    func setMenuBarMetric(
        _ enabled: Bool,
        item: MenuBarItemID,
        availableItems: [MenuBarItemID]
    ) {
        var metrics = selectedMenuBarMetrics(for: item.provider)
        if enabled {
            if !metrics.contains(item.metric) {
                metrics.append(item.metric)
            }
            if trackedProviderIDs.contains(item.provider) {
                visibleMenuBarProviderIDs.insert(item.provider)
            }
        } else {
            metrics.removeAll { $0 == item.metric }
        }

        metrics = Self.orderedMetrics(
            metrics,
            provider: item.provider,
            availableItems: availableItems
        )
        if metrics.isEmpty {
            menuBarMetricSelections.removeValue(forKey: item.provider)
            visibleMenuBarProviderIDs.remove(item.provider)
        } else {
            menuBarMetricSelections[item.provider] = metrics
        }
        hasConfiguredMenuBar = true
    }

    func configureDefaultMenuBarProviders(
        availableItemsByProvider: [ProviderID: [MenuBarItemID]]
    ) {
        guard !hasConfiguredMenuBar else { return }

        let selectedItems: [MenuBarItemID]
        if let pendingMenuBarItems {
            selectedItems = Self.resolve(
                pendingMenuBarItems,
                against: availableItemsByProvider
            )
        } else {
            selectedItems = Self.initialWeeklyMenuBarItems
        }
        applyMenuBarItems(selectedItems)
        hasConfiguredMenuBar = true
    }

    func markInitialSetupCompleted() {
        guard !hasCompletedInitialSetup else { return }
        hasCompletedInitialSetup = true
    }

    private func applyMenuBarItems(_ items: [MenuBarItemID]) {
        var selections: [ProviderID: [MenuBarMetricID]] = [:]
        for provider in ProviderID.allCases {
            let metrics = Self.uniqueMetrics(
                items
                    .filter { $0.provider == provider }
                    .map(\.metric)
            )
            if !metrics.isEmpty {
                selections[provider] = metrics
            }
        }
        menuBarMetricSelections = selections
        visibleMenuBarProviderIDs = Set(selections.keys)
    }

    private static var initialWeeklyMenuBarItems: [MenuBarItemID] {
        [ProviderID.claude, .codex].map {
            MenuBarItemID(
                provider: $0,
                metric: $0.defaultMenuBarMetric
            )
        }
    }

    private static let openUsageProviders: Set<ProviderID> = [
        .cursor,
        .antigravity,
        .copilot,
        .devin,
        .grok
    ]

    private static func hasLegacyInstallation(
        in defaults: UserDefaults
    ) -> Bool {
        [
            Key.menuBarSelection,
            Key.menuBarWindow,
            Key.usageDisplayMode,
            Key.refreshInterval,
            "launchAtLoginDefaultActivationApplied"
        ].contains { defaults.object(forKey: $0) != nil }
    }

    private static func unique(_ items: [MenuBarItemID]) -> [MenuBarItemID] {
        var seen: Set<MenuBarItemID> = []
        return items.filter { seen.insert($0).inserted }
    }

    private static func uniqueMetrics(
        _ metrics: [MenuBarMetricID]
    ) -> [MenuBarMetricID] {
        var seen: Set<MenuBarMetricID> = []
        return metrics.filter { seen.insert($0).inserted }
    }

    private static func sanitizedSelections(
        _ selections: [ProviderID: [MenuBarMetricID]]
    ) -> [ProviderID: [MenuBarMetricID]] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap {
            provider in
            let metrics = uniqueMetrics(selections[provider] ?? [])
            return metrics.isEmpty ? nil : (provider, metrics)
        })
    }

    private static func orderedMetrics(
        _ selectedMetrics: [MenuBarMetricID],
        provider: ProviderID,
        availableItems: [MenuBarItemID]
    ) -> [MenuBarMetricID] {
        let uniqueSelected = uniqueMetrics(selectedMetrics)
        let availableOrder = uniqueMetrics(
            availableItems
                .filter { $0.provider == provider }
                .map(\.metric)
        )
        let available = availableOrder.filter(uniqueSelected.contains)
        let temporarilyUnavailable = uniqueSelected.filter {
            !availableOrder.contains($0)
        }
        return available + temporarilyUnavailable
    }

    private static func defaultMenuBarItem(
        for provider: ProviderID,
        in availableItems: [MenuBarItemID]
    ) -> MenuBarItemID? {
        let providerItems = availableItems.filter {
            $0.provider == provider
        }
        return providerItems.first {
            $0.metric == provider.defaultMenuBarMetric
        } ?? providerItems.first
    }

    private static func resolve(
        _ desiredItems: [MenuBarItemID],
        against availableItemsByProvider: [ProviderID: [MenuBarItemID]]
    ) -> [MenuBarItemID] {
        var resolved: [MenuBarItemID] = []
        for provider in ProviderID.allCases {
            let desiredForProvider = desiredItems.filter {
                $0.provider == provider
            }
            guard !desiredForProvider.isEmpty else { continue }

            let available = availableItemsByProvider[provider] ?? []
            if available.isEmpty {
                resolved.append(contentsOf: desiredForProvider)
                continue
            }
            let desiredSet = Set(desiredForProvider)
            let exactMatches = available.filter(desiredSet.contains)
            if exactMatches.isEmpty {
                if let fallback = defaultMenuBarItem(
                    for: provider,
                    in: available
                ) {
                    resolved.append(fallback)
                }
            } else {
                resolved.append(contentsOf: exactMatches)
            }
        }
        return unique(resolved)
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func value<Value: RawRepresentable>(
        _ type: Value.Type,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Value? where Value.RawValue == String {
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return Value(rawValue: rawValue)
    }

    private enum Key {
        static let trackedProviderIDs = "trackedProviderIDs.v1"
        static let visibleMenuBarProviderIDs =
            "menuBarVisibleProviders.v3"
        static let menuBarMetricSelections =
            "menuBarMetricSelections.v3"
        static let hasConfiguredMenuBar =
            "menuBarConfigured.v3"
        static let currentMenuBarItems = "menuBarItems.v2"
        static let currentConfiguredMenuBarItems =
            "menuBarItemsConfigured.v2"
        static let previousMenuBarItems = "menuBarItems.v1"
        static let previousConfiguredMenuBarItems =
            "menuBarItemsConfigured.v1"
        static let hasCompletedInitialSetup = "initialSettingsCompleted.v1"
        static let openUsageProvidersAdded =
            "openUsageProvidersAdded.v1"
        static let menuBarSelection = "menuBarSelection"
        static let menuBarWindow = "menuBarWindow"
        static let usageDisplayMode = "usageDisplayMode"
        static let refreshInterval = "refreshInterval"
    }
}
