#!/bin/sh
# Xcode Cloud and local development use the same native test entry points.
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
gem install --user-install xcodeproj --version 1.27.0 --no-document
output=$(mktemp -d)
# Keep result bundles/logs available in the build workspace; export attachments
# even on test failure. Xcode Cloud has no custom artifact-upload hook.
finish() {
    status=$?
    find "$output" -name '*.xcresult' -type d | while IFS= read -r result; do
        xcrun xcresulttool get test-results summary --path "$result" || true
        attachments="${result%.xcresult}-attachments"
        xcrun xcresulttool export attachments --path "$result" --output-path "$attachments" || true
        find "$attachments" -name '*.png' -type f | while IFS= read -r image; do
            echo "NATIVE_TEST_ATTACHMENT_BEGIN $(basename "$image")"
            base64 -b 4096 -i "$image"
            echo NATIVE_TEST_ATTACHMENT_END
        done
    done
    exit "$status"
}
trap finish EXIT
case "$CI_PRODUCT_PLATFORM" in
    macOS)
        SAM_TEST_HEADLESS_HOST=1 bash "$repo_dir/apps/native/ios/tests/run.sh" host "$output/host"
        bash "$repo_dir/apps/native/ios/tests/run.sh" integration "$output/integration"
        ;;
    iOS)
        bash "$repo_dir/apps/native/ios/tests/run.sh" ui "$output/ui"
        bash "$repo_dir/apps/native/ios/tests/run.sh" ui "$output/project-loading" project-loading
        bash "$repo_dir/apps/native/ios/tests/run.sh" ui "$output/slash-commands" slash-commands
        ;;
esac
