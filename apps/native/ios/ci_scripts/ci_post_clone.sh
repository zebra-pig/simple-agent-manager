#!/bin/sh

# Xcode Cloud: apply the build's identity (SAM_* and BASE_DOMAIN workflow
# environment variables, see scripts/configure-ios.sh), then build the Rust core (SamCore.xcframework + Swift bindings)
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

"$repo_dir/apps/native/scripts/configure-ios.sh"
# Render the actual Swift Charts view on the macOS host. Fixture images are
# carried in build logs because Xcode Cloud has no custom-artifact upload hook.
# Only mock resource data is encoded; this never reads a live session.
if [ "$CI_PRODUCT_PLATFORM" = "macOS" ]; then
    render_dir=$(mktemp -d)
    xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
        "$repo_dir/apps/native/ios/SAM/Glass.swift" \
        "$repo_dir/apps/native/ios/SAM/ResourceHistoryView.swift" \
        "$repo_dir/apps/native/ios/tests/resource-history-render.swift" \
        -o "$render_dir/render"
    "$render_dir/render" "$render_dir/images"
    for chart_image in "$render_dir/images/"*.png; do
        echo "RESOURCE_CHART_RENDER_BEGIN $(basename "$chart_image")"
        base64 -b 76 -i "$chart_image"
        echo "RESOURCE_CHART_RENDER_END"
    done
    xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
        "$repo_dir/apps/native/ios/SAM/FileBrowserView.swift" \
        "$repo_dir/apps/native/ios/tests/files-git-render.swift" \
        -o "$render_dir/files-git-render"
    "$render_dir/files-git-render" "$render_dir/files-git-images"
    for browser_image in "$render_dir/files-git-images/"*.png; do
        echo "FILES_GIT_RENDER_BEGIN $(basename "$browser_image")"
        base64 -b 76 -i "$browser_image"
        echo "FILES_GIT_RENDER_END"
    done
    xcrun --sdk macosx swiftc -parse-as-library \
        "$repo_dir/apps/native/ios/SAM/ChatDraft.swift" \
        "$repo_dir/apps/native/ios/tests/chat-draft.swift" \
        -o "$render_dir/chat-draft-tests"
    "$render_dir/chat-draft-tests"
    rm -rf "$render_dir"
fi

install_rust_if_needed
"$repo_dir/apps/native/scripts/build-ios.sh"
