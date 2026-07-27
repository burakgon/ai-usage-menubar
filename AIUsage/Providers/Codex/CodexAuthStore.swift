import Foundation

struct CodexTokens: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

struct CodexAuth: Codable, Equatable, Sendable {
    var tokens: CodexTokens?
    var lastRefresh: String?
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
        case apiKey = "OPENAI_API_KEY"
    }
}

struct CodexAuthState: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case file(path: String)
        case keychain
    }

    var auth: CodexAuth
    let source: Source

    var hasUsableAccessToken: Bool {
        auth.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    static let refreshWindow: TimeInterval = 5 * 60

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

    func loadFileCandidates() -> [CodexAuthState] {
        authPaths().compactMap(loadAuth(at:))
    }

    func loadKeychainAuth() -> CodexAuthState? {
        guard
            let text = try? keychain.readGenericPassword(service: Self.keychainService),
            let auth = Self.parseAuth(text),
            Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .keychain)
    }

    func loadAuth(at path: String) -> CodexAuthState? {
        guard
            files.exists(path),
            let text = try? files.readText(path),
            let auth = Self.parseAuth(text),
            Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .file(path: path))
    }

    func reload(_ source: CodexAuthState.Source) -> CodexAuthState? {
        switch source {
        case .file(let path):
            loadAuth(at: path)
        case .keychain:
            loadKeychainAuth()
        }
    }

    func save(_ state: CodexAuthState, ifUnchanged expected: CodexAuthState) throws -> Bool {
        guard reload(state.source) == expected else { return false }

        let encoder = JSONEncoder()
        if case .file = state.source {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data = try encoder.encode(state.auth)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderFailure(.storage, "Codex credentials could not be encoded.")
        }

        switch state.source {
        case .file(let path):
            try files.writeText(path, text)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainService, value: text)
        }
        return true
    }

    func needsRefresh(_ auth: CodexAuth) -> Bool {
        if let token = auth.tokens?.accessToken,
           let expiration = ProviderParsing.jwtExpiration(token) {
            return expiration.timeIntervalSince(dateProvider.now()) <= Self.refreshWindow
        }
        guard
            let lastRefresh = auth.lastRefresh,
            let refreshedAt = ProviderParsing.date(lastRefresh)
        else {
            return false
        }
        return dateProvider.now().timeIntervalSince(refreshedAt) > 8 * 24 * 60 * 60
    }

    func authPaths() -> [String] {
        if let home = codexHome() {
            return ["\(home.trimmingTrailingSlashes)/auth.json"]
        }
        return ["~/.config/codex/auth.json", "~/.codex/auth.json"]
    }

    static func parseAuth(_ text: String) -> CodexAuth? {
        ProviderParsing.decodeWithHexFallback(text, as: CodexAuth.self)
    }

    static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
        if auth.tokens?.accessToken?.isEmpty == false { return true }
        return auth.apiKey?.isEmpty == false
    }

    private func codexHome() -> String? {
        guard let value = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    var trimmingTrailingSlashes: String {
        var copy = self
        while copy.hasSuffix("/") {
            copy.removeLast()
        }
        return copy
    }
}
