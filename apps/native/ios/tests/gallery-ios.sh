#!/bin/bash
# Reuse the repository's isolated XCTest project generator and simulator runner.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../../.." && pwd)"
output="${1:?Pass an isolated output directory}"
mkdir -p "$output/fixture"
# The existing runner locates its repo relative to itself. Give it a small,
# isolated repository layout with the production sources and gallery fixtures.
mkdir -p "$output/fixture/apps/native/verification/chat-scroll"
cp -R "$repo/apps/native/ios" "$output/fixture/apps/native/ios"
runner="$output/fixture/apps/native/verification/chat-scroll"
cp "$repo/apps/native/verification/chat-scroll/"{run.sh,add-ui-tests.rb} "$runner/"
cp "$repo/apps/native/ios/tests/gallery-ios.swift" "$runner/SAMScrollFixture.swift"
cp "$repo/apps/native/ios/tests/gallery-ui.swift" "$runner/ChatScrollUITests.swift"
cp "$repo/apps/native/ios/tests/gallery-server.py" "$runner/gallery-server.py"
printf 'import runpy,sys\nsys.argv=["gallery-server.py","--serve"]\nrunpy.run_path(__file__.replace("fixture-server.py","gallery-server.py"),run_name="__main__")\n' > "$runner/fixture-server.py"
# Keep the existing project/scheme names, but isolate the app identity.
sed -i '' 's/org.simpleagentmanager.validation.scroll/org.simpleagentmanager.validation.gallery/g' "$runner/run.sh"
bash "$runner/run.sh" "$output/run"
