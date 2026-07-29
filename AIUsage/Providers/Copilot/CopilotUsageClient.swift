import Foundation

struct CopilotUsageClient: Sendable {
    static let usageURL = URL(
        string: "https://api.github.com/copilot_internal/user"
    )!

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .get,
            url: Self.usageURL,
            headers: [
                "Authorization": "token \(token)",
                "Accept": "application/json",
                "Editor-Version": "vscode/1.96.2",
                "Editor-Plugin-Version": "copilot-chat/0.26.7",
                "User-Agent": "GitHubCopilotChat/0.26.7",
                "X-Github-Api-Version": "2025-04-01"
            ]
        ))
    }
}
