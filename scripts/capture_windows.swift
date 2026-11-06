// Composites the given windows, front to back, into one PNG. Only the listed
// windows are drawn, so nothing else on screen can end up in the image.
//
// Usage: capture_windows <output.png> <x,y,width,height> <window-id>...
// The rectangle uses screen points with the origin at the top left.
import CoreGraphics
import Foundation
import ImageIO

typealias CreateImageFromArray = @convention(c) (
    CGRect,
    CFArray,
    UInt32
) -> Unmanaged<CGImage>?

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("capture_windows: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    fail("usage: capture_windows <output.png> <x,y,width,height> <window-id>...")
}

let values = arguments[2].split(separator: ",").compactMap { Double($0) }
guard values.count == 4 else { fail("invalid rectangle \(arguments[2])") }
let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])

var windows: [UnsafeRawPointer?] = arguments.dropFirst(3).map {
    guard let id = UInt($0) else { fail("invalid window id \($0)") }
    return UnsafeRawPointer(bitPattern: id)
}
guard let windowArray = CFArrayCreate(nil, &windows, windows.count, nil) else {
    fail("could not list the windows")
}

// The replacement, ScreenCaptureKit, can't composite an exact set of windows
// from a script, so look the function up at run time.
let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
guard let symbol = dlsym(defaultHandle, "CGWindowListCreateImageFromArray") else {
    fail("CGWindowListCreateImageFromArray is unavailable")
}
let createImage = unsafeBitCast(symbol, to: CreateImageFromArray.self)
let bestResolution: UInt32 = 1 << 3
guard let image = createImage(rect, windowArray, bestResolution)?.takeRetainedValue() else {
    fail("the windows could not be captured; check Screen Recording permission")
}

let output = URL(fileURLWithPath: arguments[1])
guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    "public.png" as CFString,
    1,
    nil
) else {
    fail("could not write \(output.path)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("could not write \(output.path)")
}
