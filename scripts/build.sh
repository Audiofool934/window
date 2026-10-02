#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Builds dist/Window.app. SIGNING_IDENTITY picks a certificate; the default signs ad hoc,
# which works locally but makes macOS ask again for permissions after each rebuild.
configuration="${CONFIGURATION:-release}"
app_dir="${APP_DIR:-dist/Window.app}"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
cp "$bin_dir/Window" "$app_dir/Contents/MacOS/Window"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
# The shader is compiled at launch, so no Metal toolchain is needed to build.
cp Sources/WindowCore/Shaders/Room.metal "$app_dir/Contents/Resources/Room.metal"
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/window-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
swift scripts/icon.swift "$icon_work/Window.iconset"
iconutil -c icns "$icon_work/Window.iconset" -o "$app_dir/Contents/Resources/Window.icns"
sign_options=(--force --sign "${SIGNING_IDENTITY:--}" --options runtime --entitlements Resources/Window.entitlements)
if [[ "${SIGNING_IDENTITY:--}" != "-" ]]; then sign_options+=(--timestamp); fi
codesign "${sign_options[@]}" "$app_dir"
codesign --verify --strict "$app_dir"
echo "Built $app_dir"
