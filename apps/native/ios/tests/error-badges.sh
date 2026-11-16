#!/bin/bash
# Run from the repository root on a Mac with the iOS 27 simulator runtime.
set -euo pipefail
root=$(pwd)
build=$(mktemp -d /tmp/sam-error-badges.XXXXXX)
sim=$(xcrun simctl create SAM-Error-Badges com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
cleanup() {
    xcrun simctl shutdown "$sim" || true
    xcrun simctl delete "$sim" || true
}
trap cleanup EXIT
mkdir -p "$build/BadgeReview.app" "$build/screenshots"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    "$root/apps/native/ios/SAM/"{ErrorMessagesKey,ErrorNotice,FloatingErrorBadge,FloatingErrors}.swift \
    "$root/apps/native/ios/tests/error-badges.swift" -o "$build/BadgeReview.app/BadgeReview"
cat > "$build/BadgeReview.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.sam.badges.review</string>
<key>CFBundleExecutable</key><string>BadgeReview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$build/BadgeReview.app"
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b
xcrun simctl install "$sim" "$build/BadgeReview.app"
for mode in nested sheet; do
    xcrun simctl terminate "$sim" dev.sam.badges.review 2>/dev/null || true
    xcrun simctl launch "$sim" dev.sam.badges.review "$mode"
    sleep 4
    xcrun simctl io "$sim" screenshot "$build/screenshots/$mode.png"
done
printf 'Evidence: %s/screenshots\n' "$build"
