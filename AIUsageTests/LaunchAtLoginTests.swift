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
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    var shouldFail = false

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        if shouldFail { throw FakeError.failure }
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
