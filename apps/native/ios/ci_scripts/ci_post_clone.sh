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
        "$repo_dir/apps/native/ios/SAM/Loading.swift" \
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
    xcrun --sdk macosx swiftc -parse-as-library \
        "$repo_dir/apps/native/ios/SAM/ChatHistoryPager.swift" \
        "$repo_dir/apps/native/ios/tests/chat-history-loading.swift" \
        -o "$render_dir/chat-history-loading"
    "$render_dir/chat-history-loading"
    xcrun --sdk macosx swiftc -parse-as-library \
        "$repo_dir/apps/native/ios/SAM/ChatHistoryAnchor.swift" \
        "$repo_dir/apps/native/ios/tests/chat-history-position.swift" \
        -o "$render_dir/chat-history-position"
    "$render_dir/chat-history-position"
    # Exercise the production New project view as a sheet, including the
    # loading-to-loaded transition and repeated repository loads.
    sh "$repo_dir/apps/native/ios/tests/project-loading.sh" "$render_dir/project-loading-images"
    for loading_image in "$render_dir/project-loading-images/"*.png; do
        echo "PROJECT_LOADING_RENDER_BEGIN $(basename "$loading_image")"
        base64 -b 76 -i "$loading_image"
        echo "PROJECT_LOADING_RENDER_END"
    done
    rm -rf "$render_dir"
fi

install_rust_if_needed
"$repo_dir/apps/native/scripts/build-ios.sh"

# Exercise real Swift bindings, authenticated fallback transport, and ImageIO
# against an offline HTTP fixture after the generated Rust library is available.
if [ "$CI_PRODUCT_PLATFORM" = "macOS" ]; then
    preview_test_dir=$(mktemp -d)
    preview_generated="$repo_dir/apps/native/ios/Generated"
    xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
        -I "$preview_generated/SamCore.xcframework/macos-arm64/Headers" \
        "$preview_generated/SamCore.swift" \
        "$repo_dir/apps/native/ios/tests/uploaded-preview-macos.swift" \
        -L "$preview_generated/SamCore.xcframework/macos-arm64" \
        -lsam_core -framework Security -framework SystemConfiguration \
        -o "$preview_test_dir/preview-test"
    python3 "$repo_dir/apps/native/ios/tests/uploaded-preview-server.py" "$preview_test_dir/preview-test"
    gallery_mac_status=0
    bash "$repo_dir/apps/native/ios/tests/gallery-macos.sh" "$preview_test_dir/gallery" || gallery_mac_status=$?
    for gallery_image in "$preview_test_dir/gallery/images/"*.png; do
        [ -f "$gallery_image" ] || continue
        echo "GALLERY_MAC_SCREENSHOT_BEGIN $(basename "$gallery_image")"
        base64 -b 4096 -i "$gallery_image"
        echo "GALLERY_MAC_SCREENSHOT_END"
    done
    [ "$gallery_mac_status" -eq 0 ] || exit "$gallery_mac_status"
    rm -rf "$preview_test_dir"
fi

# Run real touch-driven chat regressions on the Mac host before the iOS archive.
# The runner copies the app into an isolated directory and uses only localhost
# fixture data. No account credentials or provisioning services are involved.
if [ "$CI_PRODUCT_PLATFORM" = "iOS" ]; then
    # The SAM text-only composer has no attachment/microphone child. Render the
    # production layout on both platforms so missing layout slots fail CI.
    composer_test_dir=$(mktemp -d)
    bash "$repo_dir/apps/native/ios/tests/composer-no-controls.sh" "$composer_test_dir"
    rm -rf "$composer_test_dir"
    gem install --user-install xcodeproj --version 1.27.0 --no-document
    scroll_test_dir=$(mktemp -d)
    scroll_test_status=0
    "$repo_dir/apps/native/verification/chat-scroll/run.sh" "$scroll_test_dir" || scroll_test_status=$?
    # A failing test still carries the most useful screenshots. Export them
    # before returning the original failure to Xcode Cloud.
    if [ -d "$scroll_test_dir/scroll-tests.xcresult" ]; then
        xcrun xcresulttool export attachments --path "$scroll_test_dir/scroll-tests.xcresult" \
            --output-path "$scroll_test_dir/attachments" || true
        find "$scroll_test_dir/attachments" -name '*.png' 2>/dev/null | while IFS= read -r screenshot; do
            echo "CHAT_SCROLL_SCREENSHOT_BEGIN $(basename "$screenshot")"
            base64 -b 4096 -i "$screenshot"
            echo "CHAT_SCROLL_SCREENSHOT_END"
        done
    fi
    if [ "$scroll_test_status" -eq 0 ]; then
        gallery_test_dir=$(mktemp -d)
        gallery_test_status=0
        bash "$repo_dir/apps/native/ios/tests/gallery-ios.sh" "$gallery_test_dir" || gallery_test_status=$?
        if [ -d "$gallery_test_dir/run/scroll-tests.xcresult" ]; then
            xcrun xcresulttool export attachments --path "$gallery_test_dir/run/scroll-tests.xcresult" \
                --output-path "$gallery_test_dir/attachments" || true
            find "$gallery_test_dir/attachments" -name '*.png' 2>/dev/null | while IFS= read -r screenshot; do
                echo "GALLERY_SCREENSHOT_BEGIN $(basename "$screenshot")"
                base64 -b 4096 -i "$screenshot"
                echo "GALLERY_SCREENSHOT_END"
            done
        fi
        exit "$gallery_test_status"
    fi
    exit "$scroll_test_status"
fi
