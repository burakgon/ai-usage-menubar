import XCTest
@testable import AIUsage

final class AntigravityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let prod = "https://cloudcode-pa.googleapis.com"
    private let daily = "https://daily-cloudcode-pa.googleapis.com"

    // MARK: - Mapper

    func testSummaryMergesPoolsAcrossHostsWithTheFirstAnswerWinning() throws {
        let dailyHost = summary("""
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,
           "resetTime":"2027-01-15T12:00:00Z"},
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.25}
        ]},
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-5h","window":"5h","remainingFraction":0.9}
        ]}
        """)
        let production = summary("""
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":1,
           "resetTime":"2027-01-15T15:00:00Z"}
        ]},
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-5h","window":"5h","remainingFraction":0.1},
          {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.8}
        ]}
        """)

        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            [dailyHost, production],
            planName: "Google AI Pro",
            now: now
        ))

        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.session, .weekly, .claudePool, .claudePoolWeekly]
        )
        // Only Claude Weekly, which the first body leaves out, comes from
        // the second.
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [50, 75, 10, 20])
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            ProviderParsing.date("2027-01-15T12:00:00Z")
        )
        XCTAssertEqual(snapshot.planName, "Google AI Pro")
    }

    func testArgonWeeklyComesFromItsGroupOrKnownBucket() throws {
        let byGroup = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
        {"displayName":"Gemini 4 Argon","buckets":[
          {"bucketId":"test-weekly","window":"weekly","remainingFraction":0.25},
          {"bucketId":"test-5h","window":"5h","remainingFraction":0}
        ]},
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.6}
        ]},
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.5}
        ]}
        """)], planName: nil, now: now))
        XCTAssertEqual(
            byGroup.windows.map(\.kind),
            [.weekly, .argonWeekly, .claudePoolWeekly]
        )
        XCTAssertEqual(byGroup.windows.map(\.usedPercent), [40, 75, 50])

        let byIdentifier = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-argon-wtu-weekly","remainingFraction":0.8,
           "resetTime":"2027-01-20T00:00:00Z"}
        ]}
        """)], planName: nil, now: now))
        XCTAssertEqual(byIdentifier.windows.map(\.kind), [.argonWeekly])
        XCTAssertEqual(byIdentifier.windows.map(\.usedPercent), [20])
        XCTAssertEqual(
            byIdentifier.windows[0].startsAt,
            ProviderParsing.date("2027-01-20T00:00:00Z")?.addingTimeInterval(-604_800)
        )
    }

    func testAmbiguousOrDisabledArgonIsNotShown() throws {
        let cases = [
            """
            {"bucketId":"first","window":"weekly","remainingFraction":0.9},
            {"bucketId":"second","window":"weekly","remainingFraction":0.1}
            """,
            #"{"bucketId":"only","window":"weekly","remainingFraction":0.5,"disabled":true}"#,
            #"{"bucketId":"only","window":"weekly","remainingFraction":0.5,"disabled":"no"}"#,
            #"{"bucketId":"only","window":"weekly"}"#
        ]
        for buckets in cases {
            let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
            {"displayName":"Gemini 4 Argon","buckets":[\(buckets)]}
            """)], planName: nil, now: now))
            XCTAssertEqual(snapshot.windows, [], buckets)
        }
    }

    func testBucketWithoutAFractionIsDroppedInsteadOfInvented() throws {
        let snapshot = try XCTUnwrap(AntigravityUsageMapper.summary([summary("""
        {"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.75},
          {"bucketId":"gemini-weekly","resetTime":"2027-01-15T12:00:00Z"}
        ]}
        """)], planName: nil, now: now))

        XCTAssertEqual(snapshot.windows.map(\.kind), [.session])
        XCTAssertNil(AntigravityUsageMapper.summary(
            [Data(#"{"models":{}}"#.utf8)],
            planName: nil,
            now: now
        ))
    }

    func testCompleteSummaryNeedsEverySharedPool() {
        XCTAssertTrue(AntigravityUsageMapper.isCompleteSummary(completeSummary))
        XCTAssertFalse(AntigravityUsageMapper.isCompleteSummary(summary("""
        {"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-5h","remainingFraction":1},
          {"bucketId":"3p-weekly","remainingFraction":1}
        ]}
        """)))
    }

    func testPlanUsesThePaidTierAndProjectComesFromCodeAssist() {
        let paid = Data("""
        {
          "currentTier": {"id": "free-tier", "name": "Antigravity"},
          "paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"},
          "cloudaicompanionProject": "project-1"
        }
        """.utf8)
        XCTAssertEqual(AntigravityUsageMapper.plan(paid), "Google AI Pro")
        XCTAssertEqual(AntigravityUsageMapper.project(paid), "project-1")

        let unknownPaid = Data(
            #"{"paidTier":{"id":"g1-new","name":"Google AI Ultra for Business"}}"#.utf8
        )
        XCTAssertEqual(AntigravityUsageMapper.plan(unknownPaid), "Google AI Ultra")

        let free = Data(#"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#.utf8)
        XCTAssertEqual(AntigravityUsageMapper.plan(free), "Free")

        let unnamed = Data(#"{"currentTier":{"id":"standard-tier","name":"Antigravity"}}"#.utf8)
        XCTAssertNil(AntigravityUsageMapper.plan(unnamed))
        XCTAssertNil(AntigravityUsageMapper.project(unnamed))
    }

    // MARK: - Cloud Code client

    func testQuotaSummaryUsesTheClientIdentityAndStopsWhenTheDailyHostIsComplete() async {
        let http = RoutedHTTPClient([
            daily + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: untouchedJSON)]
        ])
        let client = AntigravityUsageClient(http: http)

        let outcome = await client.quotaSummary(
            accessToken: "token",
            project: "project-1",
            now: now
        )

        guard case let .success(bodies) = outcome else {
            return XCTFail("Expected a summary, got \(outcome)")
        }
        XCTAssertEqual(bodies, [completeSummary])
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            daily + AntigravityUsageClient.summaryPath
        ])
        XCTAssertEqual(requests[0].headers["User-Agent"], AntigravityUsageClient.userAgent)
        // The hub identity is the one Google answers with the Argon group.
        XCTAssertTrue(AntigravityUsageClient.userAgent.hasPrefix("antigravity/hub/"))
        let body = try? JSONSerialization.jsonObject(
            with: requests[0].body ?? Data()
        ) as? [String: String]
        XCTAssertEqual(body, ["project": "project-1"])
    }

    func testQuotaSummaryAsksProductionWhenTheDailyHostIsIncomplete() async {
        let incomplete = """
        {"groups":[{"buckets":[{"bucketId":"3p-weekly","remainingFraction":1}]}]}
        """
        let http = RoutedHTTPClient([
            daily + AntigravityUsageClient.summaryPath: [httpResponse(json: incomplete)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)]
        ])

        let outcome = await AntigravityUsageClient(http: http).quotaSummary(
            accessToken: "token",
            project: nil,
            now: now
        )

        guard case let .success(bodies) = outcome else {
            return XCTFail("Expected summaries, got \(outcome)")
        }
        // The daily host's answer stays first, so its pools win the merge.
        XCTAssertEqual(bodies, [Data(incomplete.utf8), completeSummary])
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            daily + AntigravityUsageClient.summaryPath,
            prod + AntigravityUsageClient.summaryPath
        ])
        XCTAssertEqual(requests.first?.body, Data("{}".utf8))
    }

    func testProductionDoesNotStandInForADailyHostThatIsTemporarilyOut() async {
        // Production would answer with every window untouched, which reads
        // as a fresh 100% left.
        func outcome(
            daily response: HTTPResponse?
        ) async -> (AntigravitySummaryOutcome, [String]) {
            var routes = [
                prod + AntigravityUsageClient.summaryPath: [httpResponse(json: untouchedJSON)]
            ]
            if let response {
                routes[daily + AntigravityUsageClient.summaryPath] = [response]
            }
            let http = RoutedHTTPClient(routes)
            let outcome = await AntigravityUsageClient(http: http).quotaSummary(
                accessToken: "token",
                project: nil,
                now: now
            )
            return (outcome, await http.capturedRequests().map(\.url.absoluteString))
        }

        for response in [nil, httpResponse(503), httpResponse(408)] {
            let (result, requests) = await outcome(daily: response)
            guard case .unavailable = result else {
                return XCTFail("Expected a temporary failure, got \(result)")
            }
            XCTAssertEqual(requests, [daily + AntigravityUsageClient.summaryPath])
        }

        let (limited, requests) = await outcome(
            daily: httpResponse(429, headers: ["Retry-After": "90"])
        )
        guard case let .rateLimited(retryAt) = limited else {
            return XCTFail("Expected a rate limit, got \(limited)")
        }
        XCTAssertEqual(retryAt, now.addingTimeInterval(90))
        XCTAssertEqual(requests, [daily + AntigravityUsageClient.summaryPath])
    }

    func testProductionAnswersForADailyHostThatDeclinesToShare() async {
        let http = RoutedHTTPClient([
            daily + AntigravityUsageClient.summaryPath: [httpResponse(403)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)]
        ])

        let outcome = await AntigravityUsageClient(http: http).quotaSummary(
            accessToken: "token",
            project: nil,
            now: now
        )

        guard case let .success(bodies) = outcome else {
            return XCTFail("Expected production's summary, got \(outcome)")
        }
        XCTAssertEqual(bodies, [completeSummary])
    }

    func testAnOutageOnTheDailyHostKeepsTheLastReading() async {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: "{}")],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(503)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: untouchedJSON)]
        ])

        // A temporary failure keeps the last reading and marks it stale.
        await assertFailure(makeProvider(http: http), kind: .transient)
    }

    func testQuotaSummarySeparatesDenialRefusalAndRateLimits() async {
        func outcome(_ status: Int, headers: [String: String] = [:]) async
            -> AntigravitySummaryOutcome {
            let http = RoutedHTTPClient([
                prod + AntigravityUsageClient.summaryPath: [
                    httpResponse(status, headers: headers)
                ],
                daily + AntigravityUsageClient.summaryPath: [
                    httpResponse(status, headers: headers)
                ]
            ])
            return await AntigravityUsageClient(http: http).quotaSummary(
                accessToken: "token",
                project: nil,
                now: now
            )
        }

        guard case .denied = await outcome(403) else {
            return XCTFail("403 must be a denial, not a sign-in failure")
        }
        guard case .tokenRefused = await outcome(401) else {
            return XCTFail("401 must refuse the token")
        }
        guard case let .rateLimited(retryAt) = await outcome(
            429,
            headers: ["Retry-After": "90"]
        ) else {
            return XCTFail("429 must be a rate limit")
        }
        XCTAssertEqual(retryAt, now.addingTimeInterval(90))
        guard case .unavailable = await outcome(503) else {
            return XCTFail("503 must be unavailable")
        }
    }

    func testCodeAssistFallsThroughToTheDailyHostAfterAProductionDenial() async {
        let fallthroughHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(403)],
            daily + AntigravityUsageClient.planPath: [httpResponse(json: "{}")]
        ])
        let outcome = await AntigravityUsageClient(http: fallthroughHTTP)
            .loadCodeAssist(accessToken: "token")
        guard case .success = outcome else {
            return XCTFail("403 on production must not end the host loop")
        }

        let deniedHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(403)],
            daily + AntigravityUsageClient.planPath: [httpResponse(403)]
        ])
        let denied = await AntigravityUsageClient(http: deniedHTTP)
            .loadCodeAssist(accessToken: "token")
        guard case .denied = denied else {
            return XCTFail("403 on every host is a denial, not a sign-in failure")
        }
    }

    func testQuotaSummaryDoesNotReportDenialWhenAHostIsUnreachable() async {
        let partialHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)]
        ])
        let partial = await AntigravityUsageClient(http: partialHTTP)
            .quotaSummary(accessToken: "token", project: nil, now: now)
        guard case .unavailable = partial else {
            return XCTFail("A 403 from one of two unreachable hosts is transient")
        }

        let mixedHTTP = RoutedHTTPClient([
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(503)]
        ])
        let mixed = await AntigravityUsageClient(http: mixedHTTP)
            .quotaSummary(accessToken: "token", project: nil, now: now)
        guard case .unavailable = mixed else {
            return XCTFail("403 plus a failing host is transient, not a denial")
        }
    }

    func testCodeAssistSendsTheClientMetadata() async throws {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: "{}")]
        ])

        _ = await AntigravityUsageClient(http: http).loadCodeAssist(accessToken: "token")

        let requests = await http.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.body, AntigravityUsageClient.codeAssistPayload)
        XCTAssertEqual(request.headers["User-Agent"], AntigravityUsageClient.userAgent)
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
    }

    // MARK: - Provider

    func testProviderReadsCloudQuotaWithPlanAndNeverTheModelList() async throws {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: """
            {"paidTier":{"id":"g1-ultra-tier"},"cloudaicompanionProject":"p"}
            """)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)]
        ])
        let provider = makeProvider(http: http)

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.planName, "Google AI Ultra")
        XCTAssertEqual(snapshot.windows.count, 4)
        let urls = await http.capturedRequests().map(\.url.absoluteString)
        XCTAssertFalse(urls.contains { $0.contains("fetchAvailableModels") })

        // The plan and project are read hourly, not on every refresh.
        _ = try await provider.fetch()
        let planReads = await http.capturedRequests()
            .filter { $0.url.path.hasSuffix("loadCodeAssist") }
        XCTAssertEqual(planReads.count, 1)
    }

    func testProviderShowsTheDailyHostsCountersNotProductionsUntouchedWindows() async throws {
        // What the two hosts answered for one account with real usage:
        // production reported every window full and resetting one whole
        // window from now.
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: """
            {"paidTier":{"id":"g1-pro-tier"},"cloudaicompanionProject":"p"}
            """)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(json: """
            {"groups":[
              {"displayName":"Gemini Models","buckets":[
                {"bucketId":"gemini-weekly","window":"weekly",
                 "remainingFraction":0.9574321,"resetTime":"2027-01-20T23:11:14Z"},
                {"bucketId":"gemini-5h","window":"5h",
                 "remainingFraction":0.8951,"resetTime":"2027-01-15T04:06:00Z"}
              ]},
              {"displayName":"Claude and GPT models","buckets":[
                {"bucketId":"3p-weekly","window":"weekly",
                 "remainingFraction":1,"resetTime":"2027-01-22T00:00:00Z"},
                {"bucketId":"3p-5h","window":"5h",
                 "remainingFraction":1,"resetTime":"2027-01-15T05:00:00Z"}
              ]},
              {"displayName":"Gemini 4 Argon","buckets":[
                {"bucketId":"gemini-argon-wtu-weekly","window":"weekly",
                 "remainingFraction":1,"resetTime":"2027-01-22T00:00:00Z"}
              ]}
            ]}
            """)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(json: untouchedJSON)]
        ])

        let snapshot = try await makeProvider(http: http).fetch()

        XCTAssertEqual(
            snapshot.windows.map(\.kind),
            [.session, .weekly, .argonWeekly, .claudePool, .claudePoolWeekly]
        )
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [10, 4, 0, 0, 0])
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            ProviderParsing.date("2027-01-15T04:06:00Z")
        )
        XCTAssertEqual(
            snapshot.windows[1].resetsAt,
            ProviderParsing.date("2027-01-20T23:11:14Z")
        )
        let summaryReads = await http.capturedRequests()
            .map(\.url.absoluteString)
            .filter { $0.hasSuffix(AntigravityUsageClient.summaryPath) }
        XCTAssertEqual(summaryReads, [daily + AntigravityUsageClient.summaryPath])
    }

    func testRefusedTokenIsRenewedOnceAndCached() async throws {
        let files = MemoryFiles()
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [
                httpResponse(401),
                httpResponse(json: "{}")
            ],
            AntigravityUsageClient.googleOAuthURL.absoluteString: [
                httpResponse(json: #"{"access_token":"fresh","expires_in":3600}"#)
            ],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(json: completeJSON)]
        ])
        let provider = makeProvider(http: http, files: files)

        _ = try await provider.fetch()

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer fresh")
        XCTAssertNotNil(files.value(at: AntigravityAuthStore.cachePath))
    }

    func testDeniedQuotaFallsBackToTheRunningCLI() async throws {
        let cloud = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: """
            {"paidTier":{"id":"g1-pro-tier"}}
            """)],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(403)]
        ])
        let loopback = RoutedHTTPClient([
            "https://127.0.0.1:5555" + AntigravityLocalClient.summaryPath: [
                httpResponse(json: """
                {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
                  {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.3868888}
                ]}]}}
                """)
            ]
        ])
        let inspector = FixedProcessInspector(
            running: [LocalProcess(pid: 10, executablePath: "/usr/local/bin/agy")],
            commandLines: [
                10: ProcessCommandLine(arguments: ["agy"], environment: []),
                11: ProcessCommandLine(
                    arguments: ["bash"],
                    environment: ["ANTIGRAVITY_CSRF_TOKEN=csrf-1"]
                )
            ],
            childProcesses: [10: [11]],
            ports: [10: [5555]]
        )
        let provider = makeProvider(
            http: cloud,
            local: AntigravityLocalClient(inspector: inspector, http: loopback)
        )

        let snapshot = try await provider.fetch()

        XCTAssertEqual(snapshot.windows.map(\.kind), [.weekly])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [61])
        XCTAssertEqual(snapshot.planName, "Google AI Pro")
        let local = await loopback.capturedRequests()
        XCTAssertEqual(local.first?.headers["X-Codeium-Csrf-Token"], "csrf-1")
    }

    func testDeniedQuotaWithoutALocalToolKeepsTheLastReading() async {
        let http = RoutedHTTPClient([
            prod + AntigravityUsageClient.planPath: [httpResponse(json: "{}")],
            prod + AntigravityUsageClient.summaryPath: [httpResponse(403)],
            daily + AntigravityUsageClient.summaryPath: [httpResponse(403)]
        ])

        await assertFailure(makeProvider(http: http), kind: .transient)
    }

    func testRejectedRefreshTokenIsAnExpiredSignIn() async {
        let http = RoutedHTTPClient([
            AntigravityUsageClient.googleOAuthURL.absoluteString: [
                httpResponse(400, json: #"{"error":"invalid_grant"}"#)
            ]
        ])
        let provider = makeProvider(http: http, expiry: "2020-01-01T00:00:00Z")

        await assertFailure(provider, kind: .authentication)
    }

    func testUnavailableRefreshIsTransient() async {
        let http = RoutedHTTPClient([
            AntigravityUsageClient.googleOAuthURL.absoluteString: [httpResponse(503)]
        ])
        let provider = makeProvider(http: http, expiry: "2020-01-01T00:00:00Z")

        await assertFailure(provider, kind: .transient)
    }

    // MARK: - Local discovery

    func testEndpointsUseTheAppTokenAndSkipOtherEditors() {
        let inspector = FixedProcessInspector(
            running: [
                LocalProcess(
                    pid: 1,
                    executablePath: "/Applications/Windsurf.app/Contents/Resources/bin/language_server_macos_arm"
                ),
                LocalProcess(
                    pid: 2,
                    executablePath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
                ),
                LocalProcess(pid: 3, executablePath: "/opt/homebrew/bin/agy"),
                LocalProcess(pid: 4, executablePath: "/usr/bin/ssh")
            ],
            commandLines: [
                1: ProcessCommandLine(
                    arguments: ["language_server", "--ide_name", "windsurf", "--csrf_token", "other"],
                    environment: []
                ),
                2: ProcessCommandLine(
                    arguments: [
                        "language_server", "--csrf_token=app-token",
                        "--extension_server_port", "7777"
                    ],
                    environment: []
                ),
                3: ProcessCommandLine(
                    arguments: ["agy"],
                    environment: ["ANTIGRAVITY_CSRF_TOKEN=cli-token"]
                )
            ],
            ports: [1: [5000], 2: [6000], 3: [6100]]
        )

        let endpoints = AntigravityLocalClient(inspector: inspector).endpoints()

        XCTAssertEqual(endpoints.map(\.url.absoluteString), [
            "https://127.0.0.1:6000" + AntigravityLocalClient.summaryPath,
            "http://127.0.0.1:6000" + AntigravityLocalClient.summaryPath,
            "http://127.0.0.1:7777" + AntigravityLocalClient.summaryPath,
            "https://127.0.0.1:6100" + AntigravityLocalClient.summaryPath,
            "http://127.0.0.1:6100" + AntigravityLocalClient.summaryPath
        ])
        XCTAssertEqual(
            endpoints.map(\.csrfToken),
            ["app-token", "app-token", "app-token", "cli-token", "cli-token"]
        )
    }

    func testParsesProcessArgumentsAndEnvironment() throws {
        var bytes = withUnsafeBytes(of: Int32(3).littleEndian) { Array($0) }
        bytes += Array("/usr/local/bin/agy".utf8) + [0, 0, 0, 0]
        for value in ["agy", "", "--flag", "A=1", "ANTIGRAVITY_CSRF_TOKEN=secret", ""] {
            bytes += Array(value.utf8) + [0]
        }
        bytes += [0, 0]

        let commandLine = try XCTUnwrap(
            SystemProcessInspector.parseCommandLine(bytes)
        )

        XCTAssertEqual(commandLine.arguments, ["agy", "", "--flag"])
        XCTAssertEqual(commandLine.environment, ["A=1", "ANTIGRAVITY_CSRF_TOKEN=secret"])
        XCTAssertEqual(commandLine.environmentValue("ANTIGRAVITY_CSRF_TOKEN"), "secret")
        XCTAssertNil(commandLine.value(forFlag: "--flag"))
        XCTAssertNil(SystemProcessInspector.parseCommandLine([1, 0]))
    }

    func testListeningPortsAreScopedToTheProcessAndLoopback() {
        let runner = ScriptedProcessRunner([
            "/usr/sbin/lsof": ProcessResult(exitCode: 0, stdout: """
            COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            agy 42 me 10u IPv4 0x1 0t0 TCP 127.0.0.1:61234 (LISTEN)
            agy 42 me 11u IPv6 0x2 0t0 TCP [::1]:61234 (LISTEN)
            agy 42 me 12u IPv4 0x3 0t0 TCP *:5555 (LISTEN)
            agy 42 me 13u IPv4 0x4 0t0 TCP 192.168.1.2:7000 (LISTEN)
            agy 42 me 14u IPv4 0x5 0t0 TCP 127.0.0.1:50000->127.0.0.1:443 (ESTABLISHED)
            """, stderr: "")
        ])
        let inspector = SystemProcessInspector(runner: runner)

        XCTAssertEqual(inspector.listeningPorts(of: 42), [61234, 5555])
        let arguments = runner.recordedCalls().first?.arguments ?? []
        XCTAssertTrue(arguments.contains("-a"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["-p", "42"])
    }

    func testProcessListReadsOnlyIdentifiersAndExecutables() {
        let processes = SystemProcessInspector.parseProcesses("""
          101 /usr/local/bin/agy
            7 /Applications/Antigravity.app/Contents/Resources/bin/language_server
        bad line
        """)

        XCTAssertEqual(processes, [
            LocalProcess(pid: 101, executablePath: "/usr/local/bin/agy"),
            LocalProcess(
                pid: 7,
                executablePath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
            )
        ])
        XCTAssertEqual(processes[1].executableName, "language_server")
    }

    func testLoopbackClientRefusesOtherHosts() async {
        do {
            _ = try await LoopbackHTTPClient().send(HTTPRequest(
                method: .post,
                url: URL(string: "https://example.com/")!
            ))
            XCTFail("Expected a refusal")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private var completeJSON: String {
        """
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-5h","remainingFraction":1},
            {"bucketId":"gemini-weekly","remainingFraction":0.5}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-5h","remainingFraction":1},
            {"bucketId":"3p-weekly","remainingFraction":0.75}
          ]}
        ]}
        """
    }

    private var completeSummary: Data { Data(completeJSON.utf8) }

    /// Every shared pool full, with a reset one whole window away: how
    /// production answers for an account whose usage the daily host counts.
    private var untouchedJSON: String {
        """
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","window":"weekly",
             "remainingFraction":1,"resetTime":"2027-01-22T00:00:00Z"},
            {"bucketId":"gemini-5h","window":"5h",
             "remainingFraction":1,"resetTime":"2027-01-15T05:00:00Z"}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","window":"weekly",
             "remainingFraction":1,"resetTime":"2027-01-22T00:00:00Z"},
            {"bucketId":"3p-5h","window":"5h",
             "remainingFraction":1,"resetTime":"2027-01-15T05:00:00Z"}
          ]}
        ]}
        """
    }

    private func summary(_ groups: String) -> Data {
        Data(#"{"groups":[\#(groups)]}"#.utf8)
    }

    private func makeProvider(
        http: HTTPClient,
        files: MemoryFiles = MemoryFiles(),
        expiry: String = "2027-06-01T00:00:00Z",
        local: AntigravityLocalClient = AntigravityLocalClient(
            inspector: FixedProcessInspector(),
            http: RoutedHTTPClient([:])
        )
    ) -> AntigravityProvider {
        let date = FixedDateProvider(value: now)
        return AntigravityProvider(
            authStore: AntigravityAuthStore(
                runner: keychainRunner(antigravityToken: """
                {"token":{"access_token":"stored","refresh_token":"refresh",
                 "expiry":"\(expiry)"}}
                """),
                files: files,
                dateProvider: date
            ),
            client: AntigravityUsageClient(http: http),
            localClient: local,
            dateProvider: date
        )
    }

    private func assertFailure(
        _ provider: AntigravityProvider,
        kind: ProviderFailureKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await provider.fetch()
            XCTFail("Expected a \(kind) failure", file: file, line: line)
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, kind, failure.message, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
