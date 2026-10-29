#!/bin/bash
set -euo pipefail

# Device-development archives are private artifacts, not public release assets.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
team_id="${1:?Usage: bash scripts/build-signed.sh APPLE_TEAM_ID}"
artifact_dir="$project_dir/build/artifacts"
mkdir -p "$artifact_dir"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/apple-watch-cursor-signed.XXXXXX")"

for target in Mac Watch; do
    if [[ "$target" == "Mac" ]]; then
        destination='platform=macOS'
        product='Debug/Apple-Watch-Cursor.app'
    else
        destination='generic/platform=watchOS'
        product='Debug-watchos/AppleWatchCursorWatch.app'
    fi
    derived_dir="$build_root/$target"
    xcodebuild -project "$project_dir/AppleWatchCursor.xcodeproj" -scheme "AppleWatchCursor$target" \
        -destination "$destination" -derivedDataPath "$derived_dir" \
        DEVELOPMENT_TEAM="$team_id" -allowProvisioningUpdates build
    app_path="$derived_dir/Build/Products/$product"
    codesign --verify --deep --strict "$app_path"
    ditto -c -k --norsrc --keepParent "$app_path" "$artifact_dir/Apple-Watch-Cursor-$target-private.zip"
    echo "Signed app: $app_path"
done
