import Foundation
import Observation

struct MenuBarReading: Equatable, Sendable {
    let provider: ProviderID?
    let percent: Double?
    let displayMode: UsageDisplayMode
    let isStale: Bool
    let showsPlaceholder: Bool
}

@MainActor
@Observable
final class UsageStore {
    private(set) var states: [ProviderID: ProviderState]
    private(set) var lastAttemptAt: Date?
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var refreshInterval: RefreshIntervalOption

    private let providers: [any UsageProvider]
    private var cadenceTask: Task<Void, Never>?
    private var refreshTask: Task<[FetchResult], Never>?

    init(
        providers: [any UsageProvider] = [ClaudeProvider(), CodexProvider()],
        refreshInterval: RefreshIntervalOption = .fiveMinutes
    ) {
        self.providers = providers
        self.refreshInterval = refreshInterval
        states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, ProviderState(provider: $0))
        })
    }

    func start() {
        guard cadenceTask == nil else { return }
        LoginShellEnvironment.shared.prewarm()
        cadenceTask = makeCadenceTask(refreshImmediately: true)
    }

    func stop() {
        cadenceTask?.cancel()
        cadenceTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func setRefreshInterval(_ interval: RefreshIntervalOption) {
        guard refreshInterval != interval else { return }
        refreshInterval = interval

        guard cadenceTask != nil else { return }
        cadenceTask?.cancel()
        cadenceTask = makeCadenceTask(refreshImmediately: false)
    }

    func refreshNow() {
        cadenceTask?.cancel()
        cadenceTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            guard !Task.isCancelled else { return }
            self.cadenceTask = self.makeCadenceTask(refreshImmediately: false)
        }
    }

    func refresh() async {
        if let refreshTask {
            _ = await refreshTask.value
            return
        }

        for provider in providers {
            states[provider.id]?.isRefreshing = true
        }
        let providers = self.providers
        let task = Task {
            await withTaskGroup(of: FetchResult.self) { group in
                for provider in providers {
                    group.addTask {
                        do {
                            return FetchResult(
                                provider: provider.id,
                                result: .success(try await provider.fetch())
                            )
                        } catch let failure as ProviderFailure {
                            return FetchResult(provider: provider.id, result: .failure(failure))
                        } catch {
                            return FetchResult(
                                provider: provider.id,
                                result: .failure(ProviderFailure(
                                    .transient,
                                    "\(provider.id.displayName) could not be refreshed."
                                ))
                            )
                        }
                    }
                }

                var results: [FetchResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }
        refreshTask = task
        let results = await task.value
        refreshTask = nil

        lastAttemptAt = Date()
        var successfulDates: [Date] = []
        for result in results {
            var state = states[result.provider] ?? ProviderState(provider: result.provider)
            state.isRefreshing = false
            switch result.result {
            case .success(let snapshot):
                state.snapshot = snapshot
                state.failure = nil
                successfulDates.append(snapshot.fetchedAt)
            case .failure(let failure):
                if !failure.preservesLastGood {
                    state.snapshot = nil
                }
                state.failure = failure
            }
            states[result.provider] = state
        }
        if let latest = successfulDates.max() {
            lastSuccessfulRefreshAt = latest
        }
    }

    func menuBarReading(
        for selection: MenuBarSelection,
        window windowSelection: MenuBarWindow = .session,
        displayMode: UsageDisplayMode = .used
    ) -> MenuBarReading {
        switch selection {
        case .automatic:
            let candidates = ProviderID.allCases.compactMap { provider -> (ProviderID, Double, Bool)? in
                guard let state = states[provider],
                      let value = state.snapshot?
                        .primaryWindow(for: windowSelection)?
                        .usedPercent else {
                    return nil
                }
                return (provider, value, state.isStale)
            }
            guard let highest = candidates.max(by: { $0.1 < $1.1 }) else {
                return MenuBarReading(
                    provider: nil,
                    percent: nil,
                    displayMode: displayMode,
                    isStale: false,
                    showsPlaceholder: false
                )
            }
            return MenuBarReading(
                provider: highest.0,
                percent: displayMode.displayedPercent(from: highest.1),
                displayMode: displayMode,
                isStale: highest.2,
                showsPlaceholder: false
            )

        case .claude, .codex:
            let provider: ProviderID = selection == .claude ? .claude : .codex
            let state = states[provider]
            let window = state?.snapshot?.primaryWindow(for: windowSelection)
            return MenuBarReading(
                provider: provider,
                percent: window.map {
                    displayMode.displayedPercent(from: $0.usedPercent)
                },
                displayMode: displayMode,
                isStale: state?.isStale == true,
                showsPlaceholder: window == nil
            )
        }
    }

    private func makeCadenceTask(refreshImmediately: Bool) -> Task<Void, Never> {
        let duration = refreshInterval.duration
        return Task { [weak self, duration] in
            if refreshImmediately {
                await self?.refresh()
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}

private struct FetchResult: Sendable {
    let provider: ProviderID
    let result: Result<ProviderSnapshot, ProviderFailure>
}
