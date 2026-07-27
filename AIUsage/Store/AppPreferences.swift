import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    var menuBarSelection: MenuBarSelection {
        didSet {
            defaults.set(menuBarSelection.rawValue, forKey: Key.menuBarSelection)
        }
    }

    var menuBarWindow: MenuBarWindow {
        didSet {
            defaults.set(menuBarWindow.rawValue, forKey: Key.menuBarWindow)
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarSelection = Self.value(
            MenuBarSelection.self,
            forKey: Key.menuBarSelection,
            in: defaults
        ) ?? .automatic
        menuBarWindow = Self.value(
            MenuBarWindow.self,
            forKey: Key.menuBarWindow,
            in: defaults
        ) ?? .session
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
        static let menuBarSelection = "menuBarSelection"
        static let menuBarWindow = "menuBarWindow"
        static let usageDisplayMode = "usageDisplayMode"
        static let refreshInterval = "refreshInterval"
    }
}
