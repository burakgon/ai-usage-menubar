import Foundation

/// The result of `loadCodeAssist`, which carries the plan and the Cloud
/// project the quota summary is scoped to.
enum AntigravityCodeAssistOutcome: Sendable {
    case success(Data)
    case tokenRefused
    case unavailable
}

/// The result of `retrieveUserQuotaSummary` across both Cloud Code hosts.
enum AntigravitySummaryOutcome: Sendable {
    /// Every successful body, production host first.
    case success([Data])
    /// `401`: the access token itself was refused.
    case tokenRefused
    /// `403`: the token is valid, but Google does not share quota for this
    /// account (for example `PERMISSION_DENIED` #3501 or
    /// `SUBSCRIPTION_REQUIRED`). This is not a sign-in problem.
    case denied
    case rateLimited(retryAt: Date?)
    case unavailable
}

enum AntigravityTokenRefreshOutcome: Sendable {
    case refreshed(token: String, expiresIn: Double)
    /// The refresh token was revoked or expired.
    case rejected
    /// Throttling, a server error, or no connection. The refresh token may
    /// still be valid.
    case unavailable
}

private struct AntigravityGoogleTokenResponse: Decodable {
    let accessToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

struct AntigravityUsageClient: Sendable {
    /// Production first: the daily host can answer the quota summary with a
    /// whole pool missing.
    static let cloudBases = [
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.googleapis.com"
    ]
    static let summaryPath = "/v1internal:retrieveUserQuotaSummary"
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

    /// The Antigravity client's own User-Agent shape. Google answers other
    /// callers without the Gemini quota group and without `paidTier`.
    static let userAgent: String = {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "amd64"
        #endif
        return "antigravity/2.24.0 (aidev_client; os_type=darwin; " +
            "arch=\(architecture))"
    }()

    /// The `ClientMetadata` Antigravity sends. Without it `loadCodeAssist`
    /// returns only `allowedTiers`, so neither the plan nor the project can
    /// be read.
    static let codeAssistPayload = Data(
        #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#
            .utf8
    )

    let http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func loadCodeAssist(accessToken: String) async -> AntigravityCodeAssistOutcome {
        for base in Self.cloudBases {
            guard let url = URL(string: base + Self.planPath),
                  let response = try? await http.send(request(
                      url: url,
                      accessToken: accessToken,
                      body: Self.codeAssistPayload
                  )) else {
                continue
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                return .tokenRefused
            }
            if (200..<300).contains(response.statusCode) {
                return .success(response.body)
            }
        }
        return .unavailable
    }

    /// Asks production first and stops there when its answer already holds
    /// every shared pool; otherwise also asks the daily host so the mapper can
    /// merge the pools each host returned.
    func quotaSummary(
        accessToken: String,
        project: String?,
        now: Date
    ) async -> AntigravitySummaryOutcome {
        let payload: Data
        if let project,
           let encoded = try? JSONSerialization.data(
               withJSONObject: ["project": project]
           ) {
            payload = encoded
        } else {
            payload = Data("{}".utf8)
        }

        var responses: [HTTPResponse] = []
        for (index, base) in Self.cloudBases.enumerated() {
            guard let url = URL(string: base + Self.summaryPath),
                  let response = try? await http.send(request(
                      url: url,
                      accessToken: accessToken,
                      body: payload
                  )) else {
                continue
            }
            responses.append(response)
            if index == 0,
               (200..<300).contains(response.statusCode),
               AntigravityUsageMapper.isCompleteSummary(response.body) {
                break
            }
        }

        let bodies = responses
            .filter { (200..<300).contains($0.statusCode) }
            .map(\.body)
        if !bodies.isEmpty {
            return .success(bodies)
        }
        if responses.contains(where: { $0.statusCode == 401 }) {
            return .tokenRefused
        }
        if responses.contains(where: { $0.statusCode == 403 }) {
            return .denied
        }
        if let limited = responses.first(where: { $0.statusCode == 429 }) {
            return .rateLimited(
                retryAt: ProviderParsing.retryDate(from: limited, now: now)
            )
        }
        return .unavailable
    }

    func refresh(_ refreshToken: String) async -> AntigravityTokenRefreshOutcome {
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
        )) else {
            return .unavailable
        }
        switch response.statusCode {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(
                AntigravityGoogleTokenResponse.self,
                from: response.body
            ),
                let token = decoded.accessToken,
                !token.isEmpty else {
                return .unavailable
            }
            return .refreshed(token: token, expiresIn: decoded.expiresIn ?? 3600)
        case 408, 429:
            return .unavailable
        case 400..<500:
            return .rejected
        default:
            return .unavailable
        }
    }

    private func request(
        url: URL,
        accessToken: String,
        body: Data
    ) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Accept": "application/json",
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "User-Agent": Self.userAgent
            ],
            body: body
        )
    }
}
