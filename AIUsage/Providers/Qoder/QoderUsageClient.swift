import Foundation

struct QoderUsageClient: Sendable {
    let httpClient: any HTTPClient

    init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await send(path: "/api/v2/quota/usage", accessToken: accessToken)
    }

    func fetchPlan(accessToken: String) async throws -> HTTPResponse {
        try await send(path: "/api/v2/user/plan", accessToken: accessToken)
    }

    private func send(
        path: String,
        accessToken: String
    ) async throws -> HTTPResponse {
        var lastResponse: HTTPResponse?
        for origin in Self.origins {
            guard let url = URL(string: origin + path) else { continue }
            let response = try await httpClient.send(HTTPRequest(
                method: .get,
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Authorization": "Bearer \(accessToken)",
                    "User-Agent": "qodercli"
                ]
            ))
            if (200..<300).contains(response.statusCode) {
                return response
            }
            lastResponse = response
            if response.statusCode != 401 && response.statusCode != 403 {
                return response
            }
        }
        if let lastResponse { return lastResponse }
        throw ProviderFailure(.invalidResponse, "Qoder usage request failed.")
    }

    private static let origins = [
        "https://openapi.qoder.sh"
    ]
}
