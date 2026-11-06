import Foundation

struct KiroTokenRecord: Codable, Equatable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: String?
    var clientIdHash: String?
    var authMethod: String?
    var provider: String?
    var region: String?
    var profileArn: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAt
        case clientIdHash
        case authMethod
        case provider
        case region
        case profileArn
    }
}

struct KiroClientCredentials: Codable, Equatable, Sendable {
    var clientId: String?
    var clientSecret: String?
    var expiresAt: String?
}

struct KiroAuthState: Equatable, Sendable {
    var tokenRecord: KiroTokenRecord
    var tokenPath: String
    var clientCredentials: KiroClientCredentials?
    /// The record exactly as it was loaded, before any refresh mutated
    /// `tokenRecord`. Kiro refreshes this token too, so a write is only
    /// allowed while this generation is still the one on disk.
    let loadedRecord: KiroTokenRecord

    init(
        tokenRecord: KiroTokenRecord,
        tokenPath: String,
        clientCredentials: KiroClientCredentials? = nil,
        loadedRecord: KiroTokenRecord? = nil
    ) {
        self.tokenRecord = tokenRecord
        self.tokenPath = tokenPath
        self.clientCredentials = clientCredentials
        self.loadedRecord = loadedRecord ?? tokenRecord
    }
}

struct KiroAuthStore: Sendable {
    static let primaryAuthPath = "~/.aws/sso/cache/kiro-auth-token.json"
    static let cliAuthPath = "~/.aws/sso/cache/kiro-auth-token-cli.json"
    static let ssoCacheDirectory = "~/.aws/sso/cache"
    static let environmentName = "KIRO_API_KEY"
    static let refreshWindow: TimeInterval = 5 * 60
    /// Kiro always stores a region, so this is only the fallback for a
    /// hand-written record that omits one.
    static let defaultRegion = "us-east-1"
    /// AWS region names only. The value is read from the token file and is
    /// interpolated into the usage and OIDC hosts, so anything else is
    /// treated as unusable instead of being sent to an invented host.
    private static let regionPattern = #"^[a-z]{2}(-[a-z]+)+-\d+$"#

