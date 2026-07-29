import XCTest
@testable import AIUsage

final class AuthStoreTests: XCTestCase {
    func testClaudeUsesHashedCurrentUserKeychainBeforeLegacyAndFile() {
        let configDirectory = "/tmp/Claude Profile"
        let service = "Claude Code-credentials-\(ProviderParsing.shortSHA256(configDirectory))"
        let keychainOAuth = ClaudeOAuth(
            accessToken: "keychain",
            refreshToken: "refresh",
            expiresAt: nil,
            subscriptionType: nil,
            rateLimitTier: nil,
            scopes: nil
        )
        let fileOAuth = ClaudeOAuth(
            accessToken: "file",
            refreshToken: "refresh",
            expiresAt: nil,
            subscriptionType: nil,
            rateLimitTier: nil,
            scopes: nil
        )
        let keychain = MemoryKeychain(currentUser: [
            service: encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: keychainOAuth))
        ])
        let files = MemoryFiles([
            "\(configDirectory)/.credentials.json":
                encodedJSON(ClaudeCredentialsDocument(claudeAiOauth: fileOAuth))
        ])
        let store = ClaudeAuthStore(
            environment: MockEnvironment(values: ["CLAUDE_CONFIG_DIR": configDirectory]),
            files: files,
            keychain: keychain
        )

        let candidates = store.loadCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["keychain", "file"])
        XCTAssertEqual(keychain.currentUserReads.first, service)
        XCTAssertTrue(keychain.genericReads.isEmpty)
    }

    func testClaudeScopeRulesAllowUnknownButRejectKnownMissingProfile() {
        let store = ClaudeAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(),
            keychain: MemoryKeychain()
        )
        XCTAssertTrue(store.hasUsageScope(ClaudeOAuth(scopes: nil)))
        XCTAssertTrue(store.hasUsageScope(ClaudeOAuth(scopes: [])))
        XCTAssertFalse(store.hasUsageScope(ClaudeOAuth(scopes: ["user:inference"])))
        XCTAssertTrue(store.hasUsageScope(ClaudeOAuth(scopes: ["user:profile"])))
    }

    func testCodexHomeOverridesDefaultPaths() {
        let store = CodexAuthStore(
            environment: MockEnvironment(values: ["CODEX_HOME": "/tmp/custom-codex"]),
            files: MemoryFiles(),
            keychain: MemoryKeychain()
        )
        XCTAssertEqual(store.authPaths(), ["/tmp/custom-codex/auth.json"])
    }

    func testCodexJWTExpirationWinsOverOldLastRefreshFallback() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = CodexAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(),
            keychain: MemoryKeychain(),
            dateProvider: FixedDateProvider(value: now)
        )
        let futureToken = jwt(expiration: now.timeIntervalSince1970 + 3_600)
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: futureToken),
            lastRefresh: "2020-01-01T00:00:00Z"
        )
        XCTAssertFalse(store.needsRefresh(auth))
    }

    func testLocalCredentialWritesArePrivate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("auth.json").path

        try LocalTextFileAccessor().writeText(path, "{}")

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o600)
    }

    func testCopilotPrefersEditorTokenOverGitHubCLI() {
        let files = MemoryFiles([
            CopilotAuthStore.editorAppsPath: """
            {"github.com":{"oauth_token":"editor-token"}}
            """,
            CopilotAuthStore.ghHostsPath: """
            github.com:
                oauth_token: gh-token
            """
        ])
        let store = CopilotAuthStore(
            files: files,
            keychain: MemoryKeychain()
        )

        XCTAssertEqual(store.loadToken()?.value, "editor-token")
    }

    func testDevinReadsTheCLICredentialsFormat() {
        let store = DevinAuthStore(
            files: MemoryFiles([
                DevinAuthStore.credentialsPath: """
                windsurf_api_key = "devin-key"
                api_server_url = "https://example.test/"
                """
            ]),
            sqlite: MemorySQLite()
        )

        XCTAssertEqual(
            store.loadCredentialsFile(),
            DevinAuth(
                apiKey: "devin-key",
                apiServerURL: "https://example.test"
            )
        )
    }

    func testGrokReadsKeyedAuthEntries() {
        let store = GrokAuthStore(files: MemoryFiles([
            GrokAuthStore.authPath: """
            {
              "user::client": {
                "key": "access",
                "refresh_token": "refresh"
              }
            }
            """
        ]))

        XCTAssertEqual(store.loadCandidates().map(\.token), ["access"])
        XCTAssertEqual(
            store.loadCandidates().first.map(store.clientID),
            "client"
        )
    }

    func testAntigravityDecodesGoKeyringTokenEnvelope() throws {
        let json = """
        {
          "token": {
            "access_token": "access",
            "refresh_token": "refresh",
            "expiry": "2027-01-15T00:00:00Z"
          }
        }
        """
        let wrapped = "go-keyring-base64:" +
            Data(json.utf8).base64EncodedString()
        let token = try XCTUnwrap(AntigravityAuthStore.decode(wrapped))

        XCTAssertEqual(token.accessToken, "access")
        XCTAssertEqual(token.refreshToken, "refresh")
        XCTAssertNotNil(token.expiry)
    }
}

private struct MemorySQLite: SQLiteValueReading {
    var values: [String: String] = [:]

    func queryValue(path: String, sql: String) throws -> String? {
        values.first { sql.contains($0.key) }?.value
    }

    func execute(path: String, sql: String) throws {}
}

private extension ClaudeOAuth {
    init(scopes: [String]?) {
        self.init(
            accessToken: "access",
            refreshToken: nil,
            expiresAt: nil,
            subscriptionType: nil,
            rateLimitTier: nil,
            scopes: scopes
        )
    }
}

private extension CodexTokens {
    init(accessToken: String) {
        self.init(
            accessToken: accessToken,
            refreshToken: nil,
            idToken: nil,
            accountID: nil
        )
    }
}

private extension CodexAuth {
    init(tokens: CodexTokens, lastRefresh: String?) {
        self.init(tokens: tokens, lastRefresh: lastRefresh, apiKey: nil)
    }
}
