import Foundation
import XCTest
@testable import AIUsage

final class KiroTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMapperMapsCreditsFreeTrialAndWeeklyWindows() throws {
        let response = httpResponse(json: """
        {
          "subscriptionInfo": {"subscriptionTitle": "Kiro Pro"},
          "nextDateReset": "2027-01-15T00:00:00.000Z",
          "usageBreakdownList": [
            {
              "displayName": "Agentic Requests",
              "resourceType": "AGENTIC_REQUEST",
              "currentUsageWithPrecision": 250,
              "usageLimitWithPrecision": 1000
            },
            {
              "displayName": "Weekly requests",
              "resourceType": "AGENTIC_REQUEST",
              "currentUsageWithPrecision": 100,
              "usageLimitWithPrecision": 500
            },
            {
              "displayName": "Free trial",
              "resourceType": "AGENTIC_REQUEST",
              "freeTrialInfo": {
                "freeTrialStatus": "ACTIVE",
                "currentUsageWithPrecision": 10,
                "usageLimitWithPrecision": 100,
                "freeTrialExpiry": "2027-01-01T00:00:00.000Z"
              }
            }
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.provider, .kiro)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits, .weekly, .credits])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 20, 10])
        XCTAssertEqual(
            snapshot.windows.last?.resetsAt,
            ProviderParsing.date("2027-01-01T00:00:00.000Z")
        )
    }

    func testMapperFallsBackToFreePlanWithoutASubscription() throws {
        let response = httpResponse(json: """
        {"usageBreakdownList": [{"currentUsage": 1, "usageLimit": 4}]}
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25])
    }

    func testMapperReportsEnabledOverageAsBillingUsage() throws {
        let response = httpResponse(json: """
        {
          "subscriptionInfo": {"subscriptionTitle": "Kiro Pro"},
          "overageConfiguration": {"overageStatus": "ENABLED"},
          "usageBreakdownList": [
            {
              "currentUsageWithPrecision": 0,
              "usageLimitWithPrecision": 1000,
              "overageCharges": 12.5,
              "overageCapWithPrecision": 100,
              "overageRate": 0.04,
              "currency": "USD"
            }
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        guard case let .boundedSpend(usedAmount, limitAmount, currencyCode) =
            snapshot.billingUsage else {
            return XCTFail("Expected bounded overage spend")
        }
        XCTAssertEqual(usedAmount, 12.5)
        XCTAssertEqual(limitAmount, 4.0)
        XCTAssertEqual(currencyCode, "USD")
    }

    func testAuthStoreLoadsTokenAndClientCredentialsFromSSOCache() throws {
        let files = MemoryFiles([
            KiroAuthStore.primaryAuthPath: """
            {"accessToken":"old","refreshToken":"refresh","clientIdHash":"abc123","authMethod":"social"}
            """,
            "~/.aws/sso/cache/abc123.json": """
            {"clientId":"client","clientSecret":"secret"}
            """
        ])
        let store = KiroAuthStore(
            files: files,
            dateProvider: FixedDateProvider(value: now)
        )

        let state = try XCTUnwrap(store.load())

        XCTAssertEqual(state.tokenRecord.accessToken, "old")
        XCTAssertEqual(state.tokenPath, KiroAuthStore.primaryAuthPath)
        XCTAssertEqual(state.clientCredentials?.clientId, "client")
        XCTAssertEqual(state.clientCredentials?.clientSecret, "secret")
    }

    func testAuthStoreRefreshPersistsRotatedTokensAndUnknownFields() async throws {
        let token = """
        {"accessToken":"old","refreshToken":"refresh","expiresAt":"2020-01-01T00:00:00.000Z","clientIdHash":"abc123","authMethod":"social","unknownField":{"nested":true}}
        """
        let files = MemoryFiles([
            KiroAuthStore.primaryAuthPath: token,
            "~/.aws/sso/cache/abc123.json": """
            {"clientId":"client","clientSecret":"secret"}
            """
        ])
        let store = KiroAuthStore(
            files: files,
            dateProvider: FixedDateProvider(value: now)
        )
        var state = try XCTUnwrap(store.load())
        let http = MockHTTPClient([
            httpResponse(json: """
            {"accessToken":"new","refreshToken":"rotated","expiresIn":3600,"profileArn":"arn:new"}
            """)
        ])

        let refreshed = try await store.refresh(&state, client: http)
        XCTAssertTrue(refreshed)
        XCTAssertEqual(state.tokenRecord.accessToken, "new")
        XCTAssertEqual(state.tokenRecord.refreshToken, "rotated")

        let saved = try XCTUnwrap(files.value(at: KiroAuthStore.primaryAuthPath))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["accessToken"] as? String, "new")
        XCTAssertEqual(object["refreshToken"] as? String, "rotated")
        XCTAssertEqual(object["profileArn"] as? String, "arn:new")
        XCTAssertEqual(object["authMethod"] as? String, "social")
        XCTAssertNotNil(object["unknownField"])
    }
}
