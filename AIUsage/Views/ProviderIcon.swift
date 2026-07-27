import AppKit
import SwiftUI

struct ProviderIcon: View {
    let provider: ProviderID
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: Self.templateImage(for: provider, size: size))
            .renderingMode(.template)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func templateImage(for provider: ProviderID, size: CGFloat) -> NSImage {
        guard let source = NSImage(named: provider.iconAssetName),
              let image = source.copy() as? NSImage else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
