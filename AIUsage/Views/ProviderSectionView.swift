import AppKit
import SwiftUI

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
        VStack(alignment: .leading, spacing: 0) {
            providerHeader
            if let snapshot = state.snapshot,
               !snapshot.windows.isEmpty || snapshot.creditUsage != nil {
                if !snapshot.windows.isEmpty {
                    QuotaGrid(
                        windows: snapshot.windows,
                        displayMode: displayMode
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
                if let creditUsage = snapshot.creditUsage {
                    CreditUsageRow(usage: creditUsage)
                }
            } else if state.isRefreshing {
                ProviderStatusRow(
                    message: "Checking local login…",
                    showsProgress: true
                )
            } else if let failure = state.failure {
                FailureRow(failure: failure)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                ProviderStatusRow(
                    message: "No quota data yet.",
                    systemImage: "chart.bar.xaxis"
                )
            }

            if state.isStale, let failure = state.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(UsagePalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(failure.message)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var providerHeader: some View {
        HStack(spacing: 9) {
            ProviderIcon(provider: state.provider, size: 18)
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)

            Text(state.provider.displayName)
                .font(.headline.weight(.semibold))

            Spacer(minLength: 8)

            if let plan = state.snapshot?.planName {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassEffect(.clear, in: .capsule)
                    .accessibilityLabel("Plan \(plan)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private struct CreditUsageRow: View {
    let usage: CreditUsage

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "creditcard")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)

            Text("Credits")
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(valueText)
                .monospacedDigit()
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Credits")
        .accessibilityValue(valueText)
    }

    private var valueText: String {
        if usage.isUnlimited {
            return "Unlimited"
        }
        if let balance = usage.balanceAmount {
            return "\(currency(balance)) left"
        }
        if let remaining = usage.remainingAmount {
            return "\(currency(remaining)) left"
        }
        if let used = usage.usedAmount {
            return "\(currency(used)) used"
        }
        if let limit = usage.limitAmount {
            return "\(currency(limit)) limit"
        }
        if let percent = usage.usedPercent {
            let formatted = percent.formatted(
                .number.precision(.fractionLength(0...1))
            )
            return "\(formatted)% used"
        }
        return "Available"
    }

    private func currency(_ amount: Double) -> String {
        amount.formatted(
            .currency(code: usage.currencyCode)
                .precision(.fractionLength(2))
        )
    }
}

private struct QuotaGrid: View {
    let windows: [QuotaWindow]
    let displayMode: UsageDisplayMode

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { columnIndex, window in
                        QuotaTile(window: window, displayMode: displayMode)

                        if columnIndex == 0, row.count == 2 {
                            Color(nsColor: .separatorColor)
                                .opacity(0.42)
                                .frame(width: 0.5, height: 48)
                        }
                    }
                }

                if rowIndex < rows.count - 1 {
                    Color(nsColor: .separatorColor)
                        .opacity(0.42)
                        .frame(height: 0.5)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    private var rows: [[QuotaWindow]] {
        stride(from: 0, to: windows.count, by: 2).map { index in
            Array(windows[index..<min(index + 2, windows.count)])
        }
    }
}

private struct QuotaTile: View {
    let window: QuotaWindow
    let displayMode: UsageDisplayMode

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(window.kind.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(percentText)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(valueTint)
                        Text(displayMode.valueSuffix)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.primary.opacity(0.1))
                        Capsule()
                            .fill(progressTint)
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

                if let reset = window.resetsAt {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .foregroundStyle(.tertiary)
                        Text(resetText(reset, relativeTo: context.date))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.kind.title)
            .accessibilityValue(accessibilityValue(relativeTo: context.date))
        }
    }

    private var percentText: String {
        let value = displayMode.displayedPercent(from: window.usedPercent)
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private var valueTint: Color {
        switch window.usedPercent {
        case 85...: UsagePalette.critical
        case 60..<85: UsagePalette.warning
        default: Color(nsColor: .labelColor)
        }
    }

    private var progressTint: Color {
        switch window.usedPercent {
        case 85...: UsagePalette.critical
        case 60..<85: UsagePalette.warning
        default: UsagePalette.normalUsage
        }
    }

    private func resetText(_ date: Date, relativeTo now: Date) -> String {
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        if remaining == 0 {
            return "Resetting"
        }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = max(1, (remaining % 3_600) / 60)
        if days > 0 {
            return hours > 0 ? "Reset \(days)d \(hours)h" : "Reset \(days)d"
        }
        if hours > 0 {
            return "Reset \(hours)h \(minutes)m"
        }
        return "Reset \(minutes)m"
    }

    private func accessibilityValue(relativeTo now: Date) -> String {
        let usage = "\(percentText) \(displayMode.valueSuffix)"
        guard let reset = window.resetsAt else {
            return usage
        }
        return "\(usage), \(resetText(reset, relativeTo: now))"
    }
}

private struct ProviderStatusRow: View {
    let message: String
    var systemImage: String?
    var showsProgress = false

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            }

            Text(message)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

private struct FailureRow: View {
    let failure: ProviderFailure

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(failureTint)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message)
                    .foregroundStyle(failureTint)
                    .fixedSize(horizontal: false, vertical: true)

                if let retryAt = failure.retryAt {
                    HStack(spacing: 3) {
                        Text("Retry")
                        Text(retryAt, style: .relative)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failureTint: Color {
        failure.kind == .authentication
            ? Color(nsColor: .secondaryLabelColor)
            : UsagePalette.warning
    }

    private var symbol: String {
        switch failure.kind {
        case .authentication:
            "person.crop.circle.badge.exclamationmark"
        case .rateLimited:
            "hourglass"
        case .transient, .invalidResponse, .storage:
            "exclamationmark.triangle"
        }
    }
}
