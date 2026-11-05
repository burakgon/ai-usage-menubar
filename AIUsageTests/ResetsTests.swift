import XCTest
@testable import AIUsage

final class ResetsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Claude

    func testClaudeGrantsCountUnexpiredResetsWithTheirExpirations() throws {
        let grants = try XCTUnwrap(ClaudeResetGrants.parse(json("""
        {
          "eligible": true,
          "grants": [
            {"id": "a", "resets_left": 2, "ends_at": 1800172800},
            {"id": "b", "resets_left": 1, "ends_at": "2027-03-01T00:00:00Z"},
            {"id": "c", "resets_left": 1, "ends_at": 1799996400},
            {"id": "d", "resets_left": 0, "ends_at": 1800172800},
            {"id": "e", "resets_left": 1, "ends_at": null}
          ]
        }
        """)))

        let resets = grants.resets(at: now)

        XCTAssertEqual(resets.availableCount, 4)
        XCTAssertEqual(resets.expirations.count, 3)
        XCTAssertEqual(resets.nextExpiration, Date(timeIntervalSince1970: 1_800_172_800))
        XCTAssertTrue(resets.hasUnknownExpirations)
    }

    func testClaudeGrantsTellZeroFromUnknown() {
        let none = ClaudeResetGrants.parse(json("""
        {"eligible": false, "ineligible_reason": "no_grant", "grants": []}
        """))
        XCTAssertEqual(none?.resets(at: now).availableCount, 0)

        for block in [
            #"{"eligible": false, "ineligible_reason": "surface", "grants": []}"#,
            #"{"eligible": false, "ineligible_reason": "cli_version"}"#,
            #"{"eligible": true, "grants": [{"resets_left": 1}]}"#,
            #"{"eligible": true}"#
        ] {
            XCTAssertNil(ClaudeResetGrants.parse(json(block)), block)
        }
        XCTAssertNil(ClaudeResetGrants.parse(nil))
    }

    func testClaudeReadsResetGrantsHourlyWithinTheUsageRead() async throws {
        let date = MutableDateProvider(now)
        let http = RoutedHTTPClient([
            ClaudeAuthStore.usageWithResetGrantsURL.absoluteString: [
                httpResponse(json: """
                {"seven_day":{"utilization":87},
                 "cedar_ember":{"eligible":true,"grants":[
                   {"id":"g","resets_left":2,"ends_at":1800172800}]}}
                """)
            ],
            ClaudeAuthStore.usageURL.absoluteString: [
                httpResponse(json: #"{"seven_day":{"utilization":88}}"#)
            ]
        ])
        let provider = makeClaudeProvider(http: http, date: date)

        let first = try await provider.fetch()
        date.advance(by: 300)
        let second = try await provider.fetch()
        date.advance(by: 3_600)
        _ = try await provider.fetch()

        XCTAssertEqual(first.resets?.availableCount, 2)
        XCTAssertEqual(second.resets, first.resets)
        XCTAssertEqual(second.windows.first?.usedPercent, 88)
        let urls = await http.capturedRequests().map(\.url)
        XCTAssertEqual(urls, [
            ClaudeAuthStore.usageWithResetGrantsURL,
            ClaudeAuthStore.usageURL,
            ClaudeAuthStore.usageWithResetGrantsURL
        ])
    }

    func testThrottledGrantsReadFallsBackToPlainReadsAndBacksOff() async throws {
        let date = MutableDateProvider(now)
        let http = RoutedHTTPClient([
            ClaudeAuthStore.usageWithResetGrantsURL.absoluteString: [httpResponse(429)],
            ClaudeAuthStore.usageURL.absoluteString: [
                httpResponse(429),
                httpResponse(json: #"{"seven_day":{"utilization":10}}"#)
            ]
        ])
        let provider = makeClaudeProvider(http: http, date: date)

        let first = await failure(of: provider)
        XCTAssertEqual(first?.retryAt, now.addingTimeInterval(300))

        date.advance(by: 301)
        let second = await failure(of: provider)
        XCTAssertEqual(second?.kind, .rateLimited)
        // The second consecutive limit waits twice as long.
        XCTAssertEqual(second?.retryAt, date.now().addingTimeInterval(600))

        date.advance(by: 601)
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 10)
        XCTAssertNil(snapshot.resets)

        let urls = await http.capturedRequests().map(\.url)
        XCTAssertEqual(urls, [
            ClaudeAuthStore.usageWithResetGrantsURL,
            ClaudeAuthStore.usageURL,
            ClaudeAuthStore.usageURL
        ])
    }

    func testClaudeBackoffGrowsToAnHour() {
        XCTAssertEqual(ClaudeProvider.backoff(strikes: 1), 300)
        XCTAssertEqual(ClaudeProvider.backoff(strikes: 2), 600)
        XCTAssertEqual(ClaudeProvider.backoff(strikes: 4), 2_400)
        XCTAssertEqual(ClaudeProvider.backoff(strikes: 9), 3_600)
    }

    // MARK: - Codex

    func testCodexUsesTheCurrentCountAndAMatchingListsExpirations() {
        let list = CodexResetCreditList.parse(Data("""
        {
          "available_count": 3,
          "credits": [
            {"id": "a", "status": "available", "expires_at": "2026-11-30T19:50:48.126987Z"},
            {"id": "b", "status": "available", "expires_at": "2026-11-06T23:19:54.760761Z"},
            {"id": "c", "status": "redeemed", "expires_at": "2026-11-01T00:00:00Z"},
            {"id": "d", "status": "available", "expires_at": "2026-12-01T22:25:27.226248Z"}
          ]
        }
        """.utf8))

        let matching = CodexUsageMapper.resets(embeddedCount: 3, list: list)
        XCTAssertEqual(matching?.availableCount, 3)
        XCTAssertEqual(matching?.expirations.count, 3)
        XCTAssertEqual(
            matching?.nextExpiration,
            ProviderParsing.date("2026-11-06T23:19:54.760761Z")
        )

        let stale = CodexUsageMapper.resets(embeddedCount: 2, list: list)
        XCTAssertEqual(stale, UsageResets(availableCount: 2))
        XCTAssertNil(CodexUsageMapper.resets(embeddedCount: nil, list: nil))
        XCTAssertEqual(CodexUsageMapper.resets(embeddedCount: nil, list: list)?.availableCount, 3)
    }

    func testCodexReadsTheResetListOnlyWhenItCanChangeTheAnswer() async throws {
        let date = MutableDateProvider(now)
        let usage = { (count: Int) in
            httpResponse(json: """
            {"plan_type":"pro",
             "rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800}},
             "rate_limit_reset_credits":{"available_count":\(count)}}
            """)
        }
        let http = RoutedHTTPClient([
            CodexUsageClient.usageURL.absoluteString: [usage(2), usage(2), usage(1), usage(1)],
            CodexUsageClient.resetCreditsURL.absoluteString: [
                httpResponse(json: """
                {"available_count":2,"credits":[
                  {"id":"a","status":"available","expires_at":1800090000},
                  {"id":"b","status":"available","expires_at":1800190000}]}
                """),
                httpResponse(json: """
                {"available_count":1,"credits":[
                  {"id":"b","status":"available","expires_at":1800190000}]}
                """)
            ]
        ])
        let provider = makeCodexProvider(http: http, date: date)

        let first = try await provider.fetch()
        XCTAssertEqual(first.resets?.availableCount, 2)
        XCTAssertEqual(first.resets?.expirations.count, 2)

        date.advance(by: 60)
        _ = try await provider.fetch()

        // The count changed: until the list is re-read, no stale expiration
        // stands in for the reset that was spent.
        date.advance(by: 60)
        let changed = try await provider.fetch()
        XCTAssertEqual(changed.resets, UsageResets(availableCount: 1))

        date.advance(by: 300)
        let reread = try await provider.fetch()
        XCTAssertEqual(reread.resets?.expirations, [Date(timeIntervalSince1970: 1_800_190_000)])

        let requests = await http.capturedRequests()
        let listReads = requests.filter { $0.url == CodexUsageClient.resetCreditsURL }
        XCTAssertEqual(listReads.count, 2)
        XCTAssertEqual(listReads.first?.headers["OpenAI-Beta"], "codex-1")
        XCTAssertEqual(listReads.first?.headers["originator"], "Codex Desktop")
        XCTAssertEqual(listReads.first?.headers["ChatGPT-Account-Id"], "account-1")
    }

    func testCodexWithoutBankedResetsMakesNoListRequest() async throws {
        let http = RoutedHTTPClient([
            CodexUsageClient.usageURL.absoluteString: [httpResponse(json: """
            {"rate_limit":{"primary_window":{"used_percent":5}},
             "rate_limit_reset_credits":{"available_count":0}}
            """)]
        ])

        let snapshot = try await makeCodexProvider(
            http: http,
            date: MutableDateProvider(now)
        ).fetch()

        XCTAssertEqual(snapshot.resets, UsageResets(availableCount: 0))
        XCTAssertTrue(snapshot.hasPanelContent)
        let urls = await http.capturedRequests().map(\.url)
        XCTAssertEqual(urls, [CodexUsageClient.usageURL])
    }

    // MARK: - Presentation

    func testResetsPresentationWarnsBeforeTheNextExpiration() {
        let resets = UsageResets(
            availableCount: 3,
            expirations: [
                now.addingTimeInterval(23 * 3_600),
                now.addingTimeInterval(10 * 86_400)
            ]
        )

        let presentation = ResetsPresentation(
            resets: resets,
            now: now,
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(presentation.valueText, "3 available")
        XCTAssertEqual(presentation.expiryText, "next expires in 23h 1m")
        XCTAssertTrue(presentation.isExpiringSoon)
        XCTAssertTrue(presentation.helpText.contains("1 reset without a known expiration"))
        XCTAssertEqual(
            presentation.helpText.components(separatedBy: "Expires ").count - 1,
            2
        )

        let later = ResetsPresentation(resets: resets, now: now.addingTimeInterval(24 * 3_600))
        XCTAssertEqual(later.valueText, "2 available")
        XCTAssertFalse(later.isExpiringSoon)
    }

    func testResetsMenuBarValueIsSelfDescribingWithoutAMicroLabel() {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            planName: nil,
            windows: [QuotaWindow(kind: .weekly, usedPercent: 40, resetsAt: nil)],
            resets: UsageResets(availableCount: 3),
            fetchedAt: now
        )
        XCTAssertEqual(
            snapshot.availableMenuBarItems.map(\.metric),
            [.weekly, .resets]
        )

        let readings = [MenuBarMetricID.weekly, .resets].compactMap { metric in
            snapshot.menuBarValue(for: metric, displayMode: .remaining).map {
                MenuBarReading(
                    provider: .codex,
                    metric: metric,
                    value: $0,
                    displayMode: .remaining,
                    isStale: false
                )
            }
        }
        let presentation = MenuBarProviderPresentation(group: MenuBarProviderReadings(
            provider: .codex,
            selectedMetrics: [.weekly, .resets],
            readings: readings
        ))

        XCTAssertEqual(presentation.metrics.map(\.label), ["W", nil])
        XCTAssertEqual(presentation.metrics.map(\.valueText), ["60%", "↻3"])
        XCTAssertNil(presentation.sharedSuffix)
        XCTAssertEqual(
            MenuBarPresentation(reading: readings[1]).accessibilityLabel,
            "Codex 3 usage limit resets available"
        )
    }

    // MARK: - Helpers

    private func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func makeClaudeProvider(
        http: HTTPClient,
        date: MutableDateProvider
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: MockEnvironment(),
                files: MemoryFiles(),
                keychain: claudeKeychain(expiresAt: now.addingTimeInterval(86_400)),
                dateProvider: date
            ),
            client: ClaudeUsageClient(http: http),
            dateProvider: date
        )
    }

    private func makeCodexProvider(
        http: HTTPClient,
        date: MutableDateProvider
    ) -> CodexProvider {
        let auth = CodexAuth(
            tokens: CodexTokens(
                accessToken: jwt(expiration: now.timeIntervalSince1970 + 86_400),
                refreshToken: "refresh",
                idToken: nil,
                accountID: "account-1"
            ),
            lastRefresh: nil,
            apiKey: nil
        )
        return CodexProvider(
            authStore: CodexAuthStore(
                environment: MockEnvironment(),
                files: MemoryFiles(["~/.config/codex/auth.json": encodedJSON(auth)]),
                keychain: MemoryKeychain(),
                dateProvider: date
            ),
            client: CodexUsageClient(http: http),
            dateProvider: date
        )
    }

    private func failure(of provider: ClaudeProvider) async -> ProviderFailure? {
        do {
            _ = try await provider.fetch()
            XCTFail("Expected a failure")
            return nil
        } catch let failure as ProviderFailure {
            return failure
        } catch {
            XCTFail("Unexpected error: \(error)")
            return nil
        }
    }
}
