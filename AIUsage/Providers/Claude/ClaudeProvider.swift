import CryptoKit
import Foundation

actor ClaudeProvider: UsageProvider {
    nonisolated let id = ProviderID.claude

    private let authStore: ClaudeAuthStore
    private let client: ClaudeUsageClient
    private let dateProvider: DateProviding
    private var activeCredentialFingerprint: Data?
    private var rateLimitedUntil: Date?

    init(
        authStore: ClaudeAuthStore = ClaudeAuthStore(),
        client: ClaudeUsageClient = ClaudeUsageClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        try await fetch(credentialReloadsRemaining: 1)
    }

    private func fetch(credentialReloadsRemaining: Int) async throws -> ProviderSnapshot {
        let candidates = authStore.loadCandidates().filter(\.hasUsableAccessToken)
        guard !candidates.isEmpty else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Run `claude` to authenticate."
            )
        }

        var generation = ClaudeCredentialGeneration(candidates)
        var lastAuthenticationFailure: ProviderFailure?

        for candidate in candidates {
            do {
                return try await probe(candidate, generation: &generation)
            } catch ClaudeProviderError.credentialsChanged where credentialReloadsRemaining > 0 {
                return try await fetch(credentialReloadsRemaining: credentialReloadsRemaining - 1)
            } catch let failure as ProviderFailure where failure.kind == .authentication {
                lastAuthenticationFailure = failure
                continue
            }
        }

        throw lastAuthenticationFailure ?? ProviderFailure(
            .authentication,
            "Not logged in. Run `claude` to authenticate."
        )
    }

    private func probe(
        _ initialState: ClaudeCredentialState,
        generation: inout ClaudeCredentialGeneration
    ) async throws -> ProviderSnapshot {
        guard authStore.hasUsageScope(initialState.oauth) else {
            throw ProviderFailure(
                .authentication,
                "Re-login for live usage. Run `claude` and sign in again."
            )
        }

        var state = initialState
        activateCooldown(for: state.oauth)
        let now = dateProvider.now()
        if let until = rateLimitedUntil, now < until {
            throw ProviderFailure(
                .rateLimited,
                "Claude is rate limited. Try again later.",
                retryAt: until
            )
        }

        var expectedGeneration = generation
        if authStore.needsRefresh(state.oauth),
           let refreshToken = nonEmpty(state.oauth.refreshToken) {
            try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                expectedGeneration: &expectedGeneration
            )
        }

        guard let accessToken = nonEmpty(state.oauth.accessToken) else {
            throw ProviderFailure(.authentication, "Claude token is missing. Run `claude` to log in.")
        }

        var response = try await sendUsage(accessToken: accessToken)
        if response.statusCode == 401 || response.statusCode == 403 {
            guard let refreshToken = nonEmpty(state.oauth.refreshToken) else {
                throw ProviderFailure(
                    .authentication,
                    "Token expired. Run `claude` to log in again."
                )
            }
            try await refreshAccessToken(
                state: &state,
                refreshToken: refreshToken,
                expectedGeneration: &expectedGeneration
            )
            guard let refreshedToken = nonEmpty(state.oauth.accessToken) else {
                throw ProviderFailure(.authentication, "Claude session expired.")
            }
            response = try await sendUsage(accessToken: refreshedToken)
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderFailure(
                    .authentication,
                    "Token expired. Run `claude` to log in again."
                )
            }
        }

        guard authStore.credentialGeneration() == expectedGeneration else {
            throw ClaudeProviderError.credentialsChanged
        }

        if response.statusCode == 429 {
            let retryAt = ProviderParsing.retryDate(from: response, now: dateProvider.now())
            rateLimitedUntil = retryAt
            throw ProviderFailure(
                .rateLimited,
                "Claude is rate limited. Try again later.",
                retryAt: retryAt
            )
        }

        let snapshot = try ClaudeUsageMapper.map(
            response: response,
            credentials: state.oauth,
            now: dateProvider.now()
        )
        rateLimitedUntil = nil
        generation = expectedGeneration
        return snapshot
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: inout ClaudeCredentialGeneration
    ) async throws {
        let response: HTTPResponse
        do {
            response = try await client.refreshToken(refreshToken)
        } catch {
            throw transportFailure(error)
        }

        if response.statusCode == 400 || response.statusCode == 401 {
            let body = try? ProviderParsing.object(from: response.body)
            let code = ProviderParsing.string(body?["error"])
                ?? ProviderParsing.string(body?["error_description"])
            if code == "invalid_grant" {
                throw ProviderFailure(
                    .authentication,
                    "Session expired. Run `claude` to log in again."
                )
            }
            throw ProviderFailure(
                .invalidResponse,
                "Claude token refresh failed (\(response.statusCode))."
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderFailure(
                response.statusCode >= 500 ? .transient : .invalidResponse,
                "Claude token refresh failed (\(response.statusCode))."
            )
        }

        let decoded: ClaudeRefreshResponse
        do {
            decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        } catch {
            throw ProviderFailure(.invalidResponse, "Claude returned an invalid refreshed token.")
        }
        guard !decoded.accessToken.isEmpty else {
            throw ProviderFailure(.invalidResponse, "Claude returned an empty refreshed token.")
        }

        let previousFingerprint = Self.fingerprint(state.oauth)
        state.oauth.accessToken = decoded.accessToken
        if let refreshToken = nonEmpty(decoded.refreshToken) {
            state.oauth.refreshToken = refreshToken
        }
        if let expiresIn = decoded.expiresIn {
            state.oauth.expiresAt =
                dateProvider.now().timeIntervalSince1970 * 1_000 + expiresIn * 1_000
        }

        do {
            guard try authStore.save(state, ifUnchanged: expectedGeneration) else {
                throw ClaudeProviderError.credentialsChanged
            }
        } catch let error as ClaudeProviderError {
            throw error
        } catch {
            throw ProviderFailure(.storage, "Claude's refreshed login could not be saved.")
        }
        expectedGeneration = expectedGeneration.replacing(state)
        if activeCredentialFingerprint == previousFingerprint {
            activeCredentialFingerprint = Self.fingerprint(state.oauth)
        }
    }

    private func sendUsage(accessToken: String) async throws -> HTTPResponse {
        do {
            return try await client.fetchUsage(accessToken: accessToken)
        } catch {
            throw transportFailure(error)
        }
    }

    private func activateCooldown(for oauth: ClaudeOAuth) {
        let fingerprint = Self.fingerprint(oauth)
        guard fingerprint != activeCredentialFingerprint else { return }
        activeCredentialFingerprint = fingerprint
        rateLimitedUntil = nil
    }

    private func transportFailure(_ error: Error) -> ProviderFailure {
        if let failure = error as? ProviderFailure {
            return failure
        }
        return ProviderFailure(.transient, "Claude could not be reached.")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func fingerprint(_ oauth: ClaudeOAuth) -> Data {
        var pair = Data(SHA256.hash(data: Data((oauth.accessToken ?? "").utf8)))
        pair.append(contentsOf: SHA256.hash(data: Data((oauth.refreshToken ?? "").utf8)))
        return Data(SHA256.hash(data: pair))
    }
}

private enum ClaudeProviderError: Error {
    case credentialsChanged
}
