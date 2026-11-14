#!/bin/sh
# Builds the Rust core for iOS (device + Apple-silicon simulator) and Apple-silicon
# macOS, generates the
# Swift bindings and assembles ios/Generated/SamCore.xcframework +
# SamCore.swift, which the Xcode project consumes. Output is gitignored.
set -eu

mobile_dir="$(cd "$(dirname "$0")/.." && pwd)"
core_dir="$mobile_dir/core"
out_dir="$mobile_dir/ios/Generated"
lib=libsam_core.a

cd "$core_dir"
# Xcode's environment leaks SDKROOT/arch flags into cargo when run from a build phase.
unset SDKROOT
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0

for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
  cargo build --release --lib --target "$target"
done

# Bindings come from the host build of the same crate (bindgen reads its metadata).
cargo build --release --lib
bindings="$(mktemp -d)"
trap 'rm -rf "$bindings"' EXIT
cargo run --release --bin uniffi-bindgen -- generate \
  --library target/release/libsam_core.dylib --language swift --out-dir "$bindings"

# `import SamCore` in the generated Swift does `import SamCoreFFI`;
# the modulemap must be named module.modulemap for Xcode to find that module.
headers="$bindings/headers"
mkdir -p "$headers"
cp "$bindings/SamCoreFFI.h" "$headers/"
cp "$bindings/SamCoreFFI.modulemap" "$headers/module.modulemap"

rm -rf "$out_dir"
mkdir -p "$out_dir"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/$lib" -headers "$headers" \
  -library "target/aarch64-apple-ios-sim/release/$lib" -headers "$headers" \
  -library "target/aarch64-apple-darwin/release/$lib" -headers "$headers" \
  -output "$out_dir/SamCore.xcframework"
cp "$bindings/SamCore.swift" "$out_dir/"

echo "Built $out_dir"
