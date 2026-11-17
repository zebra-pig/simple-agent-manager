#!/bin/sh
# Xcode Cloud only prepares the build: app identity, Rust core and Swift bindings.
# Tests do not run here (Cloud minutes are expensive); run them on a Mac with
# apps/native/scripts/test.sh. See apps/native/TESTING.md.
set -e
repo_dir=$CI_PRIMARY_REPOSITORY_PATH
"$repo_dir/apps/native/scripts/configure-ios.sh"
if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    . "$HOME/.cargo/env"
fi
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
"$repo_dir/apps/native/scripts/build-ios.sh"
