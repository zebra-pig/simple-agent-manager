# Loading-state verification

Initial requests use a centered loader covering the content area. Subsequent
requests retain the screen, including empty results, and show progress inside
the action button without changing its dimensions.

Audited Apple and Android loading indicators across project creation/settings,
Home, sessions, Files/Git/source, session tools, assistant, notifications, account,
profiles, documents and attachments. Removed loading rows/bars that inserted space
above content. Kept contextual upload, send, sign-in approval, live-agent and
older-history progress; these indicate specific operations and are not screen
reload banners. Existing pull-to-refresh controls retain visible content.

The shared core preserves file text and repository results while refreshing the
same request. Changed file/diff identities and repository account/search identities
clear stale results, so failed navigation cannot present another resource's data.

## Validation

On an Apple silicon Mac with Xcode 27:

- Production macOS and iOS Simulator builds passed.
- `cargo test`: 81 tests passed, including two new observer/API regressions.
- `cargo clippy --all-targets -- -D warnings` passed.
- `LoadingLabelCheck.swift`: rendered three Apple action labels with identical
  dimensions in idle and busy states.
- Production views ran in the iPhone 18 Pro simulator against the delayed,
  loopback-only API fixture. Initial/loaded/refreshing/completed captures verify
  the centered first loader, retained chart/selector geometry, and toolbar spinner.
  This also caught and fixed native toolbar extraction of a `Label`, which had
  discarded the spinner overlay. `LoadingLabel` uses an explicit image/text stack.

Android production Kotlin compiled and the Robolectric `LoadingTest` passed
(1 test, 0 failures). It checks initial content gating, content visibility during
refresh, and unchanged content/button bounds. This run excluded `buildRustCore`
and used UniFFI Kotlin bindings generated from the current core on the Mac; it
was not an Android APK/device test.

These are native client changes; no server deployment is part of this change.
The branch's native artifact was verified against a delayed HTTP boundary rather
than deploying unchanged server/web code. Mac desktop interaction and live
account authentication were not exercised.

| State | Capture |
| --- | --- |
| Initial resources request | [initial.png](initial.png) |
| Loaded resources | [loaded.png](loaded.png) |
| Refreshing resources | [refreshing.png](refreshing.png) |
| Refreshed resources | [refreshed.png](refreshed.png) |
| Initial project creation | [settings-initial.png](settings-initial.png) |
| Loaded project creation | [settings-loaded.png](settings-loaded.png) |

## Reproduction

Generate Apple bindings with `apps/native/scripts/build-ios.sh`. Copy `ios/` to
an isolated directory, replace its `SAM/SAMApp.swift` with `SAMVisualFixture.swift`,
and allow localhost HTTP in that copy's Info.plist. Build the fixture with bundle
ID `org.simpleagentmanager.validation.loading`. Start `python3 fixture-server.py
<port-file>` and launch the fixture with `--base=http://127.0.0.1:<port>`.
The fixture's production Resources view loads immediately and refreshes after
seven seconds. Its Documents/stage file records loading-0, loaded-1, loading-1,
and loaded-2; wait for each state before capturing with `simctl io screenshot`.
Add `--settings` for the real project creation form. `SAM_FIXTURE_DELAY=6` gives
extra capture time for that screen. Stop the server and uninstall the fixture
afterward. The fixture never accesses a real account or creates projects/tasks.

Run the Mac label check with `swiftc -parse-as-library ios/SAM/Loading.swift
verification/loading/LoadingLabelCheck.swift -o <temporary-executable>` from the
native directory. Run the Android regression with `./gradlew :app:testDebugUnitTest
--tests '*LoadingTest'` after generating Rust bindings.

## Completion validation

| Check | Verdict | Evidence |
| --- | --- | --- |
| A: Findings covered | PASS | Screen loading rows and core data clearing both addressed |
| B: Implementation coverage | PASS | Apple/Android surfaces plus shared-core changes in diff |
| C: Acceptance verification | PASS | Native builds, rendered bounds test and simulator captures |
| D: UI propagation | PASS | Existing load/save/browse intents preserved; no new API input |
| E: Resource identity | PASS | File/diff and repository source keys; changed-source tests |
| F: Vertical slice | PASS | Real production SwiftUI/core over delayed HTTP; core API/observer tests |
