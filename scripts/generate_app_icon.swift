#!/usr/bin/env swift

import Foundation

let fileManager = FileManager.default
let repository = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconDocument = repository.appendingPathComponent("AIUsage/AppIcon.icon")
let outputDirectory = repository.appendingPathComponent("docs/images")
let iconTool = URL(
    fileURLWithPath:
        "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/" +
        "Contents/Executables/ictool"
)

guard fileManager.fileExists(atPath: iconTool.path) else {
    fputs("Icon Composer is required. Install Xcode 27 or newer.\n", stderr)
    exit(1)
}

try fileManager.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for (rendition, filename) in [
    ("Default", "app-icon-light.png"),
    ("Dark", "app-icon-dark.png")
] {
    let process = Process()
    process.executableURL = iconTool
    process.arguments = [
        iconDocument.path,
        "--export-image",
        "--output-file",
        outputDirectory.appendingPathComponent(filename).path,
        "--platform", "macOS",
        "--rendition", rendition,
        "--width", "512",
        "--height", "512",
        "--scale", "1",
        "--design-generation", "27"
    ]

    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fputs("Could not export \(rendition) app icon.\n", stderr)
        exit(process.terminationStatus)
    }
}

print("Exported adaptive app icon previews to docs/images.")
