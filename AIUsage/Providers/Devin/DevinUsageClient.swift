import Foundation

struct DevinUsageClient: Sendable {
    static let service =
        "exa.seat_management_pb.SeatManagementService"
    static let compatibilityVersion = "1.108.2"

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUserStatus(
        auth: DevinAuth,
        serverURL: String
    ) async throws -> HTTPResponse {
        guard let url = URL(
            string: "\(serverURL)/\(Self.service)/GetUserStatus"
        ) else {
            throw ProviderFailure(
                .invalidResponse,
                "Devin server configuration is invalid."
            )
        }
        let body: [String: Any] = [
            "metadata": [
                "apiKey": auth.apiKey,
                "ideName": "devin",
                "ideVersion": Self.compatibilityVersion,
                "extensionName": "devin",
                "extensionVersion": Self.compatibilityVersion,
                "locale": "en"
            ]
        ]
        return try await http.send(HTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        ))
    }
}
