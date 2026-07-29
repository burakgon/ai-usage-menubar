import Foundation

actor GrokProvider: UsageProvider {
    nonisolated let id = ProviderID.grok

    private let authStore: GrokAuthStore
    private let client: GrokUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: GrokAuthStore = GrokAuthStore(),
        client: GrokUsageClient = GrokUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        let candidates = authStore.loadCandidates()
        guard !candidates.isEmpty else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Run `grok login`."
            )
        }

        var sawExpired = false
        for var state in candidates {
            do {
                if authStore.needsRefresh(state) {
                    guard try await refresh(&state) else {
                        sawExpired = sawExpired || authStore.isExpired(state)
                        continue
                    }
                }

                var response = try await client.fetchUsage(
                    accessToken: state.token
                )
                if response.statusCode == 401 ||
                    response.statusCode == 403 {
                    guard try await refresh(&state) else {
                        sawExpired = true
                        continue
                    }
                    response = try await client.fetchUsage(
                        accessToken: state.token
                    )
                }
                if response.statusCode == 401 ||
                    response.statusCode == 403 {
                    sawExpired = true
                    continue
                }
                let planResponse = try? await client.fetchSettings(
                    accessToken: state.token
                )
                return try GrokUsageMapper.map(
                    response: response,
                    planResponse: planResponse,
                    now: dateProvider.now()
                )
            } catch let failure as ProviderFailure {
                throw failure
            } catch {
                continue
            }
        }

        if sawExpired {
            throw ProviderFailure(
                .authentication,
                "Grok session expired. Run `grok login`."
            )
        }
        throw ProviderFailure(.transient, "Grok could not be reached.")
    }

    private func refresh(
        _ state: inout GrokAuthState
    ) async throws -> Bool {
        guard let refreshToken = authStore.refreshToken(state.entry) else {
            return false
        }
        guard let response = try? await client.refreshToken(
            refreshToken,
            clientID: authStore.clientID(for: state)
        ),
            (200..<300).contains(response.statusCode),
            let decoded = try? JSONDecoder().decode(
                GrokRefreshResponse.self,
                from: response.body
            ),
            !decoded.accessToken.isEmpty else {
            return false
        }

        state.token = decoded.accessToken
        state.entry.key = decoded.accessToken
        if let token = decoded.refreshToken, !token.isEmpty {
            state.entry.refreshToken = token
        }
        if let token = decoded.idToken, !token.isEmpty {
            state.entry.idToken = token
        }
        let expiration = decoded.expiresIn.map {
            dateProvider.now().addingTimeInterval($0)
        } ?? ProviderParsing.jwtExpiration(decoded.accessToken)
        if let expiration {
            state.entry.expiresAt = ISO8601DateFormatter().string(
                from: expiration
            )
        }
        state.auth[state.entryKey] = state.entry
        try authStore.save(state)
        return true
    }
}
