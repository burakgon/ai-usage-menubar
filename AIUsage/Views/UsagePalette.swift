import AppKit
import SwiftUI

enum UsagePalette {
    static let accent = Color(nsColor: .systemBlue)
    static let normalUsage = Color(nsColor: .systemTeal)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)

    /// Mentem "Morado" dark system, taken from the brand file.
    /// The dashboard renders in a fixed dark appearance so these read the
    /// same regardless of the system theme.
    enum Morado {
        /// The three-layer near-black violet field from the Paper source.
        static let panel = Color(red: 14 / 255, green: 11 / 255, blue: 30 / 255)
        static let panelDeep = Color(red: 7 / 255, green: 6 / 255, blue: 15 / 255)
        static let panelViolet = Color(red: 10 / 255, green: 8 / 255, blue: 24 / 255)
        static let ink = Color(red: 0.949, green: 0.941, blue: 0.973)
        static let lavender = Color(red: 0.804, green: 0.776, blue: 0.894)
        static let morado = Color(red: 0.290, green: 0.220, blue: 0.557)

        /// Hairline rules between rows.
        static let line = lavender.opacity(0.10)
        /// Uppercase mono labels in the left lane.
        static let label = lavender.opacity(0.62)
        /// Mono values in the right lane.
        static let value = ink.opacity(0.72)
        /// Plan tags and other tertiary meta.
        static let faint = lavender.opacity(0.45)
        /// Unfilled portion of a quota meter.
        static let track = lavender.opacity(0.14)
        /// Filled portion of a quota meter — deliberately uniform: the bar
        /// length carries the signal, not the hue.
        static let meter = lavender
        /// Header glyph buttons.
        static let glyph = lavender.opacity(0.60)
    }
}
