#!/usr/bin/env bash
# Set SIMULATOR_UDID to use a particular available iPhone simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
project=(-project VRPlay.xcodeproj -scheme VRPlay -configuration Debug)
sim_id="${SIMULATOR_UDID:-}"
if [[ -z "$sim_id" ]]; then
    destinations="$(xcodebuild "${project[@]}" -showdestinations)"
    sim_id="$(sed -nE '/platform:iOS Simulator.*name:iPhone/ s/.*id:([[:xdigit:]-]{36}),.*/\1/p' <<< "$destinations" | sed -n '1p')"
fi
if [[ -z "$sim_id" ]]; then
    echo 'An available iPhone simulator is required. Check xcodebuild -showdestinations.' >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun simctl bootstatus "$sim_id" -b
build=("${project[@]}" -destination "platform=iOS Simulator,id=$sim_id" -derivedDataPath "$work/build" -parallel-testing-enabled NO)
xcodebuild "${build[@]}" build-for-testing
app="$work/build/Build/Products/Debug-iphonesimulator/VRPlay.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl install "$sim_id" "$app"
docs="$(xcrun simctl get_app_container "$sim_id" "$bundle_id" data)/Documents"
mkdir -p "$docs"
cp Tests/Fixtures/VRPlaySmoke_360_LR.mp4 "$docs/"
printf 'test fixture: invalid movie\n' > "$docs/VRPlaySmoke_Invalid.mp4"
if [[ -n "${RESULT_BUNDLE_PATH:-}" ]]; then
    build+=(-resultBundlePath "$RESULT_BUNDLE_PATH")
fi
xcodebuild "${build[@]}" test-without-building
