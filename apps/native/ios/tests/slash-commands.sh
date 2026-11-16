#!/bin/bash
# Run from a Mac after scripts/build-ios.sh. Uses production composer/editor,
# generated bindings, and an offline app entry point in an isolated copy.
set -euo pipefail
native_dir="$(cd "$(dirname "$0")/../.." && pwd)"
output_dir="${1:?Pass a screenshot output directory}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
fixture_dir=$(mktemp -d)
simulator=""
bundle=org.simpleagentmanager.validation.slash
cleanup() {
    if [ -n "$simulator" ]; then
        xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
        xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    fi
    rm -rf "$fixture_dir"
}
trap cleanup EXIT HUP INT TERM
cp -R "$native_dir/ios" "$fixture_dir/ios"
cp "${SAM_TEST_APP_SOURCE:-$native_dir/ios/tests/slash-commands-ios.swift}" "$fixture_dir/ios/SAM/SAMApp.swift"
xcodebuild -project "$fixture_dir/ios/SAM.xcodeproj" -scheme SAM \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$fixture_dir/dd" \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle" CODE_SIGNING_ALLOWED=NO build > "$output_dir/build.log" 2>&1
selection=$(xcrun simctl list runtimes --json | python3 -c '
import json,os,sys
runtimes=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["name"].startswith("iOS")]
runtime=max(runtimes,key=lambda r:tuple(map(int,r["version"].split("."))))
prefix=os.environ.get("SAM_TEST_DEVICE_PREFIX", "iPhone")
device=next(d for d in runtime["supportedDeviceTypes"] if d["name"].startswith(prefix))
print(runtime["identifier"]+" "+device["identifier"])
')
simulator=$(xcrun simctl create "SAM-Slash-$$" "${selection#* }" "${selection%% *}")
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
# Skip the system keyboard's first-run tutorial on this disposable device.
xcrun simctl spawn "$simulator" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl spawn "$simulator" defaults write com.apple.keyboard.preferences DidShowGestureKeyboardIntroduction -bool true
xcrun simctl status_bar "$simulator" override --time '9:41' --batteryState charged --batteryLevel 100
xcrun simctl install "$simulator" "$fixture_dir/dd/Build/Products/Debug-iphonesimulator/SAM.app"
container=$(xcrun simctl get_app_container "$simulator" "$bundle" data)
SIMCTL_CHILD_SAM_FIXTURE_SERVER="${SAM_TEST_SERVER:-}" SIMCTL_CHILD_SAM_SCREENSHOT_HANDSHAKE=1 xcrun simctl launch "$simulator" "$bundle"
for phase in ${SAM_TEST_PHASES:-all-light filtered-light inserted-light all-dark}; do
    tries=0
    while [ ! -f "$container/Documents/$phase.ready" ]; do
        tries=$((tries+1))
        if [ "$tries" -gt 90 ]; then echo "Timed out: $phase"; exit 1; fi
        sleep 1
    done
    xcrun simctl io "$simulator" screenshot "$output_dir/$phase.png"
    touch "$container/Documents/$phase.done"
done
tries=0
while [ ! -f "$container/Documents/result.txt" ]; do
    tries=$((tries+1))
    if [ "$tries" -gt 30 ]; then echo 'Behavior checks timed out'; exit 1; fi
    sleep 1
done
cp "$container/Documents/result.txt" "$output_dir/result.txt"
cat "$output_dir/result.txt"
grep -q '^PASS:' "$output_dir/result.txt"
