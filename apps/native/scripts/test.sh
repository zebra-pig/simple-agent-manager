#!/bin/bash
set -euo pipefail
native=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:?Usage: test.sh core|android|apple-host|apple-integration|apple-ui|apple-all [OUTPUT_DIR] [UI_SUITE]}
shift
case "$mode" in
    core) cargo test --manifest-path "$native/core/Cargo.toml" "$@" ;;
    android) (cd "$native/android" && ./gradlew testDebugUnitTest "$@") ;;
    apple-host|apple-integration|apple-ui|apple-all) bash "$native/ios/tests/run.sh" "${mode#apple-}" "$@" ;;
    *) echo "Unknown test mode: $mode" >&2; exit 1 ;;
esac
