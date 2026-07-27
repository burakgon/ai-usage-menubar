import Foundation
import Observation
import ServiceManagement

enum LaunchAtLoginStatus: Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct MainAppLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var isEnabled = false
    private(set) var requiresApproval = false
    private(set) var errorMessage: String?

    private let service: LaunchAtLoginServicing

    init(service: LaunchAtLoginServicing = MainAppLaunchAtLoginService()) {
        self.service = service
        synchronize()
    }

    func setEnabled(_ enabled: Bool) {
        let previous = isEnabled
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            synchronize()
        } catch {
            isEnabled = previous
            errorMessage = enabled
                ? "Launch at Login could not be enabled."
                : "Launch at Login could not be disabled."
        }
    }

    func synchronize() {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
        case .notRegistered:
            isEnabled = false
            requiresApproval = false
        case .unavailable:
            isEnabled = false
            requiresApproval = false
            errorMessage = "Launch at Login is unavailable for this build."
        }
    }
}
