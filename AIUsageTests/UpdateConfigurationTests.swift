import Foundation
import XCTest

final class UpdateConfigurationTests: XCTestCase {
    func testSignedUpdateConfigurationIsEmbeddedInTheApp() {
        let info = Bundle.main.infoDictionary

        XCTAssertEqual(
            info?["SUFeedURL"] as? String,
            "https://raw.githubusercontent.com/burakgon/ai-usage-menubar/main/appcast.xml"
        )
        XCTAssertEqual(
            info?["SUPublicEDKey"] as? String,
            "Axec4KdnVCK/H0z6UrhigcI44LRzdrN8vnBxIvqPurc="
        )
        XCTAssertEqual(info?["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info?["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info?["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info?["SUScheduledCheckInterval"] as? Int, 86_400)
    }
}
