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
    /// An access token renewed with the Cursor CLI's refresh token. It is
    /// kept in memory only, for as long as that refresh token is the stored
    /// one, so the CLI's Keychain items are never written and the token is
    /// not renewed again on every refresh.
    private var renewedCLIToken: (accessToken: String, refreshToken: String)?

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
        var auth: CursorAuthState
        switch authStore.load() {
        case let .session(state):
            auth = state
        case .sealedEditorLogin:
            throw ProviderFailure(
                .authentication,
                "Cursor's editor login is encrypted. " +
                    "Sign in to the Cursor CLI with `agent login`."
            )
        case .signedOut:
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Cursor."
            )
        }
        if auth.source == .keychain,
           authStore.needsRefresh(auth.accessToken),
           let renewed = renewedCLIToken,
           renewed.refreshToken == auth.refreshToken {
            auth.accessToken = renewed.accessToken
        }
        if authStore.needsRefresh(auth.accessToken) {
            try await refresh(&auth)
        }
        guard var token = auth.accessToken else {
            throw Self.expiredSession(auth.source)
        }

        var usage = try await requestUsage(token)
        if usage.statusCode == 401 || usage.statusCode == 403 {
            try await refresh(&auth)
            guard let refreshed = auth.accessToken else {
                throw Self.expiredSession(auth.source)
            }
            token = refreshed
            usage = try await requestUsage(token)
        }
        if usage.statusCode == 401 || usage.statusCode == 403 {
            throw Self.expiredSession(auth.source)
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

    /// Signing in to the editor again does not renew the Cursor CLI's login,
    /// so an expired CLI session names the command that does.
    private static func expiredSession(
        _ source: CursorAuthState.Source
    ) -> ProviderFailure {
        switch source {
        case .sqlite:
            ProviderFailure(
                .authentication,
                "Cursor session expired. Sign in again."
            )
        case .keychain:
            ProviderFailure(
                .authentication,
                "Cursor CLI session expired. Run `agent login`."
            )
        }
    }

    private func refresh(_ auth: inout CursorAuthState) async throws {
        guard let refreshToken = auth.refreshToken else {
            throw Self.expiredSession(auth.source)
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
            throw Self.expiredSession(auth.source)
        }
        switch auth.source {
        case .sqlite:
            do {
                try authStore.saveEditorAccessToken(decoded.accessToken)
            } catch {
                throw ProviderFailure(
                    .storage,
                    "Cursor session could not be saved."
                )
            }
        case .keychain:
            renewedCLIToken = (decoded.accessToken, refreshToken)
        }
        auth.accessToken = decoded.accessToken
    }
}
