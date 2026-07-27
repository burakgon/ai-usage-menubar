import XCTest
@testable import AIUsage

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testRegistrationStateAndFailureRollback() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)

        service.shouldFail = true
        controller.setEnabled(false)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testRequiresApprovalRemainsEnabledWithNotice() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
    }

    func testLaunchAtLoginIsEnabledByDefaultOnlyOnce() {
        let suiteName = "LaunchAtLoginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        controller.enableByDefaultIfNeeded(defaults: defaults)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCallCount, 1)

        controller.setEnabled(false)
        controller.enableByDefaultIfNeeded(defaults: defaults)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.registerCallCount, 1)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var shouldFail = false
    var registerCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        if shouldFail { throw FakeError.failure }
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        if shouldFail { throw FakeError.failure }
        status = .notRegistered
    }
}

private enum FakeError: Error {
    case failure
}
