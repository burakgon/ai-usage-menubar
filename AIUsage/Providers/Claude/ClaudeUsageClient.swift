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
    /// Anthropic shows reset grants only to a recent Claude Code
    /// (`ineligible_reason: cli_version` otherwise) on its CLI surface.
    static let claudeCodeVersion = "2.1.318"
    static let userAgent = "claude-cli/\(claudeCodeVersion) (external, cli)"

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(
        accessToken: String,
        includingResetGrants: Bool = false
    ) async throws -> HTTPResponse {
        try await sendOAuthGET(
            includingResetGrants
                ? ClaudeAuthStore.usageWithResetGrantsURL
                : ClaudeAuthStore.usageURL,
            accessToken: accessToken
        )
    }

    func fetchProfile(accessToken: String) async throws -> HTTPResponse {
        try await sendOAuthGET(
            ClaudeAuthStore.profileURL,
            accessToken: accessToken
        )
    }

    private func sendOAuthGET(
        _ url: URL,
        accessToken: String
    ) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": Self.userAgent
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
