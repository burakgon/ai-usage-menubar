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

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: self,
            displayName: displayName,
            iconAssetName: iconAssetName,
            executableName: rawValue
        )
    }
}

enum QuotaKind: String, Codable, Hashable, Sendable {
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

    var menuBarMetric: MenuBarMetricID {
        switch self {
        case .session: .session
        case .weekly: .weekly
        case .sonnet: .sonnet
        case .fable: .fable
        case .sparkSession: .spark
        case .sparkWeekly: .sparkWeekly
        }
    }
}

enum MenuBarMetricID: String, CaseIterable, Codable, Identifiable, Sendable {
    case session
    case weekly
    case sonnet
    case fable
    case spark
    case sparkWeekly
    case extraUsage
    case credits

    var id: Self { self }

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .sonnet: "Sonnet"
        case .fable: "Fable"
        case .spark: "Spark"
        case .sparkWeekly: "Spark Weekly"
        case .extraUsage: "Extra Usage"
        case .credits: "Credits"
        }
    }

    var systemImage: String {
        switch self {
        case .session: "clock"
        case .weekly: "calendar"
        case .sonnet: "waveform"
        case .fable: "book.closed"
        case .spark: "sparkles"
        case .sparkWeekly: "calendar.badge.clock"
        case .extraUsage: "dollarsign.circle"
        case .credits: "creditcard"
        }
    }

    var compactLabel: String {
        switch self {
        case .session: "S"
        case .weekly: "W"
        case .sonnet: "So"
        case .fable: "F"
        case .spark: "Sp"
        case .sparkWeekly: "SpW"
        case .extraUsage: "E"
        case .credits: "C"
        }
    }

    var quotaKind: QuotaKind? {
        switch self {
        case .session: .session
        case .weekly: .weekly
        case .sonnet: .sonnet
        case .fable: .fable
        case .spark: .sparkSession
        case .sparkWeekly: .sparkWeekly
        case .extraUsage, .credits: nil
        }
    }
}

struct MenuBarItemID: Codable, Hashable, Identifiable, Sendable {
    let provider: ProviderID
    let metric: MenuBarMetricID

    var id: String { "\(provider.rawValue).\(metric.rawValue)" }
    var title: String { "\(provider.displayName) · \(metric.title)" }
}

struct MenuBarProviderConfiguration:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    let provider: ProviderID
    let metrics: [MenuBarMetricID]

    var id: ProviderID { provider }
}

struct ProviderDescriptor: Identifiable, Sendable {
    let id: ProviderID
    let displayName: String
    let iconAssetName: String
    let executableName: String
}

enum ProviderCatalog {
    static let all = ProviderID.allCases.map(\.descriptor)

    static func descriptor(for provider: ProviderID) -> ProviderDescriptor {
        provider.descriptor
    }
}

struct QuotaWindow: Identifiable, Equatable, Sendable {
    let kind: QuotaKind
    let usedPercent: Double
    let resetsAt: Date?

    var id: QuotaKind { kind }
    var renderedFraction: Double { min(max(usedPercent / 100, 0), 1) }
}

enum BillingUsage: Equatable, Sendable {
    case boundedSpend(
        usedAmount: Double,
        limitAmount: Double,
        currencyCode: String
    )
    case unboundedSpend(
        usedAmount: Double,
        currencyCode: String
    )
    case flexCreditBalance(
        remainingCredits: Int,
        usdValue: Double
    )

    var menuBarMetric: MenuBarMetricID {
        switch self {
        case .boundedSpend, .unboundedSpend: .extraUsage
        case .flexCreditBalance: .credits
        }
    }

    func menuBarValue(
        displayMode: UsageDisplayMode
    ) -> MenuBarReadingValue {
        switch self {
        case let .boundedSpend(usedAmount, limitAmount, currencyCode):
            let amount = displayMode == .used
                ? usedAmount
                : max(limitAmount - usedAmount, 0)
            return .money(amount: amount, currencyCode: currencyCode)
        case let .unboundedSpend(usedAmount, currencyCode):
            return .money(amount: usedAmount, currencyCode: currencyCode)
        case let .flexCreditBalance(remainingCredits, usdValue):
            return .credits(
                remaining: remainingCredits,
                usdValue: usdValue
            )
        }
    }
}

