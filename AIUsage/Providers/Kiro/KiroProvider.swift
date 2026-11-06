import Foundation

actor KiroProvider: UsageProvider {
    nonisolated let id = ProviderID.kiro

    private let authStore: KiroAuthStore
    private let client: KiroUsageClient
    private let httpClient: any HTTPClient
    private let dateProvider: DateProviding

    init(
        authStore: KiroAuthStore = KiroAuthStore(),
        client: KiroUsageClient = KiroUsageClient(),
        httpClient: any HTTPClient = URLSessionHTTPClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.httpClient = httpClient
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard var auth = authStore.load() else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Kiro."
            )
        }

        if authStore.needsRefresh(auth) {
            _ = try? await authStore.refresh(&auth, client: httpClient)
        }

        guard let token = auth.tokenRecord.accessToken, !token.isEmpty else {
            throw ProviderFailure(
                .authentication,
                "Kiro session expired. Sign in again."
            )
        }

        let region = auth.tokenRecord.region ?? "us-east-1"
        var response = try await client.fetchUsage(accessToken: token, region: region)

        if response.statusCode == 401 || response.statusCode == 403 {
            if (try? await authStore.refresh(&auth, client: httpClient)) == true,
               let refreshedToken = auth.tokenRecord.accessToken {
                response = try await client.fetchUsage(accessToken: refreshedToken, region: region)
            }
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderFailure(
                .authentication,
                "Kiro session expired. Sign in again."
            )
        }

        if response.statusCode == 429 {
            throw ProviderFailure(
                .rateLimited,
                "Kiro is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(from: response, now: dateProvider.now())
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Kiro usage request failed (\(response.statusCode))."
            )
        }

        return try KiroUsageMapper.map(response: response, now: dateProvider.now())
    }
}
