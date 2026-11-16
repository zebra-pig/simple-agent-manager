#!/bin/sh
# Builds and drives the actual project search UI against a local HTTP fixture.
set -eu
native_dir="$(cd "$(dirname "$0")/../.." && pwd)"
output_dir="${1:?Pass an evidence directory}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
fixture_dir=$(mktemp -d)
simulator=""
server_pid=""
bundle=org.simpleagentmanager.validation.searchg41t58
cleanup() {
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    if [ -n "$simulator" ]; then
        xcrun simctl terminate "$simulator" "$bundle" >/dev/null 2>&1 || true
        xcrun simctl uninstall "$simulator" "$bundle" >/dev/null 2>&1 || true
        xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
        xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    fi
    rm -rf "$fixture_dir"
}
trap cleanup EXIT HUP INT TERM
cp -R "$native_dir/ios" "$fixture_dir/ios"
cp "$native_dir/verification/project-search/SAMVisualFixture.swift" "$fixture_dir/ios/SAM/SAMApp.swift"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$fixture_dir/ios/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true' "$fixture_dir/ios/Info.plist"
xcodebuild -project "$fixture_dir/ios/SAM.xcodeproj" -scheme SAM \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$fixture_dir/build" \
    CODE_SIGNING_ALLOWED=NO SAM_BUNDLE_ID="$bundle" PRODUCT_BUNDLE_IDENTIFIER="$bundle" build > "$output_dir/build.log" 2>&1
selection=$(xcrun simctl list runtimes --json | python3 -c '
import json,os,sys
runtimes=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["name"].startswith("iOS")]
runtime=max(runtimes,key=lambda r:tuple(map(int,r["version"].split("."))))
family=os.environ.get("SAM_SEARCH_DEVICE_FAMILY", "iPhone")
device=next(d for d in runtime["supportedDeviceTypes"] if d["name"].startswith(family))
print(runtime["identifier"]+" "+device["identifier"])
')
simulator=$(xcrun simctl create "SAM-ProjectSearch-$$" "${selection#* }" "${selection%% *}")
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
python3 "$native_dir/verification/project-search/fixture-server.py" "$fixture_dir/port" > "$output_dir/server.log" 2>&1 &
server_pid=$!
tries=0
while [ ! -f "$fixture_dir/port" ]; do
    tries=$((tries+1))
    [ "$tries" -le 30 ] || { echo 'Fixture server timed out' >&2; exit 1; }
    sleep 1
done
xcrun simctl install "$simulator" "$fixture_dir/build/Build/Products/Debug-iphonesimulator/SAM.app"
xcrun simctl launch "$simulator" "$bundle" "--base=http://127.0.0.1:$(cat "$fixture_dir/port")"
container=$(xcrun simctl get_app_container "$simulator" "$bundle" data)
tries=0
while [ ! -f "$container/Documents/result.txt" ]; do
    tries=$((tries+1))
    [ "$tries" -le 60 ] || { echo 'Search fixture timed out' >&2; exit 1; }
    sleep 1
done
cp "$container/Documents/"*.png "$output_dir/"
cp "$container/Documents/result.txt" "$output_dir/"
cat "$output_dir/result.txt"
grep -q '^CAPTURED:' "$output_dir/result.txt"
