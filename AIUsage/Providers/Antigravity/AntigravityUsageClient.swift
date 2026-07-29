import Foundation

enum AntigravityCloudOutcome: Sendable {
    case success(Data)
    case authentication
    case unavailable
}

private struct AntigravityGoogleTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

struct AntigravityUsageClient: Sendable {
    static let cloudBases = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
    static let summaryPath =
        "/v1internal:retrieveUserQuotaSummary"
    static let modelsPath = "/v1internal:fetchAvailableModels"
    static let planPath = "/v1internal:loadCodeAssist"
    static let googleOAuthURL = URL(
        string: "https://oauth2.googleapis.com/token"
    )!
    static let googleClientID =
        "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    // Installed-app OAuth credentials shipped inside Antigravity itself.
    // Google does not treat this client secret as confidential; every copy of
    // the native client contains it, and the refresh grant requires it.
    static let googleClientSecret =
        "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"

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func cloudCode(
        path: String,
        accessToken: String,
        userAgent: String
    ) async -> AntigravityCloudOutcome {
        for base in Self.cloudBases {
            guard let url = URL(string: base + path) else { continue }
            let request = HTTPRequest(
                method: .post,
                url: url,
                headers: [
                    "Accept": "application/json",
                    "Authorization": "Bearer \(accessToken)",
                    "Content-Type": "application/json",
                    "User-Agent": userAgent
                ],
                body: Data("{}".utf8)
            )
            guard let response = try? await http.send(request) else {
                continue
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                return .authentication
            }
            if (200..<300).contains(response.statusCode) {
                return .success(response.body)
            }
        }
        return .unavailable
    }

    func refresh(
        _ refreshToken: String
    ) async -> (token: String, expiresIn: Double)? {
        let body = ProviderParsing.formBody([
            ("client_id", Self.googleClientID),
            ("client_secret", Self.googleClientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ])
        guard let response = try? await http.send(HTTPRequest(
            method: .post,
            url: Self.googleOAuthURL,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            body: body
        )),
            (200..<300).contains(response.statusCode),
            let decoded = try? JSONDecoder().decode(
                AntigravityGoogleTokenResponse.self,
                from: response.body
            ),
            !decoded.accessToken.isEmpty else {
            return nil
        }
        return (decoded.accessToken, decoded.expiresIn ?? 3600)
    }
}
