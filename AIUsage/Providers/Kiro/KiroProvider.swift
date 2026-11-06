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

    private static let signInMessage =
        "Kiro needs you to sign in again. Open Kiro or run `kiro-cli login`."

    func fetch() async throws -> ProviderSnapshot {
        guard var auth = authStore.load() else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Kiro."
            )
        }

        var region = authStore.region(for: auth)

        // An expired access token is refreshed through Kiro's own registered
        // client. A session that cannot refresh is reported as signed out
        // rather than sent with a token Kiro has already rejected.
        if authStore.needsRefresh(auth) {
            do {
                _ = try await authStore.refresh(&auth, client: httpClient)
            } catch let failure as ProviderFailure {
                throw failure
            } catch {
                throw ProviderFailure(.transient, "Kiro could not be reached.")
            }
            region = authStore.region(for: auth)
        }

        var response = try await client.fetchUsage(
            accessToken: try accessToken(of: auth),
            region: region
        )

        if response.statusCode == 401 || response.statusCode == 403 {
            do {
                guard try await authStore.refresh(
                    &auth,
                    client: httpClient
                ) else {
                    throw ProviderFailure(.authentication, Self.signInMessage)
                }
            } catch let failure as ProviderFailure {
                throw failure
            } catch {
                throw ProviderFailure(.transient, "Kiro could not be reached.")
            }
            region = authStore.region(for: auth)
            response = try await client.fetchUsage(
                accessToken: try accessToken(of: auth),
                region: region
            )
        }

        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderFailure(.authentication, Self.signInMessage)
        }

        if response.statusCode == 429 {
            throw ProviderFailure(
                .rateLimited,
                "Kiro is rate limited. Try again later.",
                retryAt: ProviderParsing.retryDate(
                    from: response,
                    now: dateProvider.now()
                )
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Kiro usage request failed (\(response.statusCode))."
            )
        }

        return try KiroUsageMapper.map(
            response: response,
            now: dateProvider.now()
        )
    }

    private func accessToken(of auth: KiroAuthState) throws -> String {
        guard let token = auth.tokenRecord.accessToken, !token.isEmpty else {
            throw ProviderFailure(.authentication, Self.signInMessage)
        }
        return token
    }
}
