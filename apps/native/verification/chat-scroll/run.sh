#!/bin/bash
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/../../../.." && pwd)
verification_dir="$repo_dir/apps/native/verification/chat-scroll"
run_dir=${1:?Pass an isolated output directory}
mkdir -p "$run_dir"
run_dir=$(cd "$run_dir" && pwd)
cp -R "$repo_dir/apps/native/ios" "$run_dir/ios"
cp "$verification_dir/SAMScrollFixture.swift" "$run_dir/ios/SAM/SAMApp.swift"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$run_dir/ios/Info.plist"
ruby "$verification_dir/add-ui-tests.rb" "$run_dir/ios/SAM.xcodeproj" "$verification_dir/ChatScrollUITests.swift"
python3 "$verification_dir/fixture-server.py" > "$run_dir/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
# Prefer an installed runtime rather than depending on a particular device name.
read -r device_type runtime < <(python3 - <<'PY'
import json,subprocess
runtimes=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','-j']))['runtimes']
runtime=next(r for r in reversed(runtimes) if r['isAvailable'] and 'iOS' in r['name'])
types=json.loads(subprocess.check_output(['xcrun','simctl','list','devicetypes','-j']))['devicetypes']
device=next(d for d in reversed(types) if d['name'].startswith('iPhone'))
print(device['identifier'],runtime['identifier'])
PY
)
simulator=$(xcrun simctl create SAMScrollRegression "$device_type" "$runtime")
trap 'kill "$server_pid" 2>/dev/null || true; xcrun simctl delete "$simulator"' EXIT
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b
xcodebuild test -project "$run_dir/ios/SAM.xcodeproj" -scheme ChatScrollRegression \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath "$run_dir/build" -resultBundlePath "$run_dir/scroll-tests.xcresult" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  SAM_BUNDLE_ID=org.simpleagentmanager.validation.scroll \
  | tee "$run_dir/xcodebuild.log"
