import Foundation

struct ClaudeRefreshResponse: Decodable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct ClaudeUsageClient: Sendable {
    private static let refreshScopes =
        "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: ClaudeAuthStore.usageURL,
            headers: [
                "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.1.69"
            ]
        ))
    }

    func refreshToken(_ refreshToken: String) async throws -> HTTPResponse {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeAuthStore.clientID,
            "scope": Self.refreshScopes
        ]
        return try await http.send(HTTPRequest(
            method: .post,
            url: ClaudeAuthStore.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)
        ))
    }
}
