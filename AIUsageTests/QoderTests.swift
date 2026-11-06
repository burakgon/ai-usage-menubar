import Foundation
import XCTest
@testable import AIUsage

final class QoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Qoder's Electron-style secret box: `v10` + AES-128-CBC with a PBKDF2
    /// key and a space-filled IV, encrypted with `test-password`.
    private let encryptedAuth = """
    djEwMl5Wu16Yo5q2JbTDRG7bCeyYJV1iij0WbcXfW3t1ECiWvYGD/JfHRBOzF1RSCHkbMy8VOEMjxyY2DMhv26h5cyDKpMu4aeNUtwnbgz+WR68=
    """

    func testMapperMapsPlanAndBonusCredits() throws {
        let usage = httpResponse(json: """
        {
          "user_type": "personal_professional",
          "expires_at": 1800100000000,
          "user_quota": {
            "total": 1000,
            "used": 250,
            "percentage": 0.25,
            "unit": "credits"
          },
          "add_on_quota": {
            "total": 500,
            "used": 400,
            "percentage": 0.8,
            "unit": "credits"
          }
        }
        """)
        let plan = httpResponse(json: """
        {"plan_tier_name": "Pro", "user_type": "personal_professional"}
        """)

        let snapshot = try QoderUsageMapper.map(
            usage: usage,
            plan: plan,
            fallbackPlanName: "Trial",
            now: now
        )

        XCTAssertEqual(snapshot.provider, .qoder)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits, .bonusCredits])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 80])
        XCTAssertEqual(
            snapshot.windows.map(\.resetsAt),
            [
                Date(timeIntervalSince1970: 1_800_100_000),
                nil
            ]
        )
        XCTAssertEqual(
            snapshot.availableMenuBarItems.map(\.metric),
            [.credits, .bonusCredits]
        )
    }

    func testMapperOmitsAnEmptyBonusPool() throws {
        let snapshot = try QoderUsageMapper.mapCached(
            usage: Data("""
            {"userQuota": {"used": 0, "total": 1000, "percentage": 0}}
            """.utf8),
            planName: "Pro",
            now: now
        )

        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [0])
    }

    func testSecretBoxDecryptsAV10Payload() throws {
        let payload = try XCTUnwrap(Data(base64Encoded: encryptedAuth))
        let plaintext = Data(#"{"token":"qoder-token","user":{"planTierName":"Pro"},"unknown":true}"#.utf8)

        XCTAssertEqual(
            QoderSecretBox.decrypt(payload: payload, password: "test-password"),
            plaintext
        )
        XCTAssertNotEqual(
            QoderSecretBox.decrypt(payload: payload, password: "wrong-password"),
            plaintext
        )
        XCTAssertNil(
            QoderSecretBox.decrypt(
                payload: Data("not-encrypted".utf8),
                password: "test-password"
            )
        )
    }

    func testAuthStoreReadsTokenAndPlanFromQoderFiles() throws {
        let payload = try XCTUnwrap(Data(base64Encoded: encryptedAuth))
        let files = MemoryFiles(data: [
            "~/Library/Application Support/com.qoder.app.stable/auth.v1.dat": payload
        ])
        let keychain = MemoryKeychain(genericAccounts: [
            "Qoder App Safe Storage|Qoder App Key": "test-password"
        ])
        let store = QoderAuthStore(files: files, keychain: keychain)

        let state = try XCTUnwrap(store.load())

        XCTAssertEqual(state.accessToken, "qoder-token")
        XCTAssertEqual(state.planName, "Pro")
    }
}
