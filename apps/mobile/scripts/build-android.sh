#!/usr/bin/env bash
# Builds the Rust core (apps/mobile/core) for Android and generates its Kotlin
# bindings. Gradle runs this before every build (task buildRustCore), so
# `./gradlew assembleDebug` needs no separate step.
#
#   build-android.sh [out-dir]   (default: apps/mobile/android/app/build/rust)
#
# Writes <out>/jniLibs/<abi>/libsam_core.so and <out>/kotlin/org/simpleagentmanager/core/*.kt.
# Needs: cargo, cargo-ndk, the aarch64/x86_64-linux-android rust targets, and an
# NDK (ANDROID_NDK_HOME, or the newest one under $ANDROID_HOME/ndk).
set -euo pipefail

mobile="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$mobile/android/app/build/rust}"
export PATH="$HOME/.cargo/bin:$PATH" # Gradle daemons started from an IDE lack it
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

cd "$mobile/core"
cargo ndk -t arm64-v8a -t x86_64 -o "$out/jniLibs" build --release
# Bindings come from an unstripped host build: bindgen reads the UniFFI
# metadata symbols and silently emits nothing from the stripped release ELF.
cargo build --quiet --lib
[[ "$(uname)" == Darwin ]] && ext=dylib || ext=so
rm -rf "$out/kotlin"
cargo run --quiet --bin uniffi-bindgen -- generate \
  --library "target/debug/libsam_core.$ext" \
  --language kotlin --no-format --out-dir "$out/kotlin"
test -f "$out/kotlin/org/simpleagentmanager/core/sam_core.kt"
