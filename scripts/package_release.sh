#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s <version>\n' "$0" >&2
    exit 1
fi

version="${1#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Version must use SemVer, for example 0.1.0.\n' >&2
    exit 1
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(dirname "$script_directory")"
project_path="$repository_directory/AIUsage.xcodeproj"
derived_data_directory="$repository_directory/DerivedData-Release"
artifact_directory="$repository_directory/dist/v$version"
release_notes="$repository_directory/docs/releases/$version.md"
built_application="$derived_data_directory/Build/Products/Release/AI Usage.app"
application_binary="$built_application/Contents/MacOS/AI Usage"
disk_image="$artifact_directory/AI-Usage.dmg"
checksum="$artifact_directory/AI-Usage.dmg.sha256"
sparkle_account="ai-usage-menubar"

if [[ ! -f "$release_notes" ]]; then
    printf 'Missing release notes: %s\n' "$release_notes" >&2
    exit 1
fi

xcode_major="$(
    xcodebuild -version |
        awk 'NR == 1 { split($2, parts, "."); print parts[1] }'
)"
if [[ -z "$xcode_major" || "$xcode_major" -lt 27 ]]; then
    printf 'AI Usage releases require Xcode 27 or newer.\n' >&2
    exit 1
fi

configured_version="$(
    xcodebuild \
        -project "$project_path" \
        -scheme AIUsage \
        -configuration Release \
        -showBuildSettings |
        awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }'
)"
if [[ "$configured_version" != "$version" ]]; then
    printf \
        'Project version is %s, but the requested release is %s.\n' \
        "$configured_version" \
        "$version" >&2
    exit 1
fi

codesign_identity="${AI_USAGE_CODESIGN_IDENTITY:-}"
if [[ -z "$codesign_identity" ]]; then
    codesign_identity="$(
        security find-identity -v -p codesigning 2>/dev/null |
            awk '/Developer ID Application:/ { print $2; exit }'
    )"
fi

build_settings=()
if [[ -n "$codesign_identity" ]]; then
    printf 'Building a universal Developer ID signed app…\n'
    build_settings+=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=$codesign_identity"
    )
else
    printf 'Building a universal ad-hoc signed app…\n'
    printf \
        'Warning: no Developer ID Application identity was found; this build cannot be notarized.\n' \
        >&2
    build_settings+=("CODE_SIGN_STYLE=Automatic")
fi

xcodebuild \
    -quiet \
    -project "$project_path" \
    -scheme AIUsage \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data_directory" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    "${build_settings[@]}" \
    clean build

if [[ ! -d "$built_application" ]]; then
    printf 'Release app was not produced at %s\n' "$built_application" >&2
    exit 1
fi

/usr/bin/lipo -verify_arch arm64 "$application_binary"
/usr/bin/lipo -verify_arch x86_64 "$application_binary"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$built_application"

embedded_version="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "$built_application/Contents/Info.plist"
)"
if [[ "$embedded_version" != "$version" ]]; then
    printf 'Built app version is %s, expected %s.\n' "$embedded_version" "$version" >&2
    exit 1
fi

feed_url="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :SUFeedURL' \
        "$built_application/Contents/Info.plist"
)"
expected_feed_url="https://raw.githubusercontent.com/burakgon/ai-usage-menubar/main/appcast.xml"
if [[ "$feed_url" != "$expected_feed_url" ]]; then
    printf 'Unexpected Sparkle feed URL: %s\n' "$feed_url" >&2
    exit 1
fi

sparkle_directory="$derived_data_directory/SourcePackages/artifacts/sparkle/Sparkle"
sparkle_license="$derived_data_directory/SourcePackages/checkouts/Sparkle/LICENSE"
generate_appcast="$sparkle_directory/bin/generate_appcast"
generate_keys="$sparkle_directory/bin/generate_keys"
sign_update="$sparkle_directory/bin/sign_update"
if [[
    ! -x "$generate_appcast" ||
        ! -x "$generate_keys" ||
        ! -x "$sign_update" ||
        ! -f "$sparkle_license"
]]; then
    printf 'Sparkle release tools were not resolved by Xcode.\n' >&2
    exit 1
