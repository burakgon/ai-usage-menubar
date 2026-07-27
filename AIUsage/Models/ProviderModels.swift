import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex

    var id: Self { self }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var iconAssetName: String {
        switch self {
        case .claude: "ProviderClaude"
        case .codex: "ProviderCodex"
        }
    }
}

enum QuotaKind: String, Codable, Sendable {
    case session
    case weekly
    case sonnet
    case fable
    case sparkSession
    case sparkWeekly

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .sonnet: "Sonnet"
        case .fable: "Fable"
        case .sparkSession: "Spark"
        case .sparkWeekly: "Spark Weekly"
        }
    }
}

struct QuotaWindow: Identifiable, Equatable, Sendable {
    let kind: QuotaKind
    let usedPercent: Double
    let resetsAt: Date?

    var id: QuotaKind { kind }
    var renderedFraction: Double { min(max(usedPercent / 100, 0), 1) }
}

struct ProviderSnapshot: Equatable, Sendable {
    let provider: ProviderID
    let planName: String?
    let windows: [QuotaWindow]
    let fetchedAt: Date

    var sessionWindow: QuotaWindow? {
        windows.first { $0.kind == .session }
    }

    /// The provider's best current headline value. Some Codex plans currently expose only a
    /// weekly window, so a session-only lookup would turn a valid response into `--`.
    var indicatorWindow: QuotaWindow? {
        sessionWindow ?? windows.first
    }
}

enum ProviderFailureKind: String, Sendable {
    case authentication
    case transient
    case rateLimited
    case invalidResponse
    case storage
}

struct ProviderFailure: LocalizedError, Equatable, Sendable {
    let kind: ProviderFailureKind
    let message: String
    let retryAt: Date?

    init(_ kind: ProviderFailureKind, _ message: String, retryAt: Date? = nil) {
        self.kind = kind
        self.message = message
        self.retryAt = retryAt
    }

    var errorDescription: String? { message }

    var preservesLastGood: Bool {
        switch kind {
        case .transient, .rateLimited, .invalidResponse:
            true
        case .authentication, .storage:
            false
        }
    }
}

struct ProviderState: Equatable, Sendable {
    let provider: ProviderID
    var snapshot: ProviderSnapshot?
    var failure: ProviderFailure?
    var isRefreshing = false

    var isStale: Bool { snapshot != nil && failure != nil }
}

enum MenuBarSelection: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case claude
    case codex

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Auto — Highest current usage"
        case .claude: "Claude current limit"
        case .codex: "Codex current limit"
        }
    }

    var provider: ProviderID? {
        switch self {
        case .automatic: nil
        case .claude: .claude
        case .codex: .codex
        }
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
}

protocol DateProviding: Sendable {
    func now() -> Date
}

struct SystemDateProvider: DateProviding {
    func now() -> Date { Date() }
}
