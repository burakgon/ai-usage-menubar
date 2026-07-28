import SwiftUI

struct MenuBarPresentation: Equatable, Sendable {
    let valueText: String?
    let accessibilityLabel: String
    let showsStaleIndicator: Bool

    init(reading: MenuBarReading) {
        let provider = reading.provider.displayName
        let subject = "\(provider) \(reading.metric.title)"
        switch reading.value {
        case .percentage(let percent):
            valueText = "\(Int(percent.rounded()))%"
            let value =
                "\(Int(percent.rounded())) percent \(reading.displayMode.valueSuffix)"
            accessibilityLabel = reading.isStale
                ? "\(subject) \(value), stale"
                : "\(subject) \(value)"
        case let .money(amount, currencyCode):
            let formatted = Self.currency(amount, code: currencyCode)
            valueText = formatted
            let qualifier = reading.displayMode == .used ? "spent" : "left"
            accessibilityLabel = reading.isStale
                ? "\(subject) \(formatted) \(qualifier), stale"
                : "\(subject) \(formatted) \(qualifier)"
        case let .credits(remaining, usdValue):
            let formatted = Self.currency(usdValue, code: "USD")
            valueText = formatted
            let detail = "\(remaining) credits left, worth \(formatted)"
            accessibilityLabel = reading.isStale
                ? "\(subject) \(detail), stale"
                : "\(subject) \(detail)"
        }
        showsStaleIndicator = reading.isStale
    }

    private static func currency(_ amount: Double, code: String) -> String {
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

            return MenuBarMetricPresentation(
                label: group.showsMetricLabels
                    ? reading.metric.compactLabel
                    : nil,
                valueText: valueText,
                showsStaleIndicator:
                    presentation.showsStaleIndicator
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
