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

    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        try await fetch(url: Self.usageURL, accessToken: accessToken, accountID: accountID)
    }

    func fetchResetCredits(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        try await fetch(url: Self.resetCreditsURL, accessToken: accessToken, accountID: accountID)
    }

    private func fetch(url: URL, accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "AIUsage/0.1"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return try await http.send(HTTPRequest(
            method: .get,
            url: url,
            headers: headers
        ))
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