    let files: TextFileAccessing
    let environment: EnvironmentReading
    let dateProvider: DateProviding

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.files = files
        self.environment = environment
        self.dateProvider = dateProvider
    }

    func load() -> KiroAuthState? {
        if let state = loadFromPath(Self.primaryAuthPath) {
            return state
        }
        if let state = loadFromPath(Self.cliAuthPath) {
            return state
        }
        if let apiKey = environment.value(for: Self.environmentName) {
            return KiroAuthState(
                tokenRecord: KiroTokenRecord(
                    accessToken: apiKey,
                    authMethod: "API_KEY"
                ),
                tokenPath: "",
                clientCredentials: nil
            )
        }
        return nil
    }

    private func loadFromPath(_ path: String) -> KiroAuthState? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8),
              let record = try? JSONDecoder().decode(KiroTokenRecord.self, from: data) else {
            return nil
        }
        guard !(record.accessToken ?? "").isEmpty ||
              !(record.refreshToken ?? "").isEmpty else {
            return nil
        }

        return KiroAuthState(
            tokenRecord: record,
            tokenPath: path,
            clientCredentials: clientCredentials(for: record)
        )
    }

    /// Kiro's own registration only: the cache file named by the record's
    /// `clientIdHash`. Other `*.json` files in the AWS SSO cache belong to
    /// whatever else signed in through `aws sso login` on this Mac, and their
    /// client secrets must never be sent in a refresh.
    private func clientCredentials(
        for record: KiroTokenRecord
    ) -> KiroClientCredentials? {
        let hash = (record.clientIdHash ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty,
              !hash.contains("/"),
              !hash.contains("..") else {
            return nil
        }
        return loadClientCredentials(at: "\(Self.ssoCacheDirectory)/\(hash).json")
    }

    private func loadClientCredentials(
        at path: String
    ) -> KiroClientCredentials? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(
                KiroClientCredentials.self,
                from: data
              ),
              let clientID = credentials.clientId,
              !clientID.isEmpty,
              let clientSecret = credentials.clientSecret,
              !clientSecret.isEmpty else {
            return nil
        }
        return credentials
    }

    func needsRefresh(_ state: KiroAuthState) -> Bool {
        guard let token = state.tokenRecord.accessToken, !token.isEmpty else {
            return true
        }
        guard let expiresAt = state.tokenRecord.expiresAt,
              let expiration = ProviderParsing.date(expiresAt) else {
            return true
        }
        return expiration.timeIntervalSince(dateProvider.now()) <=
            Self.refreshWindow
    }

    /// The region to send Kiro requests to: the token record's own value when
    /// it is a valid AWS region name, `us-east-1` otherwise.
    func region(for state: KiroAuthState) -> String {
        let region = (state.tokenRecord.region ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty,
              region.range(
                of: Self.regionPattern,
                options: .regularExpression
              ) != nil else {
            return Self.defaultRegion
        }
        return region
    }

    /// Whether this state can refresh at all: Kiro's own refresh token plus
    /// the client registration stored beside it.
    func canRefresh(_ state: KiroAuthState) -> Bool {
        guard !(state.tokenRecord.refreshToken ?? "").isEmpty,
              let clientID = state.clientCredentials?.clientId,
              !clientID.isEmpty,
              let clientSecret = state.clientCredentials?.clientSecret,
              !clientSecret.isEmpty else {
            return false
        }
        return true
    }

    /// Exchanges the stored refresh token through Kiro's own SSO OIDC
    /// endpoint and writes the rotated tokens back into the file they were
    /// loaded from, preserving unknown fields.
    ///
    /// Kiro refreshes this token too, so the file is re-read first and the
    /// write is abandoned when it moved on since `state` was loaded.
    @discardableResult
    func refresh(
        _ state: inout KiroAuthState,
        client: any HTTPClient
    ) async throws -> Bool {
        guard canRefresh(state),
              let refreshToken = state.tokenRecord.refreshToken,
              let clientID = state.clientCredentials?.clientId,
              let clientSecret = state.clientCredentials?.clientSecret else {
            return false
        }
        let region = region(for: state)
        guard let url = URL(
            string: "https://oidc.\(region).amazonaws.com/token"
        ) else {
            return false
        }

        let payload: [String: Any] = [
            "grantType": "refresh_token",
            "clientId": clientID,
            "clientSecret": clientSecret,
            "refreshToken": refreshToken
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }

        let response = try await client.send(
            HTTPRequest(
                method: .post,
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body
            )
        )
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 400 ||
                response.statusCode == 401 ||
                response.statusCode == 403 {
                throw ProviderFailure(
                    .authentication,
                    "Kiro session expired. Sign in through Kiro."
                )
            }
            return false
        }

        guard let json = (try? JSONSerialization.jsonObject(
            with: response.body
        )) as? [String: Any],
            let accessToken = ProviderParsing.string(json["accessToken"]) else {
            return false
        }

        state.tokenRecord.accessToken = accessToken
        if let rotated = ProviderParsing.string(json["refreshToken"]) {
            state.tokenRecord.refreshToken = rotated
        }
        if let expiresIn = ProviderParsing.double(json["expiresIn"]) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds
            ]
            state.tokenRecord.expiresAt = formatter.string(
                from: dateProvider.now().addingTimeInterval(expiresIn)
            )
        } else {
            state.tokenRecord.expiresAt = nil
        }
        if let profileArn = ProviderParsing.string(json["profileArn"]) {
            state.tokenRecord.profileArn = profileArn
        }

        try save(state)
        return true
    }

    /// Writes only when the file still holds the refresh token this refresh
    /// started from. A moved-on file means Kiro signed in again while the
    /// refresh was in flight, and its newer tokens win.
    func save(_ state: KiroAuthState) throws {
        guard !state.tokenPath.isEmpty,
              files.exists(state.tokenPath),
              let text = try? files.readText(state.tokenPath),
              let data = text.data(using: .utf8),
              var existing = try JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any] else {
            throw ProviderFailure(
                .storage,
                "Kiro credentials could not be updated."
            )
        }
        guard existing["refreshToken"] as? String ==
                state.loadedRecord.refreshToken else {
            throw ProviderFailure(
                .storage,
                "Kiro login changed during refresh. Refresh again."
            )
        }

        existing["accessToken"] = state.tokenRecord.accessToken
        existing["refreshToken"] = state.tokenRecord.refreshToken
        if let expiresAt = state.tokenRecord.expiresAt {
            existing["expiresAt"] = expiresAt
        } else {
            existing.removeValue(forKey: "expiresAt")
        }
        if let profileArn = state.tokenRecord.profileArn {
            existing["profileArn"] = profileArn
        }

        let updated = try JSONSerialization.data(
            withJSONObject: existing,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let output = String(data: updated, encoding: .utf8) else {
            throw ProviderFailure(
                .storage,
                "Kiro credentials could not be encoded."
            )
        }
        try files.writeText(state.tokenPath, output)
    }
}
