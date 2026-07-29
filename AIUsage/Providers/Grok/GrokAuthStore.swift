import Foundation

struct GrokAuthEntry: Codable, Equatable, Sendable {
    var key: String?
    var refreshToken: String?
    var refresh: String?
    var idToken: String?
    var expiresAt: String?
    var expires: String?
    var oidcClientID: String?

    enum CodingKeys: String, CodingKey {
        case key
        case refreshToken = "refresh_token"
        case refresh
        case idToken = "id_token"
        case expiresAt = "expires_at"
        case expires
        case oidcClientID = "oidc_client_id"
    }
}

struct GrokAuthState: Equatable, Sendable {
    var auth: [String: GrokAuthEntry]
    let entryKey: String
    var entry: GrokAuthEntry
    var token: String
}

struct GrokAuthStore: Sendable {
    static let authPath = "~/.grok/auth.json"
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let refreshWindow: TimeInterval = 5 * 60

    let files: TextFileAccessing
    let dateProvider: DateProviding

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.files = files
        self.dateProvider = dateProvider
    }

    func loadCandidates() -> [GrokAuthState] {
        guard files.exists(Self.authPath),
              let text = try? files.readText(Self.authPath),
              let data = text.data(using: .utf8),
              let auth = try? JSONDecoder().decode(
                [String: GrokAuthEntry].self,
                from: data
              ) else {
            return []
        }
        return auth.compactMap { key, entry in
            guard let token = trimmed(entry.key) else { return nil }
            return GrokAuthState(
                auth: auth,
                entryKey: key,
                entry: entry,
                token: token
            )
        }
    }

    func save(_ state: GrokAuthState) throws {
        guard files.exists(Self.authPath),
              let text = try? files.readText(Self.authPath),
              let data = text.data(using: .utf8),
              var auth = try? JSONDecoder().decode(
                [String: GrokAuthEntry].self,
                from: data
              ) else {
            throw ProviderFailure(
                .storage,
                "Grok credentials could not be updated."
            )
        }
        auth[state.entryKey] = state.entry
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updated = try encoder.encode(auth)
        guard let output = String(data: updated, encoding: .utf8) else {
            throw ProviderFailure(
                .storage,
                "Grok credentials could not be encoded."
            )
        }
        try files.writeText(Self.authPath, output)
    }

    func needsRefresh(_ state: GrokAuthState) -> Bool {
        guard let expiration = expirationDate(state) else { return false }
        return expiration.timeIntervalSince(dateProvider.now()) <=
            Self.refreshWindow
    }

    func isExpired(_ state: GrokAuthState) -> Bool {
        guard let expiration = expirationDate(state) else { return false }
        return dateProvider.now() >= expiration
    }

    func refreshToken(_ entry: GrokAuthEntry) -> String? {
        trimmed(entry.refreshToken) ?? trimmed(entry.refresh)
    }

    func clientID(for state: GrokAuthState) -> String {
        if let clientID = trimmed(state.entry.oidcClientID) {
            return clientID
        }
        if let suffix = state.entryKey.split(
            separator: "::",
            omittingEmptySubsequences: false
        ).last {
            let value = String(suffix).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !value.isEmpty { return value }
        }
        return Self.defaultClientID
    }

    private func expirationDate(_ state: GrokAuthState) -> Date? {
        ProviderParsing.jwtExpiration(state.token) ??
            ProviderParsing.date(state.entry.expiresAt) ??
            ProviderParsing.date(state.entry.expires)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }
}
