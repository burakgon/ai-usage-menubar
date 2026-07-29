import Foundation

struct GrokRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

struct GrokUsageClient: Sendable {
    static let usageURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    )!
    static let settingsURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/settings"
    )!
    static let refreshURL = URL(
        string: "https://auth.x.ai/oauth2/token"
    )!

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: Self.usageURL,
            headers: authHeaders(accessToken)
        ))
    }

    func fetchSettings(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: Self.settingsURL,
            headers: authHeaders(accessToken)
        ))
    }

    func refreshToken(
        _ refreshToken: String,
        clientID: String
    ) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .post,
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: ProviderParsing.formBody([
                ("grant_type", "refresh_token"),
                ("client_id", clientID),
                ("refresh_token", refreshToken)
            ])
        ))
    }

    private func authHeaders(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "Accept": "application/json",
            "User-Agent": "AIUsage/0.1"
        ]
    }
}
