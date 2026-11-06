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
    }

    var oauth: ClaudeOAuth
    let source: Source

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
    /// The same usage read with Claude Code's reset-grant inventory
    /// (`cedar_ember`) included. Anthropic throttles this variant when it is
    /// polled, so it replaces the plain read at most once an hour.
    static let usageWithResetGrantsURL = URL(
        string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1"
    )!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let requiredUsageScope = "user:profile"

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
        if let keychain = loadKeychainCredentials() {
            candidates.append(keychain)
        }
        if let file = loadFileCredentials() {
            candidates.append(file)
        }
        return candidates
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

        // Claude Code keeps more than the login in this document: its MCP
        // server logins live beside it. The refreshed login is merged into
        // the stored JSON so everything else is written back untouched.
        guard let stored = try storedText(for: state.source),
              var document = ProviderParsing.objectWithHexFallback(stored) else {
            throw ProviderFailure(.storage, "Claude credentials could not be updated.")
        }
        let refreshed = try JSONEncoder().encode(state.oauth)
        guard let patch = try JSONSerialization.jsonObject(with: refreshed)
            as? [String: Any] else {
            throw ProviderFailure(.storage, "Claude credentials could not be encoded.")
        }
        var login = document["claudeAiOauth"] as? [String: Any] ?? [:]
        for (key, value) in patch {
            login[key] = value
        }
        document["claudeAiOauth"] = login
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
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
        }
        return true
    }

    private func storedText(for source: ClaudeCredentialState.Source) throws -> String? {
        switch source {
        case .file:
            try files.readText(credentialsPath())
        case .keychainCurrentUser(let service):
            try keychain.readGenericPasswordForCurrentUser(service: service)
        case .keychainLegacy(let service):
            try keychain.readGenericPassword(service: service)
        }
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
        return ClaudeCredentialState(oauth: oauth, source: source)
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
