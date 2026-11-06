import Foundation

/// Kiro's `getUsageLimits`. The request asks only for what the panel shows:
/// the query carries no `isEmailRequired`, because AI Usage never uses the
/// account email.
actor KiroUsageClient: Sendable {
    private let client: any HTTPClient

    init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    func fetchUsage(
        accessToken: String,
        region: String
    ) async throws -> HTTPResponse {
        guard var components = URLComponents(
            string: "https://q.\(region).amazonaws.com/getUsageLimits"
        ) else {
            throw ProviderFailure(.invalidResponse, "Invalid Kiro URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "origin", value: "AI_EDITOR"),
            URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST")
        ]
        guard let url = components.url else {
            throw ProviderFailure(.invalidResponse, "Invalid Kiro URL.")
        }
        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(accessToken)",
                "User-Agent": Self.userAgent
            ]
        )
        return try await client.send(request)
    }

    /// The identity Kiro's own client sends, so the request is not treated as
    /// an unfamiliar caller.
    static let userAgent =
        "aws-sdk-js/1.0.18 ua/2.1 os/macos lang/js md/nodejs#20.16.0 " +
        "api/codewhispererstreaming#1.0.18 m/E KiroIDE-0.6.18"
}
