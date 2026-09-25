import AppKit
import SwiftUI

/// Shared type scale for the dashboard's mono lanes.
enum MonoLane {
    static let labelWidth: CGFloat = 58
    static let valueWidth: CGFloat = 106

    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(UsagePalette.Morado.label)
            .lineLimit(1)
            .frame(width: labelWidth, alignment: .leading)
    }

    static func value(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(UsagePalette.Morado.value)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: valueWidth, alignment: .trailing)
    }
}

struct ProviderSectionView: View {
    let state: ProviderState
    let displayMode: UsageDisplayMode

    init(
        state: ProviderState,
        displayMode: UsageDisplayMode = .used
    ) {
        self.state = state
        self.displayMode = displayMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            providerHeader

            if let snapshot = state.snapshot,
               !snapshot.windows.isEmpty || snapshot.billingUsage != nil {
                VStack(spacing: 8) {
                    ForEach(snapshot.windows) { window in
                        QuotaMeterRow(
                            window: window,
                            displayMode: displayMode
                        )
                    }

                    if let billingUsage = snapshot.billingUsage {
                        BillingUsageRow(
                            usage: billingUsage,
                            displayMode: displayMode
                        )
                    }
                }
            } else if state.isRefreshing {
                ProviderStatusRow(
                    message: "Checking local login…",
                    showsProgress: true
                )
            } else if let failure = state.failure {
                FailureRow(failure: failure)
            } else {
                ProviderStatusRow(message: "No quota data yet.")
            }

            if state.isStale, let failure = state.failure,
               state.snapshot != nil {
                MonoLane.label(failure.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(failure.message)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 14)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providerHeader: some View {
        HStack(spacing: 9) {
            ProviderIcon(provider: state.provider, size: 17)
                .foregroundStyle(UsagePalette.Morado.ink)
                .frame(width: 17, height: 17)

            Text(state.provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UsagePalette.Morado.ink)
                .lineLimit(1)

            if let plan = state.snapshot?.planName {
                Text(plan.uppercased())
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(UsagePalette.Morado.faint)
                    .lineLimit(1)
                    .accessibilityLabel("Plan \(plan)")
            }

            Spacer(minLength: 8)

            if let percent = primaryPercentText {
                Text(percent)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UsagePalette.Morado.ink)
                    .lineLimit(1)
            }
        }
    }

    /// The headline number: the same metric the menu bar shows for this
    /// provider, falling back to its first window.
    private var primaryWindow: QuotaWindow? {
        guard let windows = state.snapshot?.windows, !windows.isEmpty else {
            return nil
        }
        let preferred = state.provider.defaultMenuBarMetric.quotaKind
        return windows.first { $0.kind == preferred } ?? windows.first
    }

    private var primaryPercentText: String? {
        guard let window = primaryWindow else { return nil }
        return QuotaFormatting.percentText(
            window.usedPercent,
            displayMode: displayMode
        )
    }
}

enum QuotaFormatting {
    static func percentText(
        _ usedPercent: Double,
        displayMode: UsageDisplayMode
    ) -> String {
        let value = displayMode.displayedPercent(from: usedPercent)
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    /// "2h left", "3d left" — the time until the window resets.
    static func resetText(_ date: Date, relativeTo now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        if remaining == 0 {
            return "resetting"
        }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = max(1, (remaining % 3_600) / 60)
        if days > 0 {
            return "\(days)d left"
        }
        if hours > 0 {
            return "\(hours)h left"
        }
        return "\(minutes)m left"
    }
}

private struct QuotaMeterRow: View {
    let window: QuotaWindow
    let displayMode: UsageDisplayMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 10) {
                MonoLane.label(window.kind.title)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(UsagePalette.Morado.track)
                        Capsule()
                            .fill(UsagePalette.Morado.meter)
                            .frame(
                                width: geometry.size.width *
                                    displayMode.renderedFraction(
                                        from: window.usedPercent
                                    )
                            )
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)

                MonoLane.value(valueText(relativeTo: context.date))
            }
            .frame(height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.kind.title)
            .accessibilityValue(valueText(relativeTo: context.date))
        }
        .frame(height: 14)
    }

    private func valueText(relativeTo now: Date) -> String {
        let percent = QuotaFormatting.percentText(
            window.usedPercent,
            displayMode: displayMode
        )
        guard let reset = window.resetsAt else {
            return percent
        }
        return "\(percent) · \(QuotaFormatting.resetText(reset, relativeTo: now))"
    }
}

struct BillingUsagePresentation: Equatable {
    let title: String
    let valueText: String
    let accessibilityValue: String

    init(
        usage: BillingUsage,
        displayMode: UsageDisplayMode,
        locale: Locale = .current
    ) {
        switch usage {
        case let .boundedSpend(usedAmount, limitAmount, currencyCode):
            let displayedAmount: Double
            let suffix: String
            switch displayMode {
            case .used:
                displayedAmount = usedAmount
                suffix = "spent"
            case .remaining:
                displayedAmount = max(limitAmount - usedAmount, 0)
                suffix = "left"
            }
            let displayed = Self.currency(
                displayedAmount,
                code: currencyCode,
                locale: locale
            )
            let limit = Self.currency(
                limitAmount,
                code: currencyCode,
                locale: locale
            )
            title = "Extra usage"
            valueText = "\(displayed) / \(limit) \(suffix)"
            accessibilityValue = "\(displayed) \(suffix), \(limit) monthly limit"

        case let .unboundedSpend(usedAmount, currencyCode):
            let used = Self.currency(
                usedAmount,
                code: currencyCode,
                locale: locale
            )
            title = "Extra usage"
            valueText = "\(used) spent"
            accessibilityValue = "\(used) spent, no monthly limit"

        case let .flexCreditBalance(remainingCredits, usdValue):
            let value = Self.currency(
                usdValue,
                code: "USD",
                locale: locale
            )
            let credits = Self.integer(remainingCredits, locale: locale)
            title = "Credits"
            valueText = "\(value) · \(credits) credits left"
            accessibilityValue =
                "\(credits) Codex credits remaining, worth \(value)"
        }
    }

    private static func currency(
        _ amount: Double,
        code: String,
        locale: Locale
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private static func integer(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct BillingUsageRow: View {
    let usage: BillingUsage
    let displayMode: UsageDisplayMode

    var body: some View {
        let presentation = BillingUsagePresentation(
            usage: usage,
            displayMode: displayMode
        )

        HStack(spacing: 10) {
            MonoLane.label(presentation.title)
            Spacer(minLength: 8)
            Text(presentation.valueText.uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(UsagePalette.Morado.value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.accessibilityValue)
    }
}

private struct ProviderStatusRow: View {
    let message: String
    var showsProgress = false

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
            }

            Text(message.uppercased())
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(UsagePalette.Morado.label)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FailureRow: View {
    let failure: ProviderFailure

    var body: some View {
        Text(failure.message.uppercased())
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(UsagePalette.Morado.label)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
