import Foundation

struct ZAIUsageClient: Sendable {
    static let quotaPath = "/api/monitor/usage/quota/limit"

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchQuota(_ credential: ZAICredential) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: credential.baseURL.appendingPathComponent(
                String(Self.quotaPath.dropFirst())
            ),
            headers: [
                "Authorization": "Bearer \(credential.apiKey)",
                "Accept": "application/json",
                "User-Agent": "AIUsage"
            ]
        ))
    }
}
