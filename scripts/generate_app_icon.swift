#!/usr/bin/env swift

import AppKit

private let outputDirectory = URL(fileURLWithPath:
    FileManager.default.currentDirectoryPath
).appendingPathComponent("AIUsage/Assets.xcassets/AppIcon.appiconset")

private func point(center: NSPoint, radius: CGFloat, degrees: CGFloat) -> NSPoint {
    let radians = degrees * .pi / 180
    return NSPoint(
        x: center.x + cos(radians) * radius,
        y: center.y + sin(radians) * radius
    )
}

private func makeIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: size, height: size)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(size)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: scale, height: scale).fill()

    let tile = NSRect(
        x: scale * 0.08,
        y: scale * 0.08,
        width: scale * 0.84,
        height: scale * 0.84
    )
    let tilePath = NSBezierPath(
        roundedRect: tile,
        xRadius: scale * 0.19,
        yRadius: scale * 0.19
    )

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = scale * 0.055
    shadow.shadowOffset = NSSize(width: 0, height: -scale * 0.025)
    shadow.set()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.08, green: 0.13, blue: 0.29, alpha: 1),
        NSColor(red: 0.25, green: 0.20, blue: 0.77, alpha: 1),
        NSColor(red: 0.18, green: 0.51, blue: 0.93, alpha: 1)
    ])!
    gradient.draw(in: tilePath, angle: 55)

    NSGraphicsContext.current?.saveGraphicsState()
    tilePath.addClip()
    let glowRect = NSRect(
        x: scale * 0.18,
        y: scale * 0.48,
        width: scale * 0.68,
        height: scale * 0.42
    )
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.26),
        NSColor.white.withAlphaComponent(0)
    ])!.draw(in: glowRect, relativeCenterPosition: NSPoint(x: 0, y: 0.45))
    NSGraphicsContext.current?.restoreGraphicsState()

    let glass = NSBezierPath(
        roundedRect: tile.insetBy(dx: scale * 0.095, dy: scale * 0.095),
        xRadius: scale * 0.14,
        yRadius: scale * 0.14
    )
    NSColor.white.withAlphaComponent(0.085).setFill()
    glass.fill()
    NSColor.white.withAlphaComponent(0.24).setStroke()
    glass.lineWidth = max(1, scale * 0.006)
    glass.stroke()

    let center = NSPoint(x: scale * 0.5, y: scale * 0.44)
    let radius = scale * 0.245
    let arc = NSBezierPath()
    arc.appendArc(
        withCenter: center,
        radius: radius,
        startAngle: 205,
        endAngle: -25,
        clockwise: true
    )
    arc.lineWidth = scale * 0.047
    arc.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.94).setStroke()
    arc.stroke()

    for angle: CGFloat in [205, 147.5, 90, 32.5, -25] {
        let tick = point(center: center, radius: radius, degrees: angle)
        let dotSize = scale * 0.034
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: tick.x - dotSize / 2,
                y: tick.y - dotSize / 2,
                width: dotSize,
                height: dotSize
            )
        ).fill()
    }

    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: point(
        center: center,
        radius: scale * 0.185,
        degrees: 42
    ))
    needle.lineWidth = scale * 0.047
    needle.lineCapStyle = .round
    NSColor(
        red: 0.49,
        green: 0.97,
        blue: 0.93,
        alpha: 1
    ).setStroke()
    needle.stroke()

    let hubSize = scale * 0.085
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - hubSize / 2,
        y: center.y - hubSize / 2,
        width: hubSize,
        height: hubSize
    )).fill()
    NSColor(
        red: 0.18,
        green: 0.22,
        blue: 0.54,
        alpha: 1
    ).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - hubSize * 0.23,
        y: center.y - hubSize * 0.23,
        width: hubSize * 0.46,
        height: hubSize * 0.46
    )).fill()

    context.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let data = try makeIcon(size: size)
    try data.write(
        to: outputDirectory.appendingPathComponent("icon_\(size).png"),
        options: .atomic
    )
}