enum MenuBarReadingValue: Equatable, Sendable {
    case percentage(Double)
    case money(amount: Double, currencyCode: String)
    case credits(remaining: Int, usdValue: Double)
}

struct ProviderSnapshot: Equatable, Sendable {
    let provider: ProviderID
    let planName: String?
    let windows: [QuotaWindow]
    let billingUsage: BillingUsage?
    let fetchedAt: Date

    init(
        provider: ProviderID,
        planName: String?,
        windows: [QuotaWindow],
        billingUsage: BillingUsage? = nil,
        fetchedAt: Date
    ) {
        self.provider = provider
        self.planName = planName
        self.windows = windows
        self.billingUsage = billingUsage
        self.fetchedAt = fetchedAt
    }

    var sessionWindow: QuotaWindow? {
        windows.first { $0.kind == .session }
    }

    func window(for metric: MenuBarMetricID) -> QuotaWindow? {
        guard let quotaKind = metric.quotaKind else { return nil }
        return windows.first { $0.kind == quotaKind }
    }

    var availableMenuBarItems: [MenuBarItemID] {
        var items = windows.map {
            MenuBarItemID(provider: provider, metric: $0.kind.menuBarMetric)
        }
        if let billingUsage {
            items.append(MenuBarItemID(
                provider: provider,
                metric: billingUsage.menuBarMetric
            ))
        }
        var seen: Set<MenuBarItemID> = []
        return items.filter { seen.insert($0).inserted }
    }

    func menuBarValue(
        for metric: MenuBarMetricID,
        displayMode: UsageDisplayMode
    ) -> MenuBarReadingValue? {
        if let window = window(for: metric) {
            return .percentage(
                displayMode.displayedPercent(from: window.usedPercent)
            )
        }
        guard billingUsage?.menuBarMetric == metric else { return nil }
        return billingUsage?.menuBarValue(displayMode: displayMode)
    }

    func primaryWindow(for selection: MenuBarWindow) -> QuotaWindow? {
        switch selection {
        case .session:
            windows.first { $0.kind == .session }
        case .weekly:
            windows.first { $0.kind == .weekly }
        }
    }

    func primaryWindowWithFallback(
        for selection: MenuBarWindow
    ) -> QuotaWindow? {
        if let selected = primaryWindow(for: selection) {
            return selected
        }
        let fallback: MenuBarWindow =
            selection == .session ? .weekly : .session
        return primaryWindow(for: fallback)
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
    var isToolInstalled: Bool?

    var isStale: Bool { snapshot != nil && failure != nil }

    var isVisibleInDashboard: Bool {
        isToolInstalled != false
    }
}

enum MenuBarSelection: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case all
    case claude
    case codex

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Auto — Highest usage"
        case .all: "All providers"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var provider: ProviderID? {
        switch self {
        case .automatic, .all: nil
        case .claude: .claude
        case .codex: .codex
        }
    }
}

enum MenuBarWindow: String, CaseIterable, Identifiable, Sendable {
    case session
    case weekly

    var id: Self { self }

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
}

enum UsageDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case remaining
    case used

    static let defaultSelection: Self = .remaining

    var id: Self { self }

    var title: String {
        switch self {
        case .used: "Used"
        case .remaining: "Left"
        }
    }

    var valueSuffix: String {
        switch self {
        case .used: "used"
        case .remaining: "left"
        }
    }

    func displayedPercent(from usedPercent: Double) -> Double {
        switch self {
        case .used:
            usedPercent
        case .remaining:
            100 - min(max(usedPercent, 0), 100)
        }
    }

    func renderedFraction(from usedPercent: Double) -> Double {
        min(max(displayedPercent(from: usedPercent) / 100, 0), 1)
    }
}

enum RefreshIntervalOption: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case oneHour

    var id: Self { self }

    var title: String {
        switch self {
        case .oneMinute: "Every minute"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .thirtyMinutes: "Every 30 minutes"
        case .oneHour: "Every hour"
        }
    }

    var duration: Duration {
        switch self {
        case .oneMinute: .seconds(60)
        case .fiveMinutes: .seconds(300)
        case .fifteenMinutes: .seconds(900)
        case .thirtyMinutes: .seconds(1_800)
        case .oneHour: .seconds(3_600)
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
