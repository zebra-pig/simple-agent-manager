#!/bin/sh
# Builds the real New project sheet with a scripted model boundary, then checks
# initial completion and repository refresh on an isolated iOS simulator.
set -eu
native_dir="$(cd "$(dirname "$0")/../.." && pwd)"
output_dir="${1:?Pass an evidence output directory}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
fixture_dir=$(mktemp -d)
bundle=org.simpleagentmanager.validation.loadingsheet
simulator="${SAM_TEST_SIMULATOR_UDID:-}"
owned_simulator=false
cleanup() {
    if [ -n "$simulator" ]; then
        xcrun simctl terminate "$simulator" "$bundle" >/dev/null 2>&1 || true
        xcrun simctl uninstall "$simulator" "$bundle" >/dev/null 2>&1 || true
        if [ "$owned_simulator" = true ]; then
            xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
            xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$fixture_dir"
}
trap cleanup EXIT HUP INT TERM
if [ -z "$simulator" ]; then
    selection=$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
runtimes=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["name"].startswith("iOS")]
if not runtimes: raise SystemExit("Project loading regression requires an available iOS simulator runtime")
runtime=max(runtimes,key=lambda r:tuple(map(int,r["version"].split("."))))
phone=next(d for d in runtime["supportedDeviceTypes"] if d["name"].startswith("iPhone"))
print(runtime["identifier"]+" "+phone["identifier"])
')
    runtime=${selection%% *}
    device_type=${selection#* }
    simulator=$(xcrun simctl create "SAM-LoadingSheet-$$" "$device_type" "$runtime")
    owned_simulator=true
    xcrun simctl boot "$simulator"
fi
xcrun simctl bootstatus "$simulator" -b
app_dir="$fixture_dir/LoadingSheet.app"
mkdir -p "$app_dir"
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -parse-as-library -sdk "$sdk" \
    -target "$(uname -m)-apple-ios17.0-simulator" \
    "$native_dir/ios/SAM/Platform.swift" \
    "$native_dir/ios/SAM/Loading.swift" \
    "$native_dir/ios/SAM/ErrorMessagesKey.swift" \
    "$native_dir/ios/SAM/FloatingErrorBadge.swift" \
    "$native_dir/ios/SAM/FloatingErrors.swift" \
    "${SAM_TEST_PROJECT_SETTINGS_SOURCE:-$native_dir/ios/SAM/ProjectSettings.swift}" \
    "$native_dir/ios/tests/project-loading-ios.swift" \
    -o "$app_dir/LoadingSheet"
cat > "$app_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LoadingSheet</string>
<key>CFBundleIdentifier</key><string>$bundle</string>
<key>CFBundleName</key><string>LoadingSheet</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
xcrun simctl install "$simulator" "$app_dir"
container=$(xcrun simctl get_app_container "$simulator" "$bundle" data)
rm -f "$container/Documents/result.txt"
xcrun simctl launch "$simulator" "$bundle"
tries=0
while [ ! -f "$container/Documents/result.txt" ]; do
    tries=$((tries+1))
    if [ "$tries" -gt 90 ]; then echo 'Project loading regression timed out' >&2; exit 1; fi
    sleep 1
done
cp "$container/Documents/"*.png "$output_dir/"
cp "$container/Documents/result.txt" "$output_dir/"
cat "$output_dir/result.txt"
printf '\n'
grep -q '^PASS:' "$output_dir/result.txt"
echo PROJECT_LOADING_SHEET_PASS
