import Foundation

private struct CursorRefreshResponse: Decodable {
    let accessToken: String
    let shouldLogout: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case shouldLogout
    }
}

actor CursorProvider: UsageProvider {
    nonisolated let id = ProviderID.cursor

    private let authStore: CursorAuthStore
    private let client: CursorUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        client: CursorUsageClient = CursorUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        guard var auth = authStore.load() else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Cursor."
            )
        }
        if authStore.needsRefresh(auth.accessToken) {
            try await refresh(&auth)
        }
        guard var token = auth.accessToken else {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }

        var usage = try await requestUsage(token)
        if usage.statusCode == 401 || usage.statusCode == 403 {
            try await refresh(&auth)
            guard let refreshed = auth.accessToken else {
                throw ProviderFailure(
                    .authentication,
                    "Cursor session expired. Sign in again."
                )
            }
            token = refreshed
            usage = try await requestUsage(token)
        }
        if usage.statusCode == 401 || usage.statusCode == 403 {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }
        if usage.statusCode == 429 {
            throw ProviderFailure(
                .rateLimited,
                "Cursor is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(
                    from: usage,
                    now: dateProvider.now()
                )
            )
        }
        let plan = try? await client.fetchPlan(accessToken: token)
        return try CursorUsageMapper.map(
            usageResponse: usage,
            planResponse: plan,
            now: dateProvider.now()
        )
    }

    private func requestUsage(_ token: String) async throws -> HTTPResponse {
        do {
            return try await client.fetchUsage(accessToken: token)
        } catch {
            throw ProviderFailure(
                .transient,
                "Cursor could not be reached."
            )
        }
    }

    private func refresh(_ auth: inout CursorAuthState) async throws {
        guard let refreshToken = auth.refreshToken else {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }
        let response: HTTPResponse
        do {
            response = try await client.refresh(refreshToken)
        } catch {
            throw ProviderFailure(
                .transient,
                "Cursor could not refresh its session."
            )
        }
        guard (200..<300).contains(response.statusCode),
              let decoded = try? JSONDecoder().decode(
                CursorRefreshResponse.self,
                from: response.body
              ),
              decoded.shouldLogout != true,
              !decoded.accessToken.isEmpty else {
            throw ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        }
        do {
            try authStore.saveAccessToken(
                decoded.accessToken,
                source: auth.source
            )
        } catch {
            throw ProviderFailure(
                .storage,
                "Cursor session could not be saved."
            )
        }
        auth.accessToken = decoded.accessToken
    }
}
