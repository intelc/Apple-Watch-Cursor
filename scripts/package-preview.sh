#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ -n "$(git status --porcelain)" ]]; then
    echo 'Commit changes before packaging so source and binary describe the same tree.' >&2
    exit 1
fi
version="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
release_dir="$project_dir/build/release"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/apple-watch-cursor-release.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
mkdir -p "$release_dir"

xcodebuild -project AppleWatchCursor.xcodeproj -scheme AppleWatchCursorMac \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$build_root/DerivedData" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
app_path="$build_root/DerivedData/Build/Products/Release/Apple-Watch-Cursor.app"
# Ad hoc signing satisfies local code integrity; it is not Developer ID signing.
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
lipo -verify_arch arm64 x86_64 "$app_path/Contents/MacOS/Apple-Watch-Cursor"

stage="$build_root/Apple-Watch-Cursor-$version-macOS-universal-dev"
mkdir -p "$stage"
ditto --norsrc "$app_path" "$stage/Apple-Watch-Cursor.app"
cp LICENSE "$stage/LICENSE"
cat > "$stage/READ-ME-FIRST.txt" <<'NOTES'
Apple-Watch-Cursor — experimental developer preview

This universal Mac app is ad hoc signed and NOT notarized or Developer ID signed.
Build locally with Xcode for the recommended setup path. The Watch app must be
built and installed with your own development signing; no Watch installer is included.

Setup: https://github.com/intelc/Apple-Watch-Cursor#setup
Watch dimming can interrupt movement. Start in Practice before enabling mouse input.
NOTES
if find "$stage" \( -name '*.mobileprovision' -o -name '*.provisionprofile' -o -name '*.p12' -o -name '*.pem' -o -name '*.key' \) -print -quit | read -r _; then
    echo 'Refusing to package unexpected signing material.' >&2
    exit 1
fi
mac_zip="Apple-Watch-Cursor-$version-macOS-universal-dev.zip"
source_zip="Apple-Watch-Cursor-$version-source.zip"
ditto -c -k --norsrc --keepParent "$stage" "$release_dir/$mac_zip"
git archive --format=zip --prefix="Apple-Watch-Cursor-$version/" HEAD -o "$release_dir/$source_zip"
(cd "$release_dir" && shasum -a 256 "$mac_zip" "$source_zip" > SHA256SUMS.txt)
echo "Developer preview packages: $release_dir"
