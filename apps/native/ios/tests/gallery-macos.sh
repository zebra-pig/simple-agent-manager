#!/bin/bash
# Run on an Apple-silicon Mac after scripts/build-ios.sh.
set -euo pipefail
native="$(cd "$(dirname "$0")/../.." && pwd)"
build="${1:-$(mktemp -d)}"
mkdir -p "$build"
generated="$native/ios/Generated"
sources=()
for source in "$native/ios/SAM/"*.swift; do
    [[ "$source" == */SAMApp.swift ]] || sources+=("$source")
done
xcrun --sdk macosx swiftc -parse-as-library -target arm64-apple-macosx14.0 \
    -I "$generated/SamCore.xcframework/macos-arm64/Headers" \
    "$generated/SamCore.swift" "${sources[@]}" "$native/ios/tests/gallery-macos.swift" \
    -L "$generated/SamCore.xcframework/macos-arm64" -lsam_core \
    -framework Security -framework SystemConfiguration -o "$build/gallery-test"
python3 "$native/ios/tests/gallery-server.py" "$build/gallery-test" "$build/images"
