#!/bin/bash
# run-ui.sh SUITE OUTPUT_DIR (SUITE contains App.swift and *Tests.swift)
set -euo pipefail
support=$(cd "$(dirname "$0")" && pwd)
ios=$(cd "$support/../.." && pwd)
suite=$(cd "${1:?Pass a suite directory}" && pwd)
mkdir -p "${2:?Pass an empty output directory}"
output=$(cd "$2" && pwd)
# xcodebuild refuses an existing result bundle; also refuse stale fixture receipts.
if [ -e "$output/results.xcresult" ] || [ -e "$output/project" ]; then
    echo "Use a fresh output directory: $output" >&2; exit 1
fi
simulator=
server_pid=
cleanup() {
    result=$?
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    if [ -n "$simulator" ]; then
        xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
        xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    fi
    if [ -d "$output/results.xcresult" ]; then
        xcrun xcresulttool get test-results summary --path "$output/results.xcresult" > "$output/summary.json" || true
    fi
    exit "$result"
}
trap cleanup EXIT
# Reserve a loopback endpoint in the fixture process; it reports its own bound port.
if [ -f "$suite/server.py" ]; then
    python3 "$suite/server.py" --serve 0 "$output/port" > "$output/server.log" 2>&1 &
    server_pid=$!
    for attempt in $(seq 1 100); do
        if ! kill -0 "$server_pid" 2>/dev/null; then cat "$output/server.log" >&2; exit 1; fi
        [ ! -s "$output/port" ] || break
        sleep 0.1
    done
    test -s "$output/port"
    port=$(cat "$output/port")
    # Test source copies receive the bound URL. No patching of runner scripts or production code.
    mkdir -p "$output/sources"
    for source in "$suite/"*.swift; do
        sed "s/127.0.0.1:SAM_TEST_PORT/127.0.0.1:$port/g" "$source" > "$output/sources/$(basename "$source")"
    done
    suite="$output/sources"
fi
ruby "$support/make-project.rb" ui "$ios" "$output/project" "$suite/App.swift" "$suite/"*Tests.swift
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' \
    -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$output/project/ios/Info.plist"
selection=$(xcrun simctl list runtimes --json | python3 -c '
import json,os,sys
runtimes=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["name"].startswith("iOS")]
if not runtimes: raise SystemExit("An installed iOS simulator runtime is required")
runtime=max(runtimes,key=lambda r:tuple(map(int,r["version"].split("."))))
prefix=os.environ.get("SAM_TEST_DEVICE_PREFIX", "iPhone")
device=next(d for d in runtime["supportedDeviceTypes"] if d["name"].startswith(prefix))
print(runtime["identifier"]+" "+device["identifier"])
')
simulator=$(xcrun simctl create "SAMNativeTests-$$" "${selection#* }" "${selection%% *}")
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b > "$output/boot.log" 2>&1
xcrun simctl spawn "$simulator" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true
xcrun simctl spawn "$simulator" defaults write com.apple.keyboard.preferences DidShowGestureKeyboardIntroduction -bool true
bundle="org.simpleagentmanager.validation.$(basename "$(cd "$1" && pwd)")"
xcodebuild test -project "$output/project/ios/SAM.xcodeproj" -scheme NativeTests \
    -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$output/build" \
    -resultBundlePath "$output/results.xcresult" -parallel-testing-enabled NO \
    -collect-test-diagnostics never -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 180 \
    CODE_SIGNING_ALLOWED=NO SAM_BUNDLE_ID="$bundle" \
    | tee "$output/xcodebuild.log"

python3 "$support/check-result.py" "$output/results.xcresult"
