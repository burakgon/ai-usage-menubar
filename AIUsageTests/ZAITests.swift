import XCTest
@testable import AIUsage

final class ZAITests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testKeyComesFromTheEnvironmentClaudeCodeThenOpenCode() {
        let claudeSettings = """
        {"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic",
                "ANTHROPIC_AUTH_TOKEN":"claude-key"}}
        """
        let openCode = """
        {"anthropic":{"type":"oauth"},
         "zai-coding-plan":{"type":"api","key":"opencode-key"}}
        """

        let everything = ZAIAuthStore(
            environment: MockEnvironment(values: ["ZAI_API_KEY": "env-key"]),
            files: MemoryFiles([
                "~/.claude/settings.json": claudeSettings,
                ZAIAuthStore.openCodeAuthPath: openCode
            ])
        )
        XCTAssertEqual(everything.loadCredential()?.apiKey, "env-key")
        XCTAssertEqual(everything.loadCredential()?.source, .environment)

        let claude = ZAIAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles([
                "~/.claude/settings.json": claudeSettings,
                ZAIAuthStore.openCodeAuthPath: openCode
            ])
        ).loadCredential()
        XCTAssertEqual(claude?.apiKey, "claude-key")
        XCTAssertEqual(claude?.baseURL, ZAIAuthStore.internationalBaseURL)

        let openCodeOnly = ZAIAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles([ZAIAuthStore.openCodeAuthPath: openCode])
        ).loadCredential()
        XCTAssertEqual(openCodeOnly?.apiKey, "opencode-key")
        XCTAssertEqual(openCodeOnly?.source, .openCode)
    }

    func testOnlyAZhipuBaseURLMakesClaudeCodeSettingsAZaiKey() {
        func credential(_ settings: String, environment: [String: String] = [:]) -> ZAICredential? {
            ZAIAuthStore(
                environment: MockEnvironment(values: environment),
                files: MemoryFiles([
                    "~/.claude/settings.json": settings,
                    "/custom/settings.json": settings
                ])
            ).loadClaudeCodeSettings()
        }

        XCTAssertEqual(credential("""
        {"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic",
                "ANTHROPIC_API_KEY":"cn-key"}}
        """)?.baseURL, ZAIAuthStore.chinaBaseURL)
        XCTAssertNil(credential("""
        {"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com",
                "ANTHROPIC_AUTH_TOKEN":"not-zai"}}
        """))
        XCTAssertNil(credential("""
        {"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai.example.com/api/anthropic",
                "ANTHROPIC_AUTH_TOKEN":"lookalike"}}
        """))
        XCTAssertNil(credential(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"no-base"}}"#))
        XCTAssertEqual(credential("""
        {"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic",
                "ANTHROPIC_AUTH_TOKEN":"override"}}
        """, environment: ["CLAUDE_CONFIG_DIR": "/custom"])?.apiKey, "override")
    }

    func testMapsTheCodingPlanWindows() throws {
        let snapshot = try ZAIUsageMapper.map(response: httpResponse(json: """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 60000,
               "currentValue": 12765, "remaining": 47234, "percentage": 21,
               "nextResetTime": 1793154828977},
              {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 12000,
               "currentValue": 3288, "remaining": 8711, "percentage": 27,
               "nextResetTime": 1792624471458},
              {"type": "TIME_LIMIT", "unit": 5, "number": 1, "usage": 1000,
               "currentValue": 250, "remaining": 750, "percentage": 25},
              {"type": "SOMETHING_NEW", "percentage": 99}
            ],
            "level": "pro"
          },
          "success": true
        }
        """), now: now)

        XCTAssertEqual(snapshot.provider, .zai)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly, .webSearches])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [27, 21, 25])
        XCTAssertEqual(
            snapshot.windows[0].resetsAt,
            Date(timeIntervalSince1970: 1_792_624_471.458)
        )
    }

    func testExplainsAMissingPlanOrRejectedKey() {
        XCTAssertThrowsError(try ZAIUsageMapper.map(response: httpResponse(json: """
        {"success": false, "code": 500, "msg": "No active Coding Plan subscription"}
        """), now: now)) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .invalidResponse)
            XCTAssertTrue((error as? ProviderFailure)?.message.contains("GLM Coding Plan") == true)
        }
        XCTAssertThrowsError(try ZAIUsageMapper.map(response: httpResponse(json: """
        {"success": false, "code": 401, "msg": "token expired"}
        """), now: now)) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication)
        }
    }

    func testProviderSendsTheKeyToItsOwnPlatform() async throws {
        let http = MockHTTPClient([
            httpResponse(json: #"{"success":true,"data":{"limits":[],"level":"lite"}}"#),
            httpResponse(401)
        ])
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(
                environment: MockEnvironment(),
                files: MemoryFiles([ZAIAuthStore.openCodeAuthPath: """
                {"zhipuai-coding-plan":{"type":"api","key":"cn-key"}}
                """])
            ),
            client: ZAIUsageClient(http: http),
            dateProvider: FixedDateProvider(value: now)
        )

        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Lite")

        do {
            _ = try await provider.fetch()
            XCTFail("Expected a rejected key")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
        }

        let requests = await http.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
        XCTAssertEqual(request.headers["Authorization"], "Bearer cn-key")
    }
}
