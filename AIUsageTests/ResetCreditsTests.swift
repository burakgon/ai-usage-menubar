import XCTest
@testable import AIUsage

final class ResetCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaudeCountsHeldResetsAndFiltersExpiredGrants() throws {
        let body = try ProviderParsing.object(from: Data("""
        {"eligible":true,"grants":[
          {"id":"future","resets_left":2,"ends_at":1800003600,"paused":true,"usable_now":false},
          {"id":"expired","resets_left":1,"ends_at":1799999999,"usable_now":true},
          {"id":"permanent","resets_left":1,"ends_at":null,"usable_now":true}
        ]}
        """.utf8))
        let credits = try XCTUnwrap(ResetCredits.claude(body))
        XCTAssertEqual(credits.remainingCount(at: now), 3)
        XCTAssertEqual(credits.activeGrants(at: now).map(\.id), ["future", "permanent"])
        XCTAssertEqual(credits.activeGrants(at: now).first?.isUsableNow, false)
        XCTAssertEqual(credits.remainingCount(at: now.addingTimeInterval(3600)), 1)
    }

    func testUnavailableDoesNotBecomeZeroOrNoExpiration() {
        XCTAssertNil(ResetCredits.claude(nil))
        XCTAssertNil(ResetCredits.claude(["eligible": false, "ineligible_reason": "surface"]))
        XCTAssertEqual(ResetCredits.claude(["ineligible_reason": "no_grant"])?.availableCount, 0)
        XCTAssertNil(ResetCredits.claude([
            "eligible": true, "grants": [["id": "bad", "resets_left": 1, "ends_at": "invalid"]]
        ]))
        XCTAssertNil(ResetCredits.codex(["available_count": true]))
        XCTAssertEqual(ResetCreditsPresentation(credits: nil, now: now).compactText, "↻—")
    }

    func testCodexKeepsSummaryWhenDetailsAreMissingOrPartial() throws {
        let summary = try XCTUnwrap(ResetCredits.codex(["available_count": 3]))
        XCTAssertEqual(summary.remainingCount(at: now), 3)
        XCTAssertNil(summary.grants)
        let partial = try XCTUnwrap(ResetCredits.codex([
            "available_count": 3,
            "credits": [["id": "one", "status": "available", "expires_at": 1800003600]]
        ]))
        XCTAssertEqual(partial.remainingCount(at: now), 3)
        XCTAssertTrue(ResetCreditsPresentation(credits: partial, now: now).detailText.contains("details unavailable"))
    }

    func testCodexOnlyShowsAvailableCreditsAndParsesFractionalExpiry() throws {
        let credits = try XCTUnwrap(ResetCredits.codex([
            "available_count": 1,
            "credits": [
                ["id": "active", "status": "available", "expires_at": "2027-01-15T09:00:00.123456Z"],
                ["id": "used", "status": "redeemed", "expires_at": NSNull()]
            ]
        ]))
        XCTAssertEqual(credits.grants?.count, 1)
        XCTAssertNotNil(credits.grants?.first?.expiresAt)
        let malformed = ResetCredits.codex([
            "available_count": 1,
            "credits": [["id": "bad", "status": "available", "expires_at": "bad"]]
        ])
        XCTAssertEqual(malformed?.availableCount, 1)
        XCTAssertNil(malformed?.grants)
    }

    func testCodexDetailsFailurePreservesUsageAndCurrentSummary() async throws {
        let http = MockHTTPClient([
            httpResponse(json: """
            {"rate_limit":{"primary_window":{"used_percent":35}},
             "rate_limit_reset_credits":{"available_count":2}}
            """),
            httpResponse(503)
        ])
        let auth = CodexAuth(tokens: CodexTokens(
            accessToken: jwt(expiration: now.timeIntervalSince1970 + 3600),
            refreshToken: nil, idToken: nil, accountID: "fixture-account"
        ), lastRefresh: nil, apiKey: nil)
        let date = FixedDateProvider(value: now)
        let provider = CodexProvider(authStore: CodexAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(["~/.config/codex/auth.json": encodedJSON(auth)]),
            keychain: MemoryKeychain(), dateProvider: date
        ), client: CodexUsageClient(http: http), dateProvider: date)
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 35)
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 2)
        XCTAssertNil(snapshot.resetCredits?.grants)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.method == .get })
        XCTAssertEqual(requests.last?.headers["ChatGPT-Account-Id"], "fixture-account")
    }

    func testCodexDetailsSuccessSupersedesUsageSummary() async throws {
        let http = MockHTTPClient([
            httpResponse(json: """
            {"rate_limit":{"primary_window":{"used_percent":35}},
             "rate_limit_reset_credits":{"available_count":3}}
            """),
            httpResponse(json: """
            {"available_count":1,"credits":[
              {"id":"fixture-reset","status":"available","expires_at":"2027-01-15T12:00:00.123456Z"}
            ]}
            """)
        ])
        let auth = CodexAuth(tokens: CodexTokens(
            accessToken: jwt(expiration: now.timeIntervalSince1970 + 3600),
            refreshToken: nil, idToken: nil, accountID: "fixture-account"
        ), lastRefresh: nil, apiKey: nil)
        let date = FixedDateProvider(value: now)
        let provider = CodexProvider(authStore: CodexAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(["~/.config/codex/auth.json": encodedJSON(auth)]),
            keychain: MemoryKeychain(), dateProvider: date
        ), client: CodexUsageClient(http: http), dateProvider: date)
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 1)
        XCTAssertEqual(snapshot.resetCredits?.grants?.count, 1)
        XCTAssertNotNil(snapshot.resetCredits?.grants?.first?.expiresAt)
        XCTAssertEqual(snapshot.sessionWindow?.usedPercent, 35)
    }

    func testResetMetricIsIndependentOfUsedRemainingMode() {
        var snapshot = ProviderSnapshot(provider: .claude, planName: nil, windows: [], fetchedAt: now)
        snapshot.resetCredits = ResetCredits(availableCount: 2, grants: nil)
        XCTAssertTrue(snapshot.availableMenuBarItems.contains(MenuBarItemID(provider: .claude, metric: .extraResets)))
        XCTAssertEqual(snapshot.menuBarValue(for: .extraResets, displayMode: .used),
                       snapshot.menuBarValue(for: .extraResets, displayMode: .remaining))
    }
}
