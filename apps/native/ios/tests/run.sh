#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ios=$(cd "$here/.." && pwd)
mode=${1:?Usage: run.sh host|integration|ui|all OUTPUT_DIR [UI_SUITE]}
mkdir -p "${2:?Pass an empty output directory}"
output=$(cd "$2" && pwd)
if [ -e "$output/test-run.json" ]; then echo "Use a fresh output directory: $output" >&2; exit 1; fi
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
trap 'status=$?; python3 "$here/support/write-result.py" "$output" "$status" "$started" "$0" "$@"; exit "$status"' EXIT
case "$mode" in
    host)
        ruby "$here/support/make-project.rb" host "$ios" "$output/project" \
            "$ios/SAM/ChatDraft.swift" "$ios/SAM/ChatHistoryPager.swift" "$ios/SAM/ChatHistoryAnchor.swift" \
            "$ios/SAM/Glass.swift" "$ios/SAM/ResourceHistoryView.swift" "$ios/SAM/GalleryShare.swift" "$here/behavior/"*.swift
        action=test
        result_bundle="$output/results.xcresult"
        if [ "${SAM_TEST_HEADLESS_HOST:-0}" = 1 ]; then action=build-for-testing; result_bundle="$output/build-only.xcresult"; fi
        xcodebuild "$action" -project "$output/project/Behavior.xcodeproj" -scheme NativeTests \
            -destination 'platform=macOS' -derivedDataPath "$output/build" \
            -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO \
            | tee "$output/xcodebuild.log"
        if [ "${SAM_TEST_HEADLESS_HOST:-0}" = 1 ]; then
            python3 "$here/support/run-headless-host.py" "$output"
        else
            python3 "$here/support/check-result.py" "$output/results.xcresult"
        fi
        ;;
    integration)
        generated="$ios/Generated"
        xcrun --sdk macosx swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
            -I "$generated/SamCore.xcframework/macos-arm64/Headers" "$generated/SamCore.swift" \
            "$here/integration/uploaded-preview-macos.swift" \
            -L "$generated/SamCore.xcframework/macos-arm64" -lsam_core \
            -framework Security -framework SystemConfiguration -o "$output/uploaded-preview"
        python3 "$here/integration/uploaded-preview-server.py" "$output/uploaded-preview"
        bash "$here/ui/gallery/gallery-macos.sh" "$output/gallery"
        ;;
    ui)
        if [ -n "${3:-}" ]; then suites=("$3"); else suites=(composer errors chat-scroll gallery session-tools); fi
        for suite in "${suites[@]}"; do
            case "$suite" in
                composer|errors|chat-scroll|gallery|session-tools) bash "$here/support/run-ui.sh" "$here/ui/$suite" "$output/$suite" ;;
                project-loading) sh "$here/ui/project-loading/project-loading.sh" "$output/$suite" ;;
                slash-commands) bash "$here/ui/slash-commands/slash-commands.sh" "$output/$suite" ;;
                *) echo "Unknown UI suite: $suite" >&2; exit 1 ;;
            esac
        done
        ;;
    all)
        bash "$0" host "$output/host"
        bash "$0" integration "$output/integration"
        bash "$0" ui "$output/ui"
        bash "$0" ui "$output/project-loading" project-loading
        bash "$0" ui "$output/slash-commands" slash-commands
        ;;
    *) echo "Unknown mode: $mode" >&2; exit 1 ;;
esac
