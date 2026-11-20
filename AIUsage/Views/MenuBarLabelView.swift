import SwiftUI

struct MenuBarPresentation: Equatable, Sendable {
    let valueText: String?
    let accessibilityLabel: String
    let showsStaleIndicator: Bool
    let showsRiskIndicator: Bool

    init(reading: MenuBarReading) {
        let provider = reading.provider.displayName
        let subject = "\(provider) \(reading.metric.title)"
        let label: String
        switch reading.value {
        case .percentage(let percent):
            valueText = "\(Int(percent.rounded()))%"
            let value =
                "\(Int(percent.rounded())) percent \(reading.displayMode.valueSuffix)"
            label = reading.isStale
                ? "\(subject) \(value), stale"
                : "\(subject) \(value)"
        case let .money(amount, currencyCode):
            let formatted = Self.currency(amount, code: currencyCode)
            valueText = formatted
            let qualifier = reading.displayMode == .used ? "spent" : "left"
            label = reading.isStale
                ? "\(subject) \(formatted) \(qualifier), stale"
                : "\(subject) \(formatted) \(qualifier)"
        case let .credits(remaining, usdValue):
            let formatted = Self.currency(usdValue, code: "USD")
            valueText = formatted
            let detail = "\(remaining) credits left, worth \(formatted)"
            label = reading.isStale
                ? "\(subject) \(detail), stale"
                : "\(subject) \(detail)"
        case let .resets(available):
            valueText = "↻\(available)"
            let detail = available == 1
                ? "1 usage limit reset available"
                : "\(available) usage limit resets available"
            label = reading.isStale
                ? "\(provider) \(detail), stale"
                : "\(provider) \(detail)"
        }
        accessibilityLabel = reading.isAtRisk
            ? "\(label), runs out before reset at this pace"
            : label
        showsRiskIndicator = reading.isAtRisk
        showsStaleIndicator = reading.isStale
    }

    static func currency(_ amount: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount))
            ?? "\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(code)"
    }
}

