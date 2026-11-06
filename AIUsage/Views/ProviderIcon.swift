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

    private struct CacheKey: Hashable {
        let provider: ProviderID
        let sizeTenths: Int
    }

    @MainActor
    private static var sourceImages: [ProviderID: NSImage] = [:]
    @MainActor
    private static var contentBounds: [ProviderID: NSRect] = [:]
    @MainActor
    private static var cachedTemplateImages: [CacheKey: NSImage] = [:]

    /// Standard optical scale relative to the frame size. 104/128 (~81.25%)
    /// matches the visual weight of the existing provider icons.
    private static let standardOpticalRatio: CGFloat = 104.0 / 128.0

    @MainActor
    static func templateImage(for provider: ProviderID, size: CGFloat) -> NSImage {
        let key = CacheKey(provider: provider, sizeTenths: Int(round(size * 10)))
        if let cached = cachedTemplateImages[key] {
            return cached
        }

        let source = loadSourceImage(for: provider)
        let bounds = contentBounds(for: provider, source: source)

        let targetSize = NSSize(width: size, height: size)
        let targetMax = size * standardOpticalRatio

        let rendered: NSImage
        if let source, let bounds, bounds.width > 0, bounds.height > 0 {
            let maxDimension = max(bounds.width, bounds.height)
            let scale = targetMax / maxDimension
            let drawWidth = bounds.width * scale
            let drawHeight = bounds.height * scale
            let drawX = (size - drawWidth) / 2.0
            let drawY = (size - drawHeight) / 2.0
            let destRect = NSRect(
                x: drawX,
                y: drawY,
                width: drawWidth,
                height: drawHeight
            )

            rendered = NSImage(size: targetSize, flipped: false) { _ in
                source.draw(
                    in: destRect,
                    from: bounds,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                return true
            }
        } else if let source {
            rendered = NSImage(size: targetSize, flipped: false) { rect in
                source.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0
                )
                return true
            }
        } else {
            rendered = NSImage(size: targetSize)
        }

        rendered.isTemplate = true
        cachedTemplateImages[key] = rendered
        return rendered
    }

    @MainActor
    private static func loadSourceImage(for provider: ProviderID) -> NSImage? {
        if let cached = sourceImages[provider] {
            return cached
        }
        guard let source = NSImage(named: provider.iconAssetName) else {
            return nil
        }
        sourceImages[provider] = source
        return source
    }

    @MainActor
    private static func contentBounds(
        for provider: ProviderID,
        source: NSImage?
    ) -> NSRect? {
        if let cached = contentBounds[provider] {
            return cached
        }
        guard let source,
              let cgImage = source.cgImage(
                  forProposedRect: nil,
                  context: nil,
                  hints: nil
              ) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var rawData = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                if rawData[rowOffset + x * 4 + 3] > 10 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard minX <= maxX, minY <= maxY else { return nil }
        // CGContext uses a bottom-left origin, matching NSImage coordinates.
        let rect = NSRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1)
        )
        contentBounds[provider] = rect
        return rect
    }
}
