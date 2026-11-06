import Foundation

actor KiroUsageClient: Sendable {
    private let client: any HTTPClient

    init(client: any HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    func fetchUsage(
        accessToken: String,
        region: String = "us-east-1"
    ) async throws -> HTTPResponse {
        let urlString = "https://q.\(region).amazonaws.com/getUsageLimits?origin=AI_EDITOR&resourceType=AGENTIC_REQUEST&isEmailRequired=true"
        guard let url = URL(string: urlString) else {
            throw ProviderFailure(.invalidResponse, "Invalid Kiro URL.")
        }
        let request = HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(accessToken)",
                "User-Agent": "aws-sdk-js/1.0.18 ua/2.1 os/macos lang/js md/nodejs#20.16.0 api/codewhispererstreaming#1.0.18 m/E KiroIDE-0.6.18"
            ]
        )
        return try await client.send(request)
    }
}
