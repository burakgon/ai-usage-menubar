import Foundation

actor ZAIProvider: UsageProvider {
    nonisolated let id = ProviderID.zai

    private let authStore: ZAIAuthStore
    private let client: ZAIUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: ZAIAuthStore = ZAIAuthStore(),
        client: ZAIUsageClient = ZAIUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let credential = authStore.loadCredential() else {
            throw ProviderFailure(
                .authentication,
                "No GLM Coding Plan key found in Claude Code or OpenCode."
            )
        }

        let response: HTTPResponse
        do {
            response = try await client.fetchQuota(credential)
        } catch {
            throw ProviderFailure(.transient, "Z.ai could not be reached.")
        }

        switch response.statusCode {
        case 401, 403:
            throw ProviderFailure(.authentication, "Z.ai rejected the API key.")
        case 429:
            throw ProviderFailure(
                .rateLimited,
                "Z.ai is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(
                    from: response,
                    now: dateProvider.now()
                )
            )
        default:
            return try ZAIUsageMapper.map(
                response: response,
                now: dateProvider.now()
            )
        }
    }
}
