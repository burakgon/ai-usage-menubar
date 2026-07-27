import SwiftUI

struct MenuBarPresentation: Equatable, Sendable {
    let valueText: String?
    let accessibilityLabel: String
    let showsStaleIndicator: Bool

    init(reading: MenuBarReading) {
        if let percent = reading.percent {
            valueText = "\(Int(percent.rounded()))%"
        } else if reading.showsPlaceholder {
            valueText = "--"
        } else {
            valueText = nil
        }

        let subject = reading.provider?.displayName ?? "AI usage"
        if let percent = reading.percent {
            let value =
                "\(Int(percent.rounded())) percent \(reading.displayMode.valueSuffix)"
            accessibilityLabel = reading.isStale
                ? "\(subject) \(value), stale"
                : "\(subject) \(value)"
        } else {
            accessibilityLabel = subject
        }
        showsStaleIndicator = reading.isStale
    }
}

struct MenuBarLabelView: View {
    let reading: MenuBarReading

    var body: some View {
        let presentation = MenuBarPresentation(reading: reading)

        HStack(spacing: 4) {
            if let provider = reading.provider {
                ProviderIcon(provider: provider, size: 15)
            } else {
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
            if let valueText = presentation.valueText {
                Text(valueText)
                    .monospacedDigit()
            }
            if presentation.showsStaleIndicator {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
            }
        }
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}