fi

embedded_public_key="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :SUPublicEDKey' \
        "$built_application/Contents/Info.plist"
)"
keychain_public_key="$("$generate_keys" --account "$sparkle_account" -p)"
if [[ "$embedded_public_key" != "$keychain_public_key" ]]; then
    printf 'The app public key does not match the Sparkle key in Keychain.\n' >&2
    exit 1
fi

mkdir -p "$artifact_directory"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/ai-usage-release.XXXXXX")"
cleanup() {
    rm -rf "$temporary_directory"
}
trap cleanup EXIT

disk_image_source="$temporary_directory/disk-image"
updates_directory="$temporary_directory/updates"
licenses_directory="$disk_image_source/Licenses"
mkdir -p "$licenses_directory" "$updates_directory"

/usr/bin/ditto "$built_application" "$disk_image_source/AI Usage.app"
/usr/bin/ditto "$repository_directory/LICENSE" "$licenses_directory/AI Usage.txt"
/usr/bin/ditto \
    "$repository_directory/NOTICE" \
    "$licenses_directory/Third-Party Notices.txt"
/usr/bin/ditto "$sparkle_license" "$licenses_directory/Sparkle.txt"
/bin/ln -s /Applications "$disk_image_source/Applications"

printf 'Creating DMG…\n'
/usr/bin/hdiutil create \
    -quiet \
    -volname "AI Usage" \
    -srcfolder "$disk_image_source" \
    -format UDZO \
    -ov \
    "$disk_image"
/usr/bin/hdiutil verify -quiet "$disk_image"

if [[ -n "$codesign_identity" ]]; then
    /usr/bin/codesign \
        --force \
        --sign "$codesign_identity" \
        --timestamp \
        "$disk_image"
fi

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    if [[ -z "$codesign_identity" ]]; then
        printf 'NOTARYTOOL_PROFILE requires a Developer ID signed build.\n' >&2
        exit 1
    fi
    printf 'Submitting DMG for notarization…\n'
    xcrun notarytool submit \
        "$disk_image" \
        --keychain-profile "$NOTARYTOOL_PROFILE" \
        --wait
    xcrun stapler staple "$disk_image"
    xcrun stapler validate "$disk_image"
fi

/usr/bin/shasum -a 256 "$disk_image" |
    awk '{ print $1 "  AI-Usage.dmg" }' > "$checksum"

/usr/bin/ditto "$disk_image" "$updates_directory/AI-Usage.dmg"
/usr/bin/ditto "$release_notes" "$updates_directory/AI-Usage.md"
if [[ -f "$repository_directory/appcast.xml" ]]; then
    /usr/bin/ditto \
        "$repository_directory/appcast.xml" \
        "$updates_directory/appcast.xml"
fi

printf 'Generating signed Sparkle appcast…\n'
"$generate_appcast" \
    --account "$sparkle_account" \
    --download-url-prefix \
    "https://github.com/burakgon/ai-usage-menubar/releases/download/v$version/" \
    --embed-release-notes \
    --link "https://github.com/burakgon/ai-usage-menubar" \
    --maximum-versions 5 \
    --maximum-deltas 0 \
    "$updates_directory"

/usr/bin/xmllint --noout "$updates_directory/appcast.xml"
"$sign_update" \
    --account "$sparkle_account" \
    --verify \
    "$updates_directory/appcast.xml"
/usr/bin/ditto \
    "$updates_directory/appcast.xml" \
    "$repository_directory/appcast.xml"

printf '\nRelease package is ready:\n'
printf '  App: %s\n' "$built_application"
printf '  DMG: %s\n' "$disk_image"
printf '  SHA-256: %s\n' "$checksum"
printf '  Appcast: %s\n' "$repository_directory/appcast.xml"

if [[ -z "$codesign_identity" ]]; then
    printf '\nNotarization: skipped (no Developer ID Application identity)\n'
elif [[ -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    printf '\nNotarization: skipped (NOTARYTOOL_PROFILE is not set)\n'
else
    printf '\nNotarization: complete\n'
fi
