#!/bin/sh

# Xcode Cloud: build the Rust core (SamCore.xcframework + Swift bindings)
# before Xcode builds the app. Generated/ is not committed, so without this
# step the build fails on a missing SamCore.swift.
# Fail loudly: a half-installed toolchain would otherwise surface later as a
# confusing "no such file" in the Xcode build phase.
set -e

repo_dir=$CI_PRIMARY_REPOSITORY_PATH

install_rust_if_needed() {
    echo "Install Rust if needed"

    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    fi

    if command -v rustup >/dev/null 2>&1; then
        echo " - Found $(rustup --version 2>/dev/null)"
    else
        echo " - No rustup found, installing..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
        . "$HOME/.cargo/env"
    fi

    rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
    cargo --version
}

install_rust_if_needed
"$repo_dir/apps/mobile/scripts/build-ios.sh"
