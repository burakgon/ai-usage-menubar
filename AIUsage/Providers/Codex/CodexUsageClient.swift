import Foundation

struct CodexRefreshResponse: Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
}

struct CodexUsageClient: Sendable {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(
        string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    )!

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: Self.usageURL,
            headers: Self.headers(accessToken: accessToken, accountID: accountID)
        ))
    }

    /// Each banked rate-limit reset with its expiration. The usage response
    /// carries only their count. The extra headers mirror the Codex desktop
    /// app, which this endpoint expects. Read-only: nothing is redeemed.
    func fetchResetCredits(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var headers = Self.headers(accessToken: accessToken, accountID: accountID)
        headers["OpenAI-Beta"] = "codex-1"
        headers["originator"] = "Codex Desktop"
        return try await http.send(HTTPRequest(
            method: .get,
            url: Self.resetCreditsURL,
            headers: headers
        ))
    }

    private static func headers(accessToken: String, accountID: String?) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "AIUsage"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return headers
    }

    func refreshToken(_ refreshToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .post,
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: ProviderParsing.formBody([
                ("grant_type", "refresh_token"),
                ("client_id", Self.clientID),
                ("refresh_token", refreshToken)
            ])
        ))
    }
}
