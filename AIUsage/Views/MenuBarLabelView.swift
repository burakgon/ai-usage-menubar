import SwiftUI

struct MenuBarLabelView: View {
    let reading: MenuBarReading

    var body: some View {
        HStack(spacing: 4) {
            if let provider = reading.provider {
                ProviderIcon(provider: provider, size: 15)
            } else {
                Image(systemName: "gauge.with.dots.needle.50percent")
            }
            if let percent = reading.percent {
                Text("\(Int(percent.rounded()))%")
                    .monospacedDigit()
            } else if reading.showsPlaceholder {
                Text("--")
            }
            if reading.isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let subject = reading.provider?.displayName ?? "AI usage"
        if let percent = reading.percent {
            let value =
                "\(Int(percent.rounded())) percent \(reading.displayMode.valueSuffix)"
            return reading.isStale
                ? "\(subject) \(value), stale"
                : "\(subject) \(value)"
        }
        return subject
    }
}
