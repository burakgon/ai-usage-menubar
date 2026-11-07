import Foundation
import XCTest
@testable import AIUsage

final class KiroTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Mapping

    func testMapperShowsAnActiveFreeTrialBesideTheCredits() throws {
        let response = httpResponse(json: """
        {
          "subscriptionInfo": {"subscriptionTitle": "KIRO FREE"},
          "nextDateReset": 1799020800.0,
          "usageBreakdownList": [
            {
              "displayName": "Credit",
              "resourceType": "CREDIT",
              "currentUsageWithPrecision": 12.5,
              "usageLimitWithPrecision": 50,
              "freeTrialInfo": {
                "freeTrialStatus": "ACTIVE",
                "currentUsageWithPrecision": 100,
                "usageLimitWithPrecision": 500,
                "freeTrialExpiry": "2027-01-01T00:00:00.000Z"
              }
            }
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.provider, .kiro)
        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits, .freeTrial])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25, 20])
        XCTAssertEqual(
            snapshot.windows.map(\.resetsAt),
            [
                Date(timeIntervalSince1970: 1_799_020_800),
                ProviderParsing.date("2027-01-01T00:00:00.000Z")
            ]
        )
    }

    func testMapperIgnoresAnEndedFreeTrial() throws {
        let response = httpResponse(json: """
        {"usageBreakdownList": [{
          "resourceType": "CREDIT", "currentUsage": 5, "usageLimit": 50,
          "freeTrialInfo": {"freeTrialStatus": "EXPIRED", "currentUsage": 500, "usageLimit": 500}
        }]}
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits])
    }

    func testMapperBoundsTheCalculatedPercent() throws {
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
            {"resourceType": "AGENTIC_REQUEST", "currentUsage": 5, "usageLimit": 10},
            {"resourceType": "AGENTIC_REQUEST", "displayName": "Weekly", "currentUsage": 5, "usageLimit": 10},
            {"resourceType": "CREDIT", "currentUsage": 3, "usageLimit": 4}
          ]
        }
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.windows.map(\.kind), [.credits])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [25])
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

    func testMapperKeepsThePlanTierKiroReports() throws {
        let titles = [
            "KIRO PRO+": "Pro+",
            "KIRO POWER": "Power",
            "KIRO STUDENT": "Student",
            "Kiro Pro": "Pro"
        ]
        for (title, plan) in titles {
            let response = httpResponse(json: """
            {"subscriptionInfo": {"subscriptionTitle": "\(title)"}}
            """)

            let snapshot = try KiroUsageMapper.map(response: response, now: now)

            XCTAssertEqual(snapshot.planName, plan, title)
        }
    }

    func testMapperDoesNotShowTheInternalSubscriptionType() throws {
        let response = httpResponse(json: """
        {"subscriptionInfo": {"type": "Q_DEVELOPER_STANDALONE_STUDENT"}}
        """)

        let snapshot = try KiroUsageMapper.map(response: response, now: now)

        XCTAssertNil(snapshot.planName)
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
        {"accessToken":"old","refreshToken":"refresh","expiresAt":"2020-01-01T00:00:00.000Z","clientIdHash":"abc123","authMethod":"social","startUrl":"https://view.awsapps.com/start","unknownField":{"nested":true}}
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
        XCTAssertEqual(object["startUrl"] as? String, "https://view.awsapps.com/start")
        XCTAssertNotNil(object["unknownField"])
        XCTAssertFalse(saved.contains(#"\/"#))
    }

    func testRefreshReportsAnAWSOutageAsTransient() async throws {
        let token = """
        {"accessToken":"old","refreshToken":"refresh","clientIdHash":"abc123"}
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
            "https://oidc.us-east-1.amazonaws.com/token": [httpResponse(503)]
        ])

        do {
            _ = try await store.refresh(&state, client: http)
            XCTFail("An AWS outage must not read as a sign-out")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .transient)
        }
        XCTAssertEqual(files.value(at: KiroAuthStore.primaryAuthPath), token)
    }

    func testProviderReportsARejectedAPIKeyAsTheKeys() async throws {
        let http = RoutedHTTPClient([
            "https://q.us-east-1.amazonaws.com/getUsageLimits?origin=AI_EDITOR&resourceType=AGENTIC_REQUEST": [
                httpResponse(403)
            ]
        ])
        let provider = KiroProvider(
            authStore: KiroAuthStore(
                files: MemoryFiles(),
                environment: MockEnvironment(values: ["KIRO_API_KEY": "revoked"]),
                dateProvider: FixedDateProvider(value: now)
            ),
            client: KiroUsageClient(client: http),
            httpClient: http,
            dateProvider: FixedDateProvider(value: now)
        )

        do {
            _ = try await provider.fetch()
            XCTFail("A rejected key must fail")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
            XCTAssertEqual(failure.message, "Kiro rejected KIRO_API_KEY. Check the key.")
        }
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
