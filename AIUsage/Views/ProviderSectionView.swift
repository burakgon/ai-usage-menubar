import AppKit
import SwiftUI

struct ProviderSectionView: View {
    let state: ProviderState
    private let columns = [
        GridItem(.flexible(), spacing: 0),
        GridItem(.flexible(), spacing: 0)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            providerHeader
            if let snapshot = state.snapshot, !snapshot.windows.isEmpty {
                let rowCount = (snapshot.windows.count + 1) / 2
                LazyVGrid(columns: columns, spacing: 0) {
                    ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                        QuotaTile(window: window)
                            .overlay(alignment: .trailing) {
                                if index.isMultiple(of: 2), index + 1 < snapshot.windows.count {
                                    Color(nsColor: .separatorColor)
                                        .opacity(0.42)
                                        .frame(width: 0.5)
                                        .padding(.vertical, 6)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if index / 2 < rowCount - 1 {
                                    Color(nsColor: .separatorColor)
                                        .opacity(0.42)
                                        .frame(height: 0.5)
                                        .padding(.horizontal, 6)
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            } else if state.isRefreshing {
                Text("Checking local login…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else if let failure = state.failure {
                FailureRow(failure: failure)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                Text("No quota data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }

            if state.isStale, let failure = state.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(UsagePalette.warning)
                    .lineLimit(2)
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
                .foregroundStyle(.secondary)
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private struct QuotaTile: View {
    let window: QuotaWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(window.kind.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(percentText)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.primary.opacity(0.1))
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * window.renderedFraction)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)

                if let reset = window.resetsAt {
                    Label(
                        resetText(reset, relativeTo: context.date),
                        systemImage: "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        let value = window.usedPercent
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private var tint: Color {
        switch window.usedPercent {
        case 85...: UsagePalette.critical
        case 60..<85: UsagePalette.warning
        default: UsagePalette.accent
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
        guard let reset = window.resetsAt else {
            return "\(percentText) used"
        }
        return "\(percentText) used, \(resetText(reset, relativeTo: now))"
    }
}

private struct FailureRow: View {
    let failure: ProviderFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(failure.message, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(
                    failure.kind == .authentication
                        ? Color(nsColor: .secondaryLabelColor)
                        : UsagePalette.warning
                )
                .fixedSize(horizontal: false, vertical: true)
            if let retryAt = failure.retryAt {
                HStack(spacing: 3) {
                    Text("Retry")
                    Text(retryAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var symbol: String {
        failure.kind == .authentication ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle"
    }
}
