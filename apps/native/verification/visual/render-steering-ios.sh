#!/bin/bash
# Run on the Tailscale Mac from the repository root. Uses an isolated simulator.
set -euo pipefail
root=$(pwd)
native="$root/apps/native"
build="$root/steering-simulator"
mkdir -p "$build/SteeringReview.app" "$build/screenshots"
generated="$native/ios/Generated"
sim=$(xcrun simctl create SAM-Steering-Review com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
server_pid=""
cleanup() {
    [ -z "$server_pid" ] || kill "$server_pid" || true
    xcrun simctl shutdown "$sim" || true
    xcrun simctl delete "$sim" || true
}
trap cleanup EXIT
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b
sources=()
for source in "$native/ios/SAM/"*.swift; do
    [[ "$source" == */SAMApp.swift ]] || sources+=("$source")
done
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -I "$generated/SamCore.xcframework/ios-arm64-simulator/Headers" \
    "$generated/SamCore.swift" "${sources[@]}" "$native/verification/visual/steering-ios.swift" \
    -L "$generated/SamCore.xcframework/ios-arm64-simulator" -lsam_core \
    -framework Security -framework SystemConfiguration -o "$build/SteeringReview.app/SteeringReview"
cat > "$build/SteeringReview.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.sam.steering.review</string>
<key>CFBundleName</key><string>SAM</string>
<key>CFBundleExecutable</key><string>SteeringReview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>UILaunchScreen</key><dict/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$build/SteeringReview.app"
xcrun simctl install "$sim" "$build/SteeringReview.app"
echo steer > /tmp/sam-steering-mode
python3 "$native/verification/visual/steering-server.py" > "$build/server.log" 2>&1 &
server_pid=$!
xcrun simctl status_bar "$sim" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
for mode in steer queue draft interrupting error unsupported; do
    echo "$mode" > /tmp/sam-steering-mode
    xcrun simctl terminate "$sim" dev.sam.steering.review 2>/dev/null || true
    xcrun simctl launch "$sim" dev.sam.steering.review "$mode"
    sleep 5
    xcrun simctl io "$sim" screenshot "$build/screenshots/$mode.png"
done
