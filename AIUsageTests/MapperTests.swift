import XCTest
@testable import AIUsage

final class MapperTests: XCTestCase {
    func testClaudeMapsAllSupportedWindowsAndPlan() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = httpResponse(json: """
        {
          "five_hour": {"utilization": 12.5, "resets_at": "2027-01-15T12:00:00.123456"},
          "seven_day": {"utilization": 44, "resets_at": 1800100000},
          "seven_day_sonnet": {"utilization": 67, "resets_at": 1800200000000},
          "limits": [
            {
              "kind": "weekly_scoped",
              "scope": {"model": {"display_name": "Fable"}},
              "percent": 89,
              "resets_at": "2027-01-20T00:00:00Z"
            }
          ],
          "extra_usage": {
            "is_enabled": true,
            "used_credits": 9999,
            "monthly_limit": 20000,
            "utilization": 49.995,
            "currency": "USD"
          }
        }
        """)
        let oauth = ClaudeOAuth(
            accessToken: "token",
            refreshToken: "refresh",
            expiresAt: nil,
            subscriptionType: "PRO PLAN",
            rateLimitTier: "default_claude_max_20x",
            scopes: ["user:profile"]
        )

        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: oauth,
            now: now
        )

        XCTAssertEqual(snapshot.planName, "Pro Plan 20x")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .sonnet, .fable])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [12.5, 44, 67, 89])
        XCTAssertEqual(snapshot.creditUsage?.usedAmount, 99.99)
        XCTAssertEqual(snapshot.creditUsage?.limitAmount, 200)
        XCTAssertEqual(
            snapshot.creditUsage?.remainingAmount ?? -1,
            100.01,
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.creditUsage?.currencyCode, "USD")
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(
            snapshot.windows[1].resetsAt,
            Date(timeIntervalSince1970: 1_800_100_000)
        )
        XCTAssertEqual(
            snapshot.windows[2].resetsAt,
            Date(timeIntervalSince1970: 1_800_200_000)
        )
    }

    func testCodexClassifiesWeeklyInPrimaryAndMapsSpark() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = httpResponse(json: """
        {
          "plan_type": "prolite",
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "42.50"
          },
          "rate_limit": {
            "primary_window": {
              "used_percent": 73,
              "limit_window_seconds": 604800,
              "reset_at": 1800100000
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 101.4,
                  "limit_window_seconds": 18000,
                  "reset_after_seconds": 600
                },
                "secondary_window": {
                  "used_percent": 22,
                  "limit_window_seconds": 604800
                }
              }
            }
          ]
        }
        """)

        let snapshot = try CodexUsageMapper.map(response: response, now: now)

        XCTAssertEqual(snapshot.planName, "Pro 5x")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly, .sparkSession, .sparkWeekly])
        XCTAssertEqual(snapshot.creditUsage?.balanceAmount, 42.5)
        XCTAssertEqual(snapshot.creditUsage?.currencyCode, "USD")
        XCTAssertFalse(snapshot.creditUsage?.isUnlimited == true)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 73)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 101.4)
        XCTAssertEqual(snapshot.windows[1].renderedFraction, 1)
        XCTAssertEqual(
            snapshot.windows[1].resetsAt,
            now.addingTimeInterval(600)
        )
    }

    func testCodexFallsBackToPercentHeadersWhenBodyOmitsPercent() throws {
        let response = httpResponse(
            json: """
            {
              "rate_limit": {
                "primary_window": {"limit_window_seconds": 18000},
                "secondary_window": {"limit_window_seconds": 604800}
              }
            }
            """,
            headers: [
                "X-Codex-Primary-Used-Percent": "17.25",
                "x-codex-secondary-used-percent": "68"
            ]
        )

        let snapshot = try CodexUsageMapper.map(response: response, now: Date())

        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [17.25, 68])
    }

    func testCodexMapsUnlimitedCreditsWithoutBalance() throws {
        let response = httpResponse(json: """
        {
          "credits": {
            "has_credits": true,
            "unlimited": true,
            "balance": null
          }
        }
        """)

        let snapshot = try CodexUsageMapper.map(response: response, now: Date())

        XCTAssertTrue(snapshot.creditUsage?.isUnlimited == true)
        XCTAssertNil(snapshot.creditUsage?.balanceAmount)
    }

    func testCodexKeepsCreditAvailabilityWithoutBalance() throws {
        let response = httpResponse(json: """
        {
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": null
          }
        }
        """)

        let snapshot = try CodexUsageMapper.map(response: response, now: Date())

        XCTAssertNotNil(snapshot.creditUsage)
        XCTAssertNil(snapshot.creditUsage?.balanceAmount)
        XCTAssertFalse(snapshot.creditUsage?.isUnlimited == true)
    }

    func testClaudeOmitsDisabledExtraUsage() throws {
        let response = httpResponse(json: """
        {
          "extra_usage": {
            "is_enabled": false,
            "used_credits": 9999,
            "monthly_limit": 20000
          }
        }
        """)
        let oauth = ClaudeOAuth(
            accessToken: "token",
            refreshToken: nil,
            expiresAt: nil,
            subscriptionType: "pro",
            rateLimitTier: nil,
            scopes: ["user:profile"]
        )

        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: oauth,
            now: Date()
        )

        XCTAssertNil(snapshot.creditUsage)
    }

    func testParsingRejectsBooleanAsNumberAndEscapesFormValues() {
        XCTAssertNil(ProviderParsing.double(true))
        let body = String(
            data: ProviderParsing.formBody([("refresh_token", "a+b c&d")]),
            encoding: .utf8
        )
        XCTAssertEqual(body, "refresh_token=a%2Bb%20c%26d")
    }

    func testDateParserAcceptsProviderTimestampVariants() {
        XCTAssertNotNil(ProviderParsing.date("2027-01-15T12:00:00.123456"))
        XCTAssertNotNil(ProviderParsing.date("2027-01-15 12:00:00 UTC"))
        XCTAssertNotNil(ProviderParsing.date("2027-01-15T12:00:00+03:00"))
    }
}
