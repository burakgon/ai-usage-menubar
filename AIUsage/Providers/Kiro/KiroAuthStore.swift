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
}

struct KiroAuthStore: Sendable {
    static let primaryAuthPath = "~/.aws/sso/cache/kiro-auth-token.json"
    static let cliAuthPath = "~/.aws/sso/cache/kiro-auth-token-cli.json"
    static let ssoCacheDirectory = "~/.aws/sso/cache"
    static let refreshWindow: TimeInterval = 5 * 60
    static let defaultRegion = "us-east-1"

    let files: TextFileAccessing
    let dateProvider: DateProviding

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.files = files
        self.dateProvider = dateProvider
    }

    func load() -> KiroAuthState? {
        if let state = loadFromPath(Self.primaryAuthPath) {
            return state
        }
        if let state = loadFromPath(Self.cliAuthPath) {
            return state
        }
        if let apiKey = ProcessInfo.processInfo.environment["KIRO_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            return KiroAuthState(
                tokenRecord: KiroTokenRecord(accessToken: apiKey, authMethod: "API_KEY"),
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
        guard (record.accessToken != nil && !record.accessToken!.isEmpty) ||
              (record.refreshToken != nil && !record.refreshToken!.isEmpty) else {
            return nil
        }

        let creds = resolveClientCredentials(for: record)
        return KiroAuthState(
            tokenRecord: record,
            tokenPath: path,
            clientCredentials: creds
        )
    }

    private func resolveClientCredentials(for record: KiroTokenRecord) -> KiroClientCredentials? {
        if let hash = record.clientIdHash, !hash.isEmpty {
            let candidate = "\(Self.ssoCacheDirectory)/\(hash).json"
            if let creds = loadClientCredentials(at: candidate) {
                return creds
            }
        }
        let list = files.listDirectory(Self.ssoCacheDirectory)
        for filePath in list where filePath.hasSuffix(".json") {
            if filePath.hasSuffix("kiro-auth-token.json") ||
               filePath.hasSuffix("kiro-auth-token-cli.json") ||
               filePath.hasSuffix("kiro-connection.json") {
                continue
            }
            if let creds = loadClientCredentials(at: filePath) {
                return creds
            }
        }
        return nil
    }

    private func loadClientCredentials(at path: String) -> KiroClientCredentials? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8),
              let creds = try? JSONDecoder().decode(KiroClientCredentials.self, from: data),
              let clientId = creds.clientId, !clientId.isEmpty,
              let clientSecret = creds.clientSecret, !clientSecret.isEmpty else {
            return nil
        }
        return creds
    }

    func needsRefresh(_ state: KiroAuthState) -> Bool {
        guard let token = state.tokenRecord.accessToken, !token.isEmpty else {
            return true
        }
        guard let expiresAt = state.tokenRecord.expiresAt,
              let expiration = ProviderParsing.date(expiresAt) else {
            return false
        }
        return expiration.timeIntervalSince(dateProvider.now()) <= Self.refreshWindow
    }

    func refresh(_ state: inout KiroAuthState, client: any HTTPClient) async throws -> Bool {
        guard let refreshToken = state.tokenRecord.refreshToken, !refreshToken.isEmpty,
              let clientId = state.clientCredentials?.clientId, !clientId.isEmpty,
              let clientSecret = state.clientCredentials?.clientSecret, !clientSecret.isEmpty else {
            return false
        }

        let region = state.tokenRecord.region ?? Self.defaultRegion
        guard let url = URL(string: "https://oidc.\(region).amazonaws.com/token") else {
            return false
        }

        let payload: [String: Any] = [
            "grantType": "refresh_token",
            "clientId": clientId,
            "clientSecret": clientSecret,
            "refreshToken": refreshToken
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }

        let request = HTTPRequest(
            method: .post,
            url: url,
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let response = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderFailure(.authentication, "Kiro session expired. Sign in through Kiro.")
            }
            return false
        }

        guard let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let newAccessToken = ProviderParsing.string(json["accessToken"]) else {
            return false
        }

        state.tokenRecord.accessToken = newAccessToken
        if let newRefresh = ProviderParsing.string(json["refreshToken"]) {
            state.tokenRecord.refreshToken = newRefresh
        }
        let expiresIn = ProviderParsing.double(json["expiresIn"]) ?? 3600
        let newExpiresDate = dateProvider.now().addingTimeInterval(expiresIn)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        state.tokenRecord.expiresAt = formatter.string(from: newExpiresDate)
        if let profileArn = ProviderParsing.string(json["profileArn"]) {
            state.tokenRecord.profileArn = profileArn
        }

        if !state.tokenPath.isEmpty && files.exists(state.tokenPath) {
            if let existingText = try? files.readText(state.tokenPath),
               let existingData = existingText.data(using: .utf8),
               var existingJson = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] {
                existingJson["accessToken"] = state.tokenRecord.accessToken
                if let r = state.tokenRecord.refreshToken { existingJson["refreshToken"] = r }
                existingJson["expiresAt"] = state.tokenRecord.expiresAt
                if let p = state.tokenRecord.profileArn { existingJson["profileArn"] = p }
                if let updatedData = try? JSONSerialization.data(withJSONObject: existingJson, options: [.prettyPrinted, .sortedKeys]),
                   let updatedText = String(data: updatedData, encoding: .utf8) {
                    try? files.writeText(state.tokenPath, updatedText)
                }
            }
        }
        return true
    }
}
