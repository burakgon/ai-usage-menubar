import Foundation

actor QoderProvider: UsageProvider {
    nonisolated let id = ProviderID.qoder

    private let authStore: QoderAuthStore
    private let client: QoderUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: QoderAuthStore = QoderAuthStore(),
        client: QoderUsageClient = QoderUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard let auth = authStore.load() else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Qoder."
            )
        }

        let usage = try await client.fetchUsage(accessToken: auth.accessToken)
        if usage.statusCode == 401 || usage.statusCode == 403 {
            throw ProviderFailure(
                .authentication,
                "Qoder session expired. Open Qoder and sign in again."
            )
        }
        if usage.statusCode == 429 {
            throw ProviderFailure(
                .rateLimited,
                "Qoder is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(from: usage, now: dateProvider.now())
            )
        }

        let plan = try? await client.fetchPlan(accessToken: auth.accessToken)
        return try QoderUsageMapper.map(
            usage: usage,
            plan: plan,
            fallbackPlanName: auth.planName,
            now: dateProvider.now()
        )
    }
}
