import Foundation

actor CopilotProvider: UsageProvider {
    nonisolated let id = ProviderID.copilot

    private let authStore: CopilotAuthStore
    private let client: CopilotUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        client: CopilotUsageClient = CopilotUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let token = authStore.loadToken()?.value else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in to GitHub Copilot or run `gh auth login`."
            )
        }

        let response: HTTPResponse
        do {
            response = try await client.fetchUsage(token: token)
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            throw ProviderFailure(
                .transient,
                "GitHub Copilot could not be reached."
            )
        }

        if Self.isRateLimited(response) {
            throw ProviderFailure(
                .rateLimited,
                "GitHub Copilot is rate limited. Try again later.",
                retryAt: Self.retryDate(response, now: dateProvider.now())
            )
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderFailure(
                .authentication,
                "GitHub token expired. Run `gh auth login` again."
            )
        }
        return try CopilotUsageMapper.map(
            response: response,
            now: dateProvider.now()
        )
    }

    /// GitHub reports its rate limits as `429`, or as `403` with an
    /// exhausted `x-ratelimit-remaining` or a `Retry-After`. Neither means
    /// the token was rejected.
    static func isRateLimited(_ response: HTTPResponse) -> Bool {
        response.statusCode == 429 ||
            (response.statusCode == 403 &&
                (response.header("x-ratelimit-remaining") == "0" ||
                    response.header("Retry-After") != nil))
    }

    private static func retryDate(_ response: HTTPResponse, now: Date) -> Date {
        if response.header("Retry-After") == nil,
           let reset = ProviderParsing.double(response.header("x-ratelimit-reset")) {
            let delay = min(
                max(reset - now.timeIntervalSince1970, 0),
                ProviderParsing.maximumRetryDelay
            )
            return now.addingTimeInterval(delay)
        }
        return ProviderParsing.retryDate(from: response, now: now)
    }
}
