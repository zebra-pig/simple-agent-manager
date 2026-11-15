# Chat jump regression (iOS simulator on a Mac)

`chat-scroll-ios.swift` compiles with the production `ChatScrollControl.swift` and
`ChatScrollProbe`. It uses variable-height messages, `LazyVStack`,
`scrollTargetLayout`, `scrollPosition`, and the production bottom anchor.
It prepends and visits two older 100-message chunks, then invokes the same
controller action as Jump to latest. Assertions check intermediate animated
movement, the final measured bottom, and repeated jumps. A failure crashes the
fixture; success writes `Documents/result.txt` in its simulator data container.

Build on the Mac from the repository root (use an isolated temporary directory):

```sh
fixture_dir=$(mktemp -d)
mkdir "$fixture_dir/ScrollFixture.app"
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target arm64-apple-ios17.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  apps/native/ios/SAM/ChatScrollControl.swift \
  apps/native/ios/tests/chat-scroll-ios.swift \
  -o "$fixture_dir/ScrollFixture.app/ScrollFixture"
/usr/libexec/PlistBuddy \
  -c 'Add :CFBundleIdentifier string dev.zebrapig.scrollfixture' \
  -c 'Add :CFBundleExecutable string ScrollFixture' \
  -c 'Add :CFBundleName string ScrollFixture' \
  -c 'Add :CFBundlePackageType string APPL' \
  -c 'Add :UILaunchScreen dict' "$fixture_dir/ScrollFixture.app/Info.plist"
xcrun simctl install booted "$fixture_dir/ScrollFixture.app"
xcrun simctl launch booted dev.zebrapig.scrollfixture
# After the fixture finishes (~12 seconds):
fixture_data=$(xcrun simctl get_app_container booted dev.zebrapig.scrollfixture data)
cat "$fixture_data/Documents/result.txt"
```

Verified on 2026-11-15 on the build Mac's iPhone 18 Pro / iOS 27 simulator:

- Full SAM simulator build with freshly generated Rust bindings: BUILD SUCCEEDED.
- Regression fixture: `PASS: 3 chunks · animated · reached latest · repeated taps`.
- Production `ChatView` launched with offline HTTP fixture credentials and a queued
  task at `workspace_creation`: the inline provisioning card displayed “Cloning
  repository · 2 of 4”, elapsed time, detail, and the four-stage indicator above
  the composer. Only the temporary preview entry point and mock server differed;
  production ChatView, Rust core, and provisioning component were unchanged.
- Screenshots: [scroll result](evidence/scroll-bottom/scroll-result.png) and
  [inline provisioning](evidence/scroll-bottom/provisioning.png).

The fixture exercises the controller action programmatically, not a physical tap.
It does not connect to a user's live conversation or provision a paid VM.
