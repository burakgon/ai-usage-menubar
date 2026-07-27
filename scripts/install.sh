#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(dirname "$script_directory")"
derived_data_directory="$repository_directory/DerivedData-Install"
install_directory="${AI_USAGE_INSTALL_DIR:-${HOME}/Applications}"
built_application="$derived_data_directory/Build/Products/Release/AI Usage.app"
installed_application="$install_directory/AI Usage.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
    printf 'AI Usage requires Xcode 27 or newer.\n' >&2
    exit 1
fi

printf 'Building AI Usage…\n'
xcodebuild \
    -quiet \
    -project "$repository_directory/AIUsage.xcodeproj" \
    -scheme AIUsage \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_directory" \
    ENABLE_HARDENED_RUNTIME=NO \
    build

mkdir -p "$install_directory"
/usr/bin/ditto "$built_application" "$installed_application"

if [[ "${AI_USAGE_SKIP_OPEN:-0}" != "1" ]]; then
    open "$installed_application"
fi

printf 'Installed AI Usage at %s\n' "$installed_application"
