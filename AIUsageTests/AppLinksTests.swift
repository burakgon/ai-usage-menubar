import XCTest
@testable import AIUsage

final class AppLinksTests: XCTestCase {
    func testRepositoryLinkTargetsThePublicProject() {
        XCTAssertEqual(AppLinks.repository.scheme, "https")
        XCTAssertEqual(AppLinks.repository.host, "github.com")
        XCTAssertEqual(
            AppLinks.repository.path,
            "/burakgon/ai-usage-menubar"
        )
    }
}
