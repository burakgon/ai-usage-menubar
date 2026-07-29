import Foundation

actor DevinProvider: UsageProvider {
    nonisolated let id = ProviderID.devin

    private let authStore: DevinAuthStore
    private let client: DevinUsageClient
    private let dateProvider: DateProviding

    init(
        authStore: DevinAuthStore = DevinAuthStore(),
        client: DevinUsageClient = DevinUsageClient(),
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
                "Not logged in. Run `devin auth login`."
            )
        }

        var sawAuthenticationFailure = false
        for candidate in candidates {
            do {
                let response = try await client.fetchUserStatus(
                    auth: candidate,
                    serverURL: authStore.effectiveServerURL(for: candidate)
                )
                if response.statusCode == 401 || response.statusCode == 403 {
                    sawAuthenticationFailure = true
                    continue
                }
                return try DevinUsageMapper.map(
                    response: response,
                    now: dateProvider.now()
                )
            } catch let failure as ProviderFailure
            where failure.kind != .transient {
                throw failure
            } catch {
                continue
            }
        }

        if sawAuthenticationFailure {
            throw ProviderFailure(
                .authentication,
                "Devin session expired. Run `devin auth login`."
            )
        }
        throw ProviderFailure(.transient, "Devin could not be reached.")
    }
}
