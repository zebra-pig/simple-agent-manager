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
port=$(python3 -c 'import socket; sock=socket.socket(); sock.bind(("127.0.0.1",0)); print(sock.getsockname()[1]); sock.close()')
sed -i '' "s/18875/$port/g" "$runner/SAMScrollFixture.swift" "$runner/ChatScrollUITests.swift"
printf 'import runpy,sys\nsys.argv=["gallery-server.py","--serve","%s"]\nrunpy.run_path(__file__.replace("fixture-server.py","gallery-server.py"),run_name="__main__")\n' "$port" > "$runner/fixture-server.py"
# Keep the existing project/scheme names, but isolate the app identity.
sed -i '' 's/org.simpleagentmanager.validation.scroll/org.simpleagentmanager.validation.gallery/g' "$runner/run.sh"
# Fail promptly if the fixture could not bind; never test against a stale server.
python3 - "$runner/run.sh" <<'PYCODE'
import pathlib,sys
path=pathlib.Path(sys.argv[1])
text=path.read_text()
text=text.replace('server_pid=$!', 'server_pid=$!\nsleep 0.2\nif ! kill -0 "$server_pid" 2>/dev/null; then cat "$run_dir/server.log"; exit 1; fi')
text=text.replace('-parallel-testing-enabled NO', '-collect-test-diagnostics never -parallel-testing-enabled NO')
path.write_text(text)
PYCODE
bash "$runner/run.sh" "$output/run"
