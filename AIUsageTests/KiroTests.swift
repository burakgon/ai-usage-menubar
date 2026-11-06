import Foundation
import XCTest
@testable import AIUsage

final class KiroTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Mapping

    func testMapperMapsCreditsFreeTrialAndWeeklyWindows() throws {
        let response = httpResponse(json: """
        {
          "subscriptionInfo": {"subscriptionTitle": "Kiro Pro"},
          "nextDateReset": "2027-01-15T00:00:00.000Z",
          "usageBreakdownList": [
            {
              "displayName": "Credit",
              "resourceType": "CREDIT",
              "currentUsageWithPrecision": 250,
              "usageLimitWithPrecision": 1000
            },
            {
              "displayName": "Weekly",
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
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits, .weekly, .freeTrial])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 20, 10])
        XCTAssertEqual(
            snapshot.windows.last?.resetsAt,
            ProviderParsing.date("2027-01-01T00:00:00.000Z")
        )
    }

    func testMapperKeepsReportedPercentAndClampsOnlyTheBar() throws {
        let response = httpResponse(json: """
        {
          "usageBreakdownList": [
            {
              "displayName": "Credit",
              "resourceType": "CREDIT",
              "currentUsageWithPrecision": 1200,
              "usageLimitWithPrecision": 1000
            }
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(window.usedPercent, 100)
        XCTAssertEqual(window.renderedFraction, 1)
    }

    func testMapperLeavesOutBreakdownsKiroDidNotDescribe() throws {
        let response = httpResponse(json: """
        {
          "usageBreakdownList": [
            {"resourceType": "CREDIT", "currentUsage": 1, "usageLimit": 4},
            {"resourceType": "AGENTIC_REQUEST", "displayName": "Credit"},
            {"resourceType": "UNKNOWN_THING", "currentUsage": 5, "usageLimit": 10},
            {"resourceType": "AGENTIC_REQUEST", "currentUsage": 5, "usageLimit": 10}
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits])
        XCTAssertEqual(snapshot.windows.count, Set(snapshot.windows.map(\.kind)).count)
    }

    func testMapperReportsNoPlanInsteadOfInventingFree() throws {
        let response = httpResponse(json: """
        {"usageBreakdownList": [{"resourceType": "CREDIT", "currentUsage": 1, "usageLimit": 4}]}
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertNil(snapshot.planName)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25])
    }

    func testMapperNeverReportsEmptyWindows() throws {
        let response = httpResponse(json: """
        {"subscriptionInfo": {"subscriptionTitle": "KIRO STUDENT"}}
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.planName, "Student")
    }

    func testMapperReadsTheSubscriptionTypeAsAPlanLabel() throws {
        let response = httpResponse(json: """
        {"subscriptionInfo": {"type": "Q_DEVELOPER_STANDALONE_STUDENT"}}
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.planName, "Q Developer Standalone Student")
    }

    // MARK: - Billing

    func testMapperReportsEnabledOverageAsBillingUsage() throws {
        let response = httpResponse(json: """
        {
          "subscriptionInfo": {"subscriptionTitle": "Kiro Pro"},
          "overageConfiguration": {"overageStatus": "ENABLED"},
          "usageBreakdownList": [
            {
              "resourceType": "CREDIT",
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

    func testMapperReportsOverageWithoutACapAsUnbounded() throws {
        let response = httpResponse(json: """
        {
          "overageConfiguration": {"overageStatus": "ENABLED"},
          "usageBreakdownList": [
            {
              "resourceType": "CREDIT",
              "currentUsageWithPrecision": 0,
              "usageLimitWithPrecision": 1000,
              "overageCharges": 3.25,
              "currency": "USD"
            }
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        guard case let .unboundedSpend(usedAmount, currencyCode) =
            snapshot.billingUsage else {
            return XCTFail("Expected unbounded overage spend")
        }
        XCTAssertEqual(usedAmount, 3.25)
        XCTAssertEqual(currencyCode, "USD")
    }

    func testMapperDoesNotAssumeAnOverageRate() throws {
        let response = httpResponse(json: """
        {
          "overageConfiguration": {"overageStatus": "ENABLED"},
          "usageBreakdownList": [
            {
              "resourceType": "CREDIT",
              "currentUsageWithPrecision": 0,
              "usageLimitWithPrecision": 1000,
              "overageCharges": 3.25,
              "overageCapWithPrecision": 100,
              "currency": "USD"
            }
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        guard case let .unboundedSpend(usedAmount, currencyCode) =
            snapshot.billingUsage else {
            return XCTFail("An unreported rate must not produce a derived cap")
        }
        XCTAssertEqual(usedAmount, 3.25)
        XCTAssertEqual(currencyCode, "USD")
    }

    func testMapperIgnoresDisabledOverage() throws {
        let response = httpResponse(json: """
        {
          "overageConfiguration": {"overageStatus": "DISABLED", "overageLimit": null},
          "usageBreakdownList": [
            {
              "resourceType": "CREDIT",
              "currentUsageWithPrecision": 488.96,
              "usageLimitWithPrecision": 1000,
              "overageCharges": 0.0,
              "overageCap": 10000,
              "overageRate": 0.04,
              "currency": "USD"
            }
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertNil(snapshot.billingUsage)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits])
    }

    // MARK: - Credentials

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
            environment: MockEnvironment(),
            dateProvider: FixedDateProvider(value: now)
        )

        let state = try XCTUnwrap(store.load())

        XCTAssertEqual(state.tokenRecord.accessToken, "old")
        XCTAssertEqual(state.tokenPath, KiroAuthStore.primaryAuthPath)
        XCTAssertEqual(state.clientCredentials?.clientId, "client")
        XCTAssertEqual(state.clientCredentials?.clientSecret, "secret")
    }

    func testAuthStoreIgnoresAnotherToolsSSORegistration() throws {
        let files = MemoryFiles([
            KiroAuthStore.primaryAuthPath: """
            {"accessToken":"old","refreshToken":"refresh","clientIdHash":"abc123"}
            """,
            // The work `aws sso login` registration living in the same cache.
            "~/.aws/sso/cache/other-session.json": """
            {"clientId":"work-client","clientSecret":"work-secret"}
            """
        ])
        let store = KiroAuthStore(
            files: files,
            environment: MockEnvironment(),
            dateProvider: FixedDateProvider(value: now)
        )

        let state = try XCTUnwrap(store.load())

        XCTAssertNil(state.clientCredentials)
        XCTAssertFalse(store.canRefresh(state))
    }

    func testAuthStoreReadsTheAPIKeyThroughTheEnvironmentReader() throws {
        let store = KiroAuthStore(
            files: MemoryFiles(),
            environment: MockEnvironment(values: ["KIRO_API_KEY": "key-from-shell"]),
            dateProvider: FixedDateProvider(value: now)
        )

        let state = try XCTUnwrap(store.load())
        XCTAssertEqual(state.tokenRecord.accessToken, "key-from-shell")
        XCTAssertTrue(state.tokenPath.isEmpty)
        XCTAssertFalse(store.canRefresh(state))
    }

    func testAuthStoreTreatsAnExpiryWithoutATimestampAsStale() throws {
        let store = KiroAuthStore(
            files: MemoryFiles(),
            environment: MockEnvironment(),
            dateProvider: FixedDateProvider(value: now)
        )
        let state = KiroAuthState(
            tokenRecord: KiroTokenRecord(
                accessToken: "token",
                refreshToken: "refresh",
                expiresAt: nil,
                clientIdHash: "abc123"
            ),
            tokenPath: KiroAuthStore.primaryAuthPath,
            clientCredentials: nil
        )

        XCTAssertTrue(store.needsRefresh(state))
    }

    // MARK: - Region

    func testRegionAcceptsOnlyAWSRegionNames() {
        let store = KiroAuthStore(
            files: MemoryFiles(),
            environment: MockEnvironment(),
            dateProvider: FixedDateProvider(value: now)
        )
        func state(_ region: String?) -> KiroAuthState {
            KiroAuthState(
                tokenRecord: KiroTokenRecord(region: region),
                tokenPath: "",
                clientCredentials: nil
            )
        }

        XCTAssertEqual(store.region(for: state("eu-west-1")), "eu-west-1")
        XCTAssertEqual(store.region(for: state("us-gov-west-1")), "us-gov-west-1")
        XCTAssertEqual(store.region(for: state("ap-southeast-2")), "ap-southeast-2")

        // A poisoned token file must not redirect the refresh token, client
        // secret, or access token to an attacker-controlled host.
        XCTAssertEqual(
            store.region(for: state("evil.example.com/x")),
            KiroAuthStore.defaultRegion
        )
        XCTAssertEqual(
            store.region(for: state("us-east-1.evil.com")),
            KiroAuthStore.defaultRegion
        )
        XCTAssertEqual(
            store.region(for: state("US-EAST-1")),
            KiroAuthStore.defaultRegion
        )
        XCTAssertEqual(
            store.region(for: state("")),
            KiroAuthStore.defaultRegion
        )
        XCTAssertEqual(
            store.region(for: state(nil)),
            KiroAuthStore.defaultRegion
        )
    }

    // MARK: - Refresh persistence

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
            environment: MockEnvironment(),
            dateProvider: FixedDateProvider(value: now)
        )
        var state = try XCTUnwrap(store.load())
        let http = RoutedHTTPClient([
            "https://oidc.us-east-1.amazonaws.com/token": [
                httpResponse(json: """
                {"accessToken":"new","refreshToken":"rotated","expiresIn":3600,"profileArn":"arn:new"}
                """)
            ]
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

    func testAuthStoreGivesUpWhenKiroRotatedTheTokenFirst() async throws {
        let files = MemoryFiles([
            KiroAuthStore.primaryAuthPath: """
            {"accessToken":"old","refreshToken":"refresh","clientIdHash":"abc123"}
            """,
            "~/.aws/sso/cache/abc123.json": """
            {"clientId":"client","clientSecret":"secret"}
            """
        ])
        let store = KiroAuthStore(
            files: files,
            environment: MockEnvironment(),
            dateProvider: FixedDateProvider(value: now)
        )
        var state = try XCTUnwrap(store.load())
        // Kiro signs in again while this refresh is in flight.
        try files.writeText(
            KiroAuthStore.primaryAuthPath,
            #"{"accessToken":"newer","refreshToken":"rotated-by-kiro"}"#
        )

        let http = RoutedHTTPClient([
            "https://oidc.us-east-1.amazonaws.com/token": [
                httpResponse(json: """
                {"accessToken":"ours","refreshToken":"ours-rotated","expiresIn":3600}
                """)
            ]
        ])

        do {
            _ = try await store.refresh(&state, client: http)
            XCTFail("A moved-on token file must not be overwritten")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .storage)
        }

        let saved = try XCTUnwrap(files.value(at: KiroAuthStore.primaryAuthPath))
        XCTAssertTrue(saved.contains("rotated-by-kiro"))
        XCTAssertFalse(saved.contains("ours-rotated"))
    }

    func testRefreshRejectsARegionThatIsNotAnAWSRegion() async throws {
        let files = MemoryFiles([
            KiroAuthStore.primaryAuthPath: """
            {"accessToken":"old","refreshToken":"refresh","region":"evil.example.com","clientIdHash":"abc123"}
            """,
            "~/.aws/sso/cache/abc123.json": """
            {"clientId":"client","clientSecret":"secret"}
            """
        ])
        let store = KiroAuthStore(
            files: files,
            environment: MockEnvironment(),
            dateProvider: FixedDateProvider(value: now)
        )
        var state = try XCTUnwrap(store.load())
        let http = RoutedHTTPClient([
            "https://oidc.us-east-1.amazonaws.com/token": [
                httpResponse(json: """
                {"accessToken":"new","expiresIn":3600}
                """)
            ]
        ])

        let refreshed = try await store.refresh(&state, client: http)
        XCTAssertTrue(refreshed)

        let urls = await http.capturedRequests().map(\.url.absoluteString)
        XCTAssertEqual(urls, ["https://oidc.us-east-1.amazonaws.com/token"])
    }
}
