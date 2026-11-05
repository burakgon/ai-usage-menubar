import XCTest
@testable import AIUsage

/// Provider contract changes adopted from current OpenUsage research.
final class ProviderContractUpdateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeExtraUsageKeepsTheAccountCurrency() throws {
        let snapshot = try ClaudeUsageMapper.map(
            response: httpResponse(json: """
            {"seven_day":{"utilization":10},
             "extra_usage":{"is_enabled":true,"used_credits":1234,
                            "monthly_limit":5000,"currency":"eur","decimal_places":2}}
            """),
            credentials: oauth(),
            now: now
        )

        XCTAssertEqual(
            snapshot.billingUsage,
            .boundedSpend(usedAmount: 12.34, limitAmount: 50, currencyCode: "EUR")
        )

        let yen = try ClaudeUsageMapper.map(
            response: httpResponse(json: """
            {"extra_usage":{"is_enabled":true,"used_credits":1500,
                            "currency":"JPY","decimal_places":0}}
            """),
            credentials: oauth(),
            now: now
        )
        XCTAssertEqual(
            yen.billingUsage,
            .unboundedSpend(usedAmount: 1500, currencyCode: "JPY")
        )
    }

    func testClaudePlanUsesAnthropicsCurrentNames() {
        let cases: [(String?, String?, String?)] = [
            ("max", "default_claude_max_20x", "Ultra"),
            ("max", "default_claude_max_5x", "Max"),
            ("claude_max", nil, "Max"),
            ("ultra", nil, "Ultra"),
            ("pro", nil, "Pro"),
            ("team", "default_claude_team_5x", "Team 5x"),
            (nil, "default_claude_max_20x", nil)
        ]
        for (subscription, tier, expected) in cases {
            XCTAssertEqual(
                ClaudeUsageMapper.planName(oauth(
                    subscriptionType: subscription,
                    rateLimitTier: tier
                )),
                expected,
                "\(subscription ?? "nil") \(tier ?? "nil")"
            )
        }
    }

    func testCodexPlansAndCreditsFollowOpenAI() throws {
        for (raw, expected) in [
            ("prolite", "Pro 100"),
            (" PRO ", "Pro 200"),
            ("promax", "Pro 500"),
            ("self_serve_business_prolite", "Business Premium"),
            ("plus", "Plus")
        ] {
            XCTAssertEqual(CodexUsageMapper.planName(raw), expected, raw)
        }

        let withoutCredits = try CodexUsageMapper.map(
            response: httpResponse(json: """
            {"credits":{"has_credits":false,"balance":"0"}}
            """),
            now: now
        )
        XCTAssertNil(withoutCredits.billingUsage)

        let headerOnly = try CodexUsageMapper.map(
            response: httpResponse(
                json: "{}",
                headers: [
                    "x-codex-credits-has-credits": "False",
                    "x-codex-credits-balance": "12"
                ]
            ),
            now: now
        )
        XCTAssertNil(headerOnly.billingUsage)

        let stringBalance = try CodexUsageMapper.map(
            response: httpResponse(json: """
            {"credits":{"has_credits":true,"balance":"125.75"}}
            """),
            now: now
        )
        XCTAssertEqual(
            stringBalance.billingUsage,
            .flexCreditBalance(remainingCredits: 125, usdValue: 5)
        )
    }

    func testDevinReadsAnOmittedShareAsNothingLeft() throws {
        let snapshot = try DevinUsageMapper.map(response: httpResponse(json: """
        {"userStatus":{"planStatus":{
          "planInfo":{"planName":"Pro"},
          "dailyQuotaResetAtUnix":"1800050000",
          "weeklyQuotaRemainingPercent":40,
          "weeklyQuotaResetAtUnix":"1800300000"
        }}}
        """), now: now)

        XCTAssertEqual(snapshot.windows.map(\.kind), [.daily, .weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [100, 60])

        let hidden = try DevinUsageMapper.map(response: httpResponse(json: """
        {"userStatus":{"planStatus":{
          "planInfo":{"hideDailyQuota":true},
          "dailyQuotaRemainingPercent":75,
          "dailyQuotaResetAtUnix":"1800050000"
        }}}
        """), now: now)
        XCTAssertEqual(hidden.windows.map(\.kind), [.weekly])
        XCTAssertEqual(hidden.windows.map(\.usedPercent), [25])
        XCTAssertNil(hidden.windows.first?.resetsAt)

        XCTAssertThrowsError(try DevinUsageMapper.map(response: httpResponse(json: """
        {"userStatus":{"planStatus":{"weeklyQuotaRemainingPercent":"lots"}}}
        """), now: now))
    }

    func testGrokTeamAccountsExplainTheMissingQuota() {
        XCTAssertThrowsError(try GrokUsageMapper.map(
            response: httpResponse(412, json: #"{"error":"User has no personal team"}"#),
            planResponse: nil,
            now: now
        )) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.message,
                "Grok team accounts have no personal quota."
            )
        }
    }

    func testCopilotRateLimit403IsNotARejectedToken() async {
        let http = MockHTTPClient([
            httpResponse(403, headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "1800000600"
            ])
        ])
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(
                files: MemoryFiles([
                    CopilotAuthStore.editorAppsPath:
                        #"{"github.com:Iv1":{"oauth_token":"token"}}"#
                ]),
                keychain: MemoryKeychain()
            ),
            client: CopilotUsageClient(http: http),
            dateProvider: FixedDateProvider(value: now)
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected a rate limit")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .rateLimited)
            XCTAssertEqual(failure.retryAt, now.addingTimeInterval(600))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(CopilotProvider.isRateLimited(httpResponse(
            403,
            headers: ["Retry-After": "30"]
        )))
        XCTAssertFalse(CopilotProvider.isRateLimited(httpResponse(403)))
    }

    func testCursorShowsPersonalOnDemandSpendOnly() {
        XCTAssertEqual(
            CursorUsageMapper.onDemandUsage([
                "individualLimit": 5000,
                "individualUsed": 1250,
                "individualRemaining": 3750
            ]),
            .boundedSpend(usedAmount: 12.5, limitAmount: 50, currencyCode: "USD")
        )
        XCTAssertEqual(
            CursorUsageMapper.onDemandUsage(["totalSpend": 300]),
            .unboundedSpend(usedAmount: 3, currencyCode: "USD")
        )
        XCTAssertNil(CursorUsageMapper.onDemandUsage([
            "limitType": "team",
            "pooledLimit": 100_000,
            "pooledUsed": 2000
        ]))
        XCTAssertNil(CursorUsageMapper.onDemandUsage(["individualUsed": 0]))
        XCTAssertNil(CursorUsageMapper.onDemandUsage(nil))
    }

    func testRetryAfterIsHonoredUpToAnHour() {
        let long = ProviderParsing.retryDate(
            from: httpResponse(429, headers: ["Retry-After": "86400"]),
            now: now
        )
        let past = ProviderParsing.retryDate(
            from: httpResponse(429, headers: ["Retry-After": "-5"]),
            now: now
        )
        let missing = ProviderParsing.retryDate(from: httpResponse(429), now: now)

        XCTAssertEqual(long, now.addingTimeInterval(3_600))
        XCTAssertEqual(past, now)
        XCTAssertEqual(missing, now.addingTimeInterval(300))
    }

    private func oauth(
        subscriptionType: String? = "pro",
        rateLimitTier: String? = nil
    ) -> ClaudeOAuth {
        ClaudeOAuth(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            subscriptionType: subscriptionType,
            rateLimitTier: rateLimitTier,
            scopes: ["user:profile"]
        )
    }
}
