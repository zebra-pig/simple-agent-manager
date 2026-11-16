#!/bin/bash
# Requires current generated Swift bindings/XCFramework and an installed iOS runtime.
# Builds an isolated app copy; never signs in or contacts a backend.
set -euo pipefail
native_dir=$(cd "$(dirname "$0")/../.." && pwd)
output_dir=${1:?Pass an evidence output directory}
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
fixture_dir=$(mktemp -d)
bundle=org.simpleagentmanager.validation.composer
simulator=
cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        for log in "$output_dir/mac-build.log" "$output_dir/build.log"; do
            if [ -f "$log" ]; then tail -60 "$log" >&2; fi
        done
    fi
    if [ -n "$simulator" ]; then
        xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
        xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
    fi
    rm -rf "$fixture_dir"
}
trap cleanup EXIT
cp -R "$native_dir/ios" "$fixture_dir/ios"
cp "$native_dir/ios/tests/composer-no-controls-ios.swift" "$fixture_dir/ios/SAM/SAMApp.swift"
generated="$native_dir/ios/Generated"
sources=()
while IFS= read -r source; do sources+=("$source"); done < <(find "$native_dir/ios/SAM" -name '*.swift' ! -name SAMApp.swift)
xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
    -I "$generated/SamCore.xcframework/macos-arm64/Headers" \
    "${sources[@]}" "$generated/SamCore.swift" "$native_dir/ios/tests/composer-render.swift" \
    -L "$generated/SamCore.xcframework/macos-arm64" -lsam_core -framework Security -framework SystemConfiguration \
    -o "$fixture_dir/composer-render" > "$output_dir/mac-build.log" 2>&1
"$fixture_dir/composer-render" "$output_dir/mac-renders" > "$output_dir/mac-result.txt" 2>&1
cat "$output_dir/mac-result.txt"
selection=$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
runtimes=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["name"].startswith("iOS")]
if not runtimes: raise SystemExit("Composer regression requires an available iOS simulator runtime")
runtime=max(runtimes,key=lambda r:tuple(map(int,r["version"].split("."))))
phone=next(d for d in runtime["supportedDeviceTypes"] if d["name"].startswith("iPhone"))
print(runtime["identifier"]+" "+phone["identifier"])
')
runtime=${selection%% *}
device_type=${selection#* }
simulator=$(xcrun simctl create "SAMComposerNoControls-$$" "$device_type" "$runtime")
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b > "$output_dir/boot.log" 2>&1
xcodebuild -project "$fixture_dir/ios/SAM.xcodeproj" -scheme SAM -configuration Debug \
    -sdk iphonesimulator -destination "id=$simulator" -derivedDataPath "$fixture_dir/build" \
    CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$bundle" build > "$output_dir/build.log" 2>&1
app_dir="$fixture_dir/build/Build/Products/Debug-iphonesimulator/SAM.app"
xcrun simctl install "$simulator" "$app_dir"
xcrun simctl launch "$simulator" "$bundle"
container=$(xcrun simctl get_app_container "$simulator" "$bundle" data)
for attempt in $(seq 1 30); do
    if [ -f "$container/Documents/composer-result.txt" ]; then break; fi
    sleep 1
done
cp "$container/Documents/composer-result.txt" "$output_dir/result.txt"
xcrun simctl io "$simulator" screenshot "$output_dir/composer.png"
grep '^PASS:' "$output_dir/result.txt"
