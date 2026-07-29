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

        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderFailure(
                .authentication,
                "GitHub token expired. Run `gh auth login` again."
            )
        }
        if response.statusCode == 429 {
            throw ProviderFailure(
                .rateLimited,
                "GitHub Copilot is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(
                    from: response,
                    now: dateProvider.now()
                )
            )
        }
        return try CopilotUsageMapper.map(
            response: response,
            now: dateProvider.now()
        )
    }
}
