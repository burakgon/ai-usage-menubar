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

    func testClaudeRefreshPreservesTheRestOfTheCredentialsDocument() throws {
        let service = "Claude Code-credentials"
        let login = """
        "claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh",\
        "expiresAt":1800000000000,"scopes":["user:profile"],"future":{"nested":true}}
        """
        func document(mcpAccessToken: String) -> String {
            """
            {\(login),"mcpOAuth":{"server|0123abcd":{"serverName":"server",\
            "serverUrl":"https://mcp.example.com/mcp","accessToken":"\(mcpAccessToken)",\
            "refreshToken":"mcp-refresh","expiresAt":1800003600000,\
            "discoveryState":{"oauthMetadataFound":true,"authServerMetadataUrl":null}}},\
            "other":42}
            """
        }
        let keychain = MemoryKeychain(currentUser: [
            service: document(mcpAccessToken: "mcp-access")
        ])
        let store = ClaudeAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(),
            keychain: keychain
        )
        var state = try XCTUnwrap(store.loadCandidates().first)
        let generation = store.credentialGeneration()
        // Claude Code rotates an MCP login while the Claude refresh is in flight.
        try keychain.writeGenericPasswordForCurrentUser(
            service: service,
            value: document(mcpAccessToken: "mcp-rotated")
        )
        state.oauth.accessToken = "new-access"
        state.oauth.refreshToken = "new-refresh"

        XCTAssertTrue(try store.save(state, ifUnchanged: generation))

        let saved = try XCTUnwrap(keychain.currentValue(service: service))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any]
        )
        let savedLogin = try XCTUnwrap(object["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(savedLogin["accessToken"] as? String, "new-access")
        XCTAssertEqual(savedLogin["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(savedLogin["expiresAt"] as? Double, 1_800_000_000_000)
        XCTAssertEqual(savedLogin["scopes"] as? [String], ["user:profile"])
        XCTAssertEqual(savedLogin["future"] as? [String: Bool], ["nested": true])
        let expected = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(document(mcpAccessToken: "mcp-rotated").utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            object["mcpOAuth"] as? NSDictionary,
            expected["mcpOAuth"] as? NSDictionary
        )
        XCTAssertEqual(object["other"] as? Int, 42)
        XCTAssertFalse(saved.contains("\\/"))
    }

    func testClaudeRefreshPreservesAHexEncodedCredentialsDocument() throws {
        let service = "Claude Code-credentials"
        let json = """
        {"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh"},\
        "mcpOAuth":{"server|0123abcd":{"accessToken":"mcp-access"}}}
        """
        let keychain = MemoryKeychain(currentUser: [
            service: Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        ])
        let store = ClaudeAuthStore(
            environment: MockEnvironment(),
            files: MemoryFiles(),
            keychain: keychain
        )
        var state = try XCTUnwrap(store.loadCandidates().first)
        let generation = store.credentialGeneration()
        state.oauth.accessToken = "new-access"

        XCTAssertTrue(try store.save(state, ifUnchanged: generation))

        let saved = try XCTUnwrap(keychain.currentValue(service: service))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any]
        )
        XCTAssertEqual(
            (object["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String,
            "new-access"
        )
        XCTAssertEqual(
            object["mcpOAuth"] as? [String: [String: String]],
            ["server|0123abcd": ["accessToken": "mcp-access"]]
        )
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

    func testGrokRefreshPreservesMetadataAndOtherScopes() throws {
        let files = MemoryFiles([
            GrokAuthStore.authPath: """
            {"user::client":{"key":"old","refresh_token":"refresh","auth_mode":"oidc","create_time":"2026-10-30T00:00:00Z","user_id":"user","oidc_issuer":"https://auth.x.ai","future":{"nested":true}},"other":{"key":"other","custom":42}}
            """
        ])
        let store = GrokAuthStore(files: files)
        var state = try XCTUnwrap(
            store.loadCandidates().first { $0.entryKey == "user::client" }
        )
        state.entry.key = "new"
        state.entry.refreshToken = "rotated"
        try store.save(state)
        let data = Data(try files.readText(GrokAuthStore.authPath).utf8)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: [String: Any]]
        )
        XCTAssertEqual(saved["user::client"]?["auth_mode"] as? String, "oidc")
        XCTAssertEqual(saved["user::client"]?["user_id"] as? String, "user")
        XCTAssertEqual(
            saved["user::client"]?["create_time"] as? String,
            "2026-10-30T00:00:00Z"
        )
        XCTAssertEqual(
            saved["user::client"]?["oidc_issuer"] as? String,
            "https://auth.x.ai"
        )
        XCTAssertEqual(
            saved["user::client"]?["future"] as? [String: Bool],
            ["nested": true]
        )
        XCTAssertEqual(saved["other"]?["custom"] as? Int, 42)
        XCTAssertEqual(saved["user::client"]?["key"] as? String, "new")
        XCTAssertEqual(
            saved["user::client"]?["refresh_token"] as? String,
            "rotated"
        )
        XCTAssertThrowsError(try store.save(state))
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
