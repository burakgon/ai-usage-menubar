import Foundation

/// Antigravity quota, read the way the Antigravity client reads it.
///
/// 1. Google Cloud Code, with the client's User-Agent and metadata and the
///    account's own Cloud project. This works while Antigravity is closed.
/// 2. When Google refuses or cannot be reached, a running Antigravity app or
///    `agy` CLI, which serves the same summary on its loopback listener.
///
/// `fetchAvailableModels` is deliberately not a source: it answers
/// `remainingFraction: 1` for every model even when most of the weekly quota
/// is gone, which would show a confident but false 100% left.
actor AntigravityProvider: UsageProvider {
    nonisolated let id = ProviderID.antigravity

    private struct CodeAssist {
        var plan: String?
        var project: String?
        var checkedAt: Date
    }

    private enum CloudRead {
        case success(ProviderSnapshot)
        case tokenRefused
        case failure(ProviderFailure)
    }

    private static let codeAssistInterval: TimeInterval = 60 * 60

    private let authStore: AntigravityAuthStore
    private let client: AntigravityUsageClient
    private let localClient: AntigravityLocalClient
    private let dateProvider: DateProviding
    private var codeAssist: CodeAssist?

    init(
        authStore: AntigravityAuthStore = AntigravityAuthStore(),
        client: AntigravityUsageClient = AntigravityUsageClient(),
        localClient: AntigravityLocalClient = AntigravityLocalClient(),
        dateProvider: DateProviding = SystemDateProvider()
    ) {
        self.authStore = authStore
        self.client = client
        self.localClient = localClient
        self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        let cloudFailure: ProviderFailure
        do {
            if let auth = try authStore.load() {
                return try await cloudSnapshot(auth)
            }
            cloudFailure = ProviderFailure(
                .authentication,
                "Not logged in. Sign in through Antigravity."
            )
        } catch let failure as ProviderFailure {
            cloudFailure = failure
        } catch {
            cloudFailure = ProviderFailure(
                .transient,
                "Antigravity could not be reached."
            )
        }

        if let data = await localClient.summary(),
           let snapshot = AntigravityUsageMapper.summary(
               [data],
               planName: codeAssist?.plan,
               now: dateProvider.now()
           ) {
            return snapshot
        }
        throw cloudFailure
    }

    private func cloudSnapshot(
        _ auth: AntigravityToken
    ) async throws -> ProviderSnapshot {
        var renewalToken = auth.refreshToken
        var token: String
        if let usable = authStore.usableAccessToken(from: auth) {
            token = usable
        } else if let refresh = renewalToken {
            token = try await refreshedToken(refresh)
            renewalToken = nil
        } else {
            throw Self.expiredSession
        }

        while true {
            switch await readCloud(accessToken: token) {
            case let .success(snapshot):
                return snapshot
            case let .failure(failure):
                throw failure
            case .tokenRefused:
                // A refused token is renewed once; a second refusal is an
                // expired sign-in.
                guard let refresh = renewalToken else {
                    throw Self.expiredSession
                }
                renewalToken = nil
                token = try await refreshedToken(refresh)
            }
        }
    }

    private func readCloud(accessToken: String) async -> CloudRead {
        let now = dateProvider.now()
        if codeAssist.map({
            now.timeIntervalSince($0.checkedAt) >= Self.codeAssistInterval
        }) ?? true {
            switch await client.loadCodeAssist(accessToken: accessToken) {
            case let .success(data):
                codeAssist = CodeAssist(
                    plan: AntigravityUsageMapper.plan(data),
                    project: AntigravityUsageMapper.project(data),
                    checkedAt: now
                )
            case .tokenRefused:
                return .tokenRefused
            case .unavailable, .denied:
                // The plan and project only refine the read; try again in an
                // hour and keep whatever was known.
                codeAssist = CodeAssist(
                    plan: codeAssist?.plan,
                    project: codeAssist?.project,
                    checkedAt: now
                )
            }
        }

        switch await client.quotaSummary(
            accessToken: accessToken,
            project: codeAssist?.project,
            now: now
        ) {
        case let .success(bodies):
            guard let snapshot = AntigravityUsageMapper.summary(
                bodies,
                planName: codeAssist?.plan,
                now: dateProvider.now()
            ) else {
                return .failure(ProviderFailure(
                    .invalidResponse,
                    "Antigravity quota response changed."
                ))
            }
            return .success(snapshot)
        case .tokenRefused:
            return .tokenRefused
        case .denied:
            return .failure(ProviderFailure(
                .transient,
                "Google doesn't share this account's quota. " +
                    "Open Antigravity or `agy` to read it."
            ))
        case let .rateLimited(retryAt):
            return .failure(ProviderFailure(
                .rateLimited,
                "Antigravity is rate limited. Try again later.",
                retryAt: retryAt
            ))
        case .unavailable:
            return .failure(ProviderFailure(
                .transient,
                "Antigravity could not be reached."
            ))
        }
    }

    private func refreshedToken(_ refresh: String) async throws -> String {
        switch await client.refresh(refresh) {
        case let .refreshed(token, expiresIn):
            authStore.cache(
                accessToken: token,
                expiresIn: expiresIn,
                refreshToken: refresh
            )
            return token
        case .rejected:
            throw Self.expiredSession
        case .unavailable:
            throw ProviderFailure(
                .transient,
                "Antigravity could not renew its session."
            )
        }
    }

    private static let expiredSession = ProviderFailure(
        .authentication,
        "Antigravity session expired. Sign in again."
    )
}
