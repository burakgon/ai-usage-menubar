import Foundation

actor CodexProvider: UsageProvider {
    nonisolated let id = ProviderID.codex

    private let authStore: CodexAuthStore
    private let client: CodexUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: CodexAuthStore = CodexAuthStore(),
        client: CodexUsageClient = CodexUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        let files = authStore.loadFileCandidates()
        var lastAuthenticationFailure: ProviderFailure?

        for candidate in files {
            do {
                return try await probe(candidate)
            } catch let failure as ProviderFailure where failure.kind == .authentication {
                if failure.message == "Usage not available for API key." {
                    throw failure
                }
                lastAuthenticationFailure = failure
            }
        }

        if let keychain = authStore.loadKeychainAuth() {
            do {
                return try await probe(keychain)
            } catch let failure as ProviderFailure {
                throw failure
            }
        }

        throw lastAuthenticationFailure ?? ProviderFailure(
            .authentication,
            "Not logged in. Run `codex` to authenticate."
        )
    }

    private func probe(_ initialState: CodexAuthState) async throws -> ProviderSnapshot {
        var state = initialState
        guard var accessToken = nonEmpty(state.auth.tokens?.accessToken) else {
            if nonEmpty(state.auth.apiKey) != nil {
                throw ProviderFailure(.authentication, "Usage not available for API key.")
            }
            throw ProviderFailure(.authentication, "Not logged in. Run `codex` to authenticate.")
        }

        if authStore.needsRefresh(state.auth),
           let live = authStore.reload(state.source),
           let liveToken = nonEmpty(live.auth.tokens?.accessToken) {
            state = live
            accessToken = liveToken
        }

        if authStore.needsRefresh(state.auth),
           let refreshToken = nonEmpty(state.auth.tokens?.refreshToken) {
            accessToken = try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken
            )
        }

        var response = try await sendUsage(accessToken: accessToken, state: state)
        if response.statusCode == 401 || response.statusCode == 403 {
            guard let refreshToken = nonEmpty(state.auth.tokens?.refreshToken) else {
                throw ProviderFailure(
                    .authentication,
                    "Token expired. Run `codex` to log in again."
                )
            }
            accessToken = try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken
            )
            response = try await sendUsage(accessToken: accessToken, state: state)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderFailure(
                    .authentication,
                    "Token expired. Run `codex` to log in again."
                )
            }
        }

        if response.statusCode == 429 {
            let retryAt = ProviderParsing.retryDate(from: response, now: dateProvider.now())
            throw ProviderFailure(
                .rateLimited,
                "Codex is rate limited. Try again later.",
                retryAt: retryAt
            )
        }

        return try CodexUsageMapper.map(response: response, now: dateProvider.now())
    }

    private func refreshAccessToken(
        state: inout CodexAuthState,
        refreshToken: String
    ) async throws -> String {
        let expected = state
        let response: HTTPResponse
        do {
            response = try await client.refreshToken(refreshToken)
        } catch {
            throw transportFailure(error)
        }

        if response.statusCode == 400 || response.statusCode == 401 {
            let body = try? ProviderParsing.object(from: response.body)
            let errorValue = body?["error"]
            let nested = ProviderParsing.object(errorValue)
            let code = ProviderParsing.string(nested?["code"])
                ?? ProviderParsing.string(nested?["error"])
                ?? ProviderParsing.string(errorValue)
                ?? ProviderParsing.string(body?["code"])
            switch code {
            case "refresh_token_expired":
                throw ProviderFailure(
                    .authentication,
                    "Session expired. Run `codex` to log in again."
                )
            case "refresh_token_reused":
                throw ProviderFailure(
                    .authentication,
                    "Token conflict. Run `codex` to log in again."
                )
            case "refresh_token_invalidated":
                throw ProviderFailure(
                    .authentication,
                    "Token revoked. Run `codex` to log in again."
                )
            default:
                throw ProviderFailure(
                    .invalidResponse,
                    "Codex token refresh failed (\(response.statusCode))."
                )
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Codex token refresh failed (\(response.statusCode))."
            )
        }

        let body: [String: Any]
        do {
            body = try ProviderParsing.object(from: response.body)
        } catch {
            throw ProviderFailure(.invalidResponse, "Codex returned an invalid refreshed token.")
        }
        guard let accessToken = nonEmpty(ProviderParsing.string(body["access_token"])) else {
            throw ProviderFailure(
                .authentication,
                "Token expired. Run `codex` to log in again."
            )
        }

        state.auth.tokens?.accessToken = accessToken
        if let token = nonEmpty(ProviderParsing.string(body["refresh_token"])) {
            state.auth.tokens?.refreshToken = token
        }
        if let token = nonEmpty(ProviderParsing.string(body["id_token"])) {
            state.auth.tokens?.idToken = token
        }
        state.auth.lastRefresh = ISO8601DateFormatter().string(from: dateProvider.now())

        do {
            guard try authStore.save(state, ifUnchanged: expected) else {
                throw ProviderFailure(
                    .authentication,
                    "Codex login changed during refresh. Refresh again."
                )
            }
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            throw ProviderFailure(.storage, "Codex's refreshed login could not be saved.")
        }
        return accessToken
    }

    private func sendUsage(
        accessToken: String,
        state: CodexAuthState
    ) async throws -> HTTPResponse {
        do {
            return try await client.fetchUsage(
                accessToken: accessToken,
                accountID: state.auth.tokens?.accountID
            )
        } catch {
            throw transportFailure(error)
        }
    }

    private func transportFailure(_ error: Error) -> ProviderFailure {
        if let failure = error as? ProviderFailure {
            return failure
        }
        return ProviderFailure(.transient, "Codex could not be reached.")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
