import Foundation

struct ClaudeOAuth: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

struct ClaudeCredentialsDocument: Codable, Equatable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

struct ClaudeCredentialState: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case file
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case cliProxy(path: String)

        var refreshesProactively: Bool {
            switch self {
            case .cliProxy: false
            case .file, .keychainCurrentUser, .keychainLegacy: true
            }
        }
    }

    var oauth: ClaudeOAuth
    let source: Source
    let fullDocument: ClaudeCredentialsDocument?
    let rawJSON: Data?

    var hasUsableAccessToken: Bool {
        oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct ClaudeCredentialGeneration: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let oauth: ClaudeOAuth
        let source: ClaudeCredentialState.Source
    }

    var candidates: [Candidate]

    init(_ states: [ClaudeCredentialState]) {
        candidates = states
            .filter(\.hasUsableAccessToken)
            .map { Candidate(oauth: $0.oauth, source: $0.source) }
    }

    func replacing(_ state: ClaudeCredentialState) -> Self {
        var copy = self
        if let index = copy.candidates.firstIndex(where: { $0.source == state.source }) {
            copy.candidates[index] = Candidate(oauth: state.oauth, source: state.source)
        }
        return copy
    }
}

struct ClaudeAuthStore: Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    /// The same usage read with Claude Code's reset-grant inventory
    /// (`cedar_ember`) included. Anthropic throttles this variant when it is
    /// polled, so it replaces the plain read at most once an hour.
    static let usageWithResetGrantsURL = URL(
        string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1"
    )!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let requiredUsageScope = "user:profile"
    static let cliProxyDirectory = "~/.cli-proxy-api"

    let environment: EnvironmentReading
    let files: TextFileAccessing
    let keychain: KeychainAccessing
    let dateProvider: DateProviding

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.dateProvider = dateProvider
    }

    func loadCandidates() -> [ClaudeCredentialState] {
        var candidates: [ClaudeCredentialState] = []
        candidates.append(contentsOf: loadCLIProxyCredentials())
        if let keychain = loadKeychainCredentials() {
            candidates.append(keychain)
        }
        if let file = loadFileCredentials() {
            candidates.append(file)
        }
        return uniquedByAccessToken(candidates)
    }

    func credentialGeneration() -> ClaudeCredentialGeneration {
        ClaudeCredentialGeneration(loadCandidates())
    }

    func needsRefresh(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - dateProvider.now().timeIntervalSince1970 * 1_000 <= 5 * 60 * 1_000
    }

    func hasUsageScope(_ oauth: ClaudeOAuth) -> Bool {
        guard let scopes = oauth.scopes, !scopes.isEmpty else { return true }
        return scopes.contains(Self.requiredUsageScope)
    }

    func save(
        _ state: ClaudeCredentialState,
        ifUnchanged expected: ClaudeCredentialGeneration
    ) throws -> Bool {
        guard credentialGeneration() == expected else { return false }

        var document = state.fullDocument ?? ClaudeCredentialsDocument()
        document.claudeAiOauth = state.oauth
        let data = try JSONEncoder().encode(document)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderFailure(.storage, "Claude credentials could not be encoded.")
        }

        switch state.source {
        case .file:
            try files.writeText(credentialsPath(), text)
        case .keychainCurrentUser(let service):
            try keychain.writeGenericPasswordForCurrentUser(service: service, value: text)
        case .keychainLegacy(let service):
            try keychain.writeGenericPassword(service: service, value: text)
        case .cliProxy(let path):
            try files.writeText(path, encodeCLIProxyDocument(state))
        }
        return true
    }

    private func loadKeychainCredentials() -> ClaudeCredentialState? {
        for service in keychainServiceCandidates() {
            if let value = try? keychain.readGenericPasswordForCurrentUser(service: service),
               let state = credentialState(
                value,
                source: .keychainCurrentUser(service: service)
               ) {
                return state
            }
            if let value = try? keychain.readGenericPassword(service: service),
               let state = credentialState(
                value,
                source: .keychainLegacy(service: service)
               ) {
                return state
            }
        }
        return nil
    }

    private func loadFileCredentials() -> ClaudeCredentialState? {
        let path = credentialsPath()
        guard files.exists(path),
              let value = try? files.readText(path)
        else {
            return nil
        }
        return credentialState(value, source: .file)
    }

    private func credentialState(
        _ value: String,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard
            let document = ProviderParsing.decodeWithHexFallback(
                value,
                as: ClaudeCredentialsDocument.self
            ),
            let oauth = document.claudeAiOauth,
            oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return ClaudeCredentialState(
            oauth: oauth,
            source: source,
            fullDocument: document,
            rawJSON: nil
        )
    }

    private func loadCLIProxyCredentials() -> [ClaudeCredentialState] {
        files.listDirectory(Self.cliProxyDirectory)
            .filter(isCLIProxyClaudeFile)
            .compactMap(loadCLIProxyCredential(at:))
    }

    private func isCLIProxyClaudeFile(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name.hasPrefix("claude-") && name.hasSuffix(".json")
    }

    private func loadCLIProxyCredential(at path: String) -> ClaudeCredentialState? {
        guard
            let text = try? files.readText(path),
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        if object["disabled"] as? Bool == true {
            return nil
        }
        if let type = ProviderParsing.string(object["type"]),
           type.caseInsensitiveCompare("claude") != .orderedSame {
            return nil
        }
        guard let accessToken = ProviderParsing.string(object["access_token"]),
              !accessToken.isEmpty else {
            return nil
        }
        let oauth = ClaudeOAuth(
            accessToken: accessToken,
            refreshToken: ProviderParsing.string(object["refresh_token"]),
            expiresAt: ProviderParsing.date(
                object["expired"] ?? object["expires_at"]
            ).map { $0.timeIntervalSince1970 * 1_000 },
            subscriptionType: nil,
            rateLimitTier: nil,
            scopes: nil
        )
        return ClaudeCredentialState(
            oauth: oauth,
            source: .cliProxy(path: path),
            fullDocument: nil,
            rawJSON: data
        )
    }

    private func encodeCLIProxyDocument(
        _ state: ClaudeCredentialState
    ) throws -> String {
        var object: [String: Any]
        if let rawJSON = state.rawJSON,
           let parsed = try? JSONSerialization.jsonObject(with: rawJSON)
            as? [String: Any] {
            object = parsed
        } else {
            object = [:]
        }
        object["access_token"] = state.oauth.accessToken ?? ""
        if let refreshToken = state.oauth.refreshToken, !refreshToken.isEmpty {
            object["refresh_token"] = refreshToken
        }
        if let expiresAt = state.oauth.expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let date = Date(timeIntervalSince1970: expiresAt / 1_000)
            object["expired"] = formatter.string(from: date)
            object["last_refresh"] = formatter.string(from: dateProvider.now())
        }
        object["type"] = object["type"] ?? "claude"
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderFailure(
                .storage,
                "Claude credentials could not be encoded."
            )
        }
        return text
    }

    private func uniquedByAccessToken(
        _ candidates: [ClaudeCredentialState]
    ) -> [ClaudeCredentialState] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            let token = candidate.oauth.accessToken?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return seen.insert(token).inserted
        }
    }

    private func keychainServiceCandidates() -> [String] {
        let base = "Claude Code-credentials"
        guard let directory = configurationDirectoryOverride() else {
            return [base]
        }
        let normalized = directory.precomposedStringWithCanonicalMapping
        return ["\(base)-\(ProviderParsing.shortSHA256(normalized))", base]
    }

    private func credentialsPath() -> String {
        "\(configurationDirectoryOverride() ?? "~/.claude")/.credentials.json"
    }

    private func configurationDirectoryOverride() -> String? {
        guard let value = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