/// The status item's hover text: one block per provider, one line per limit
/// with a status icon, and a detail line with its clock times. Clock times
/// rather than countdowns, because the text is only rebuilt on refresh.
enum MenuBarTooltip {
    static func text(
        for groups: [MenuBarProviderReadings],
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard !groups.isEmpty else { return "AI Usage" }
        return groups.map { group in
            let lines = group.readings.isEmpty
                ? ["No usage data"]
                : group.readings.flatMap {
                    lines(for: $0, now: now, calendar: calendar, locale: locale)
                }
            return ([group.provider.displayName] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func lines(
        for reading: MenuBarReading,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [String] {
        let icon: String
        let value: String
        switch reading.value {
        case .percentage(let percent):
            icon = reading.isAtRisk ? "⏳" : "🟢"
            value = "\(Int(percent.rounded()))% \(reading.displayMode.valueSuffix)"
        case let .money(amount, currencyCode):
            icon = "💳"
            let qualifier = reading.displayMode == .used ? "spent" : "left"
            value = "\(MenuBarPresentation.currency(amount, code: currencyCode)) \(qualifier)"
        case let .credits(remaining, usdValue):
            icon = "🪙"
            value = "\(remaining) credits left, worth \(MenuBarPresentation.currency(usdValue, code: "USD"))"
        case .resets(let available):
            icon = "🔄"
            value = "\(available) available"
        }

        var details: [String] = []
        if reading.isStale {
            details.append("Not updated")
        } else if let exhaustsAt = reading.exhaustsAt {
            details.append("Full by \(time(exhaustsAt, now: now, calendar: calendar, locale: locale)) at this pace")
        }
        if let resetsAt = reading.resetsAt, resetsAt > now {
            details.append("Resets \(time(resetsAt, now: now, calendar: calendar, locale: locale))")
        }

        let title = "\(reading.isStale ? "⚠️" : icon) \(reading.metric.title) — \(value)"
        return details.isEmpty
            ? [title]
            : [title, "      " + details.joined(separator: " · ")]
    }

    /// `11:00` today, `Tue 08:00` within a week, `3 Feb` after that.
    private static func time(
        _ date: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            style = style.hour().minute()
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            style = style.weekday(.abbreviated).hour().minute()
        } else {
            style = style.day().month(.abbreviated)
        }
        return date.formatted(style)
    }
}

struct MenuBarReadingsPresentation: Equatable, Sendable {
    let items: [MenuBarPresentation]
    let accessibilityLabel: String

    init(readings: [MenuBarReading]) {
        items = readings.map(MenuBarPresentation.init(reading:))
        accessibilityLabel = items.isEmpty
            ? "AI usage"
            : items.map(\.accessibilityLabel).joined(separator: ", ")
    }

    init(groups: [MenuBarProviderReadings]) {
        items = groups
            .flatMap(\.readings)
            .map(MenuBarPresentation.init(reading:))
        guard !groups.isEmpty else {
            accessibilityLabel = "AI usage"
            return
        }
        accessibilityLabel = groups.map { group in
            if group.readings.isEmpty {
                return "\(group.provider.displayName), no usage data"
            }
            return group.readings
                .map(MenuBarPresentation.init(reading:))
                .map(\.accessibilityLabel)
                .joined(separator: ", ")
        }.joined(separator: ", ")
    }
}

struct MenuBarMetricPresentation: Equatable, Sendable {
    let label: String?
    let valueText: String
    let showsStaleIndicator: Bool
    var showsRiskIndicator = false
}

struct MenuBarProviderPresentation: Equatable, Sendable {
    let provider: ProviderID
    let metrics: [MenuBarMetricPresentation]
    let sharedSuffix: String?

    init(group: MenuBarProviderReadings) {
        provider = group.provider
        let sharesPercentageSuffix =
            group.showsMetricLabels &&
            !group.readings.isEmpty &&
            group.readings.allSatisfy { reading in
                if case .percentage = reading.value {
                    return true
                }
                return false
            }

        metrics = group.readings.compactMap { reading in
            let presentation = MenuBarPresentation(reading: reading)
            guard var valueText = presentation.valueText,
                  !valueText.isEmpty else {
                return nil
            }

            if sharesPercentageSuffix,
               case .percentage(let percent) = reading.value {
                valueText = "\(Int(percent.rounded()))"
            }

            // The reset count's ↻ already says what it is.
            let needsLabel = group.showsMetricLabels &&
                reading.metric != .resets
            return MenuBarMetricPresentation(
                label: needsLabel ? reading.metric.compactLabel : nil,
                valueText: valueText,
                showsStaleIndicator:
                    presentation.showsStaleIndicator,
                showsRiskIndicator: presentation.showsRiskIndicator
            )
        }
        sharedSuffix = sharesPercentageSuffix ? "%" : nil
    }
}

struct MenuBarProviderLabelView: View {
    let group: MenuBarProviderReadings
    private let microFontSize: CGFloat = 8

    var body: some View {
        let presentation = MenuBarProviderPresentation(group: group)

        HStack(spacing: 4) {
            ProviderIcon(provider: group.provider, size: 15)

            HStack(spacing: 0) {
                ForEach(
                    Array(presentation.metrics.enumerated()),
                    id: \.offset
                ) { index, metric in
                    if index > 0 {
                        Text("·")
                            .font(.system(
                                size: microFontSize,
                                weight: .semibold
                            ))
                            .padding(.horizontal, 3)
                    }

                    if let label = metric.label {
                        Text(label)
                            .font(.system(
                                size: microFontSize,
                                weight: .semibold
                            ))
                            .baselineOffset(2)
                            .padding(.trailing, 1)
                    }

                    Text(metric.valueText)
                        .monospacedDigit()

                    if index == presentation.metrics.count - 1,
                       let suffix = presentation.sharedSuffix {
                        Text(suffix)
                            .font(.system(
                                size: microFontSize,
                                weight: .semibold
                            ))
                            .padding(.leading, 1)
                    }

                    if metric.showsStaleIndicator {
                        Text("⚠︎")
                            .font(.system(
                                size: microFontSize,
                                weight: .semibold
                            ))
                            .padding(.leading, 1)
                    } else if metric.showsRiskIndicator {
                        Image(systemName: "hourglass")
                            .font(.system(
                                size: microFontSize,
                                weight: .semibold
                            ))
                            .padding(.leading, 1)
                    }
                }
            }
        }
        .accessibilityLabel(
            MenuBarReadingsPresentation(
                groups: [group]
            ).accessibilityLabel
        )
    }
}
