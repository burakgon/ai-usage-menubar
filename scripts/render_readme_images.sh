#!/bin/bash
# Renders the README images and the social preview from the app's real views.
#
# Each scene opens on screen for a few seconds, and only its own windows are
# composited into the image, so Liquid Glass renders exactly as it does in the
# app and nothing else on screen can appear in it. The terminal running this
# script needs Screen Recording permission. Keep the screen awake while the
# scenes render.
#
# Scenes are saved as WebP, which needs cwebp (`brew install webp`).
#
# Usage: ./scripts/render_readme_images.sh [output-directory]
# Set AIUSAGE_SHOWCASE_ONLY=hero-dark,hero-light to render only some scenes.
set -euo pipefail

if ! command -v cwebp >/dev/null; then
    printf 'cwebp is required to save the scenes. Install it with: brew install webp\n' >&2
    exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/docs/images}"
work="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-showcase.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$output"

/usr/bin/swiftc -O "$root/scripts/capture_windows.swift" -o "$work/capture_windows"

TEST_RUNNER_AIUSAGE_SHOWCASE_DIR="$work" \
TEST_RUNNER_AIUSAGE_SHOWCASE_ONLY="${AIUSAGE_SHOWCASE_ONLY:-}" \
    xcodebuild test \
    -project "$root/AIUsage.xcodeproj" \
    -scheme AIUsage \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:AIUsageTests/ReadmeShowcaseTests \
    -testLanguage en \
    -testRegion US \
    >"$work/xcodebuild.log" 2>&1 &
test_pid=$!

while kill -0 "$test_pid" 2>/dev/null; do
    for ready in "$work"/*.ready; do
        [[ -e "$ready" ]] || continue
        name="$(basename "$ready" .ready)"
        { read -r rect; read -r -a windows; } <"$ready"
        rm -f "$ready"
        "$work/capture_windows" "$output/$name.png" "$rect" "${windows[@]}"
        touch "$work/$name.done"
        printf 'Captured %s\n' "$name"
    done
    sleep 0.2
done

if ! wait "$test_pid"; then
    tail -n 40 "$work/xcodebuild.log" >&2
    exit 1
fi

for image in "$work"/*.png; do
    [[ -e "$image" ]] || continue
    mv "$image" "$output/"
    printf 'Rendered %s\n' "$(basename "$image" .png)"
done

# Round the scene corners so each image sits on the page like a window.
round_corners() {
    /usr/bin/swift - "$@" <<'SWIFT'
import AppKit

let radius: CGFloat = 28
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else {
        FileHandle.standardError.write(Data("Could not read \(path)\n".utf8))
        exit(1)
    }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.addPath(CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    ))
    context.clip()
    context.draw(image, in: rect)
    guard let rounded = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              "public.png" as CFString,
              1,
              nil
          ) else {
        exit(1)
    }
    CGImageDestinationAddImage(destination, rounded, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}
SWIFT
}

scenes=()
for scene in hero providers menubar settings; do
    for look in dark light; do
        [[ -f "$output/$scene-$look.png" && -e "$work/$scene-$look.done" ]] &&
            scenes+=("$output/$scene-$look.png")
    done
done
if (( ${#scenes[@]} > 0 )); then
    round_corners "${scenes[@]}"
    # Lossy WebP at this quality is indistinguishable from the PNG at a tenth
    # of the size, so the README opens quickly.
    for scene in "${scenes[@]}"; do
        cwebp -quiet -q 92 -alpha_q 100 -sharp_yuv -m 6 "$scene" -o "${scene%.png}.webp"
        rm "$scene"
    done
fi

# GitHub wants a 1280x640 social preview under 1 MB.
if [[ -f "$output/social-preview.png" && -e "$work/social-preview.done" ]]; then
    /usr/bin/sips -z 640 1280 -s format jpeg -s formatOptions 90 \
        "$output/social-preview.png" --out "$output/social-preview.jpg" >/dev/null
    rm "$output/social-preview.png"
fi

if [[ -f "$work/showcase.log" ]]; then
    cat "$work/showcase.log"
fi
