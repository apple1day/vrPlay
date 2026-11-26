#!/usr/bin/env bash
# Set SIMULATOR_UDID to use a particular available iPhone simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
project=(-project VRPlay.xcodeproj -scheme VRPlay -configuration Debug)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
build=("${project[@]}" -derivedDataPath "$work/build" -parallel-testing-enabled NO)
xcodebuild "${build[@]}" -destination 'generic/platform=iOS Simulator' build-for-testing
sim_id="${SIMULATOR_UDID:-}"
if [[ -z "$sim_id" ]]; then
    # Select a device for this Xcode's SDK from structured data; display formatting
    # and the ordering of fields in xcodebuild -showdestinations vary by Xcode.
    sim_id="$(python3 - <<'PYTHON'
import json, subprocess
def read(*args):
    return subprocess.check_output(args, text=True).strip()
sdk = read("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
catalog = json.loads(read("xcrun", "simctl", "list", "--json"))
runtimes = [r for r in catalog["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"] and
            r["version"].split(".")[0] == sdk.split(".")[0]]
for runtime in sorted(runtimes, key=lambda r: r["version"] == sdk, reverse=True):
    phones = [d for d in catalog["devices"].get(runtime["identifier"], []) if d["isAvailable"] and d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        break
else:
    if runtimes:
        runtime = runtimes[0]
        phone = next((d for d in runtime.get("supportedDeviceTypes", []) if d["name"].startswith("iPhone")), None)
        if phone:
            print(read("xcrun", "simctl", "create", "VRPlay Test iPhone", phone["identifier"], runtime["identifier"]))
PYTHON
)"
fi
if [[ -z "$sim_id" ]]; then
    xcrun simctl list runtimes
    xcrun simctl list devices available
    echo 'Install an iPhone Simulator runtime for the selected Xcode or set SIMULATOR_UDID.' >&2
    exit 1
fi
xcrun simctl bootstatus "$sim_id" -b
build+=(-destination "platform=iOS Simulator,id=$sim_id")
app="$work/build/Build/Products/Debug-iphonesimulator/VRPlay.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")"
xcrun simctl install "$sim_id" "$app"
docs="$(xcrun simctl get_app_container "$sim_id" "$bundle_id" data)/Documents"
mkdir -p "$docs"
cp Tests/Fixtures/*.mp4 "$docs/"
printf 'test fixture: invalid movie\n' > "$docs/VRPlaySmoke_Invalid.mp4"
if [[ -n "${RESULT_BUNDLE_PATH:-}" ]]; then
    build+=(-resultBundlePath "$RESULT_BUNDLE_PATH")
fi
result=0
xcodebuild "${build[@]}" test-without-building || result=$?
cat "$docs/pixel-probe.txt" || true
exit "$result"
