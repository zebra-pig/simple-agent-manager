# Native testing

Test behavior at the layer that owns it. Shared rules belong in Rust; shell tests
cover platform storage, rendering, input and navigation. An app build, generated
PNG, source-text search or unconditional PASS receipt is not a behavioral test.

## Structure

| Location                                                               | Responsibility                                                                                  | Runner                             |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------- |
| `core/src/` test modules                                               | Pure transformations and state rules                                                            | `cargo test`                       |
| `core/tests/`                                                          | Public view-model behavior, HTTP contracts and failure/retry with local servers                 | `cargo test`                       |
| `ios/tests/behavior/`                                                  | Production Swift persistence, submission, pagination and chart transformations; XCTest on macOS | Apple `host`                       |
| `ios/tests/integration/`                                               | Real UniFFI/HTTP/ImageIO boundary with offline fixtures                                         | Apple `integration`                |
| `ios/tests/ui/`                                                        | Production SwiftUI controls, touch gestures, keyboard, sheets and system pickers                | Apple `ui`                         |
| `ios/tests/support/`                                                   | Shared isolated Xcode project/simulator runner                                                  | Used by the suites                 |
| `android/app/src/test/`                                                | JUnit/Robolectric Compose behavior and shell state                                              | Gradle `testDebugUnitTest`         |
| `android/app/src/screenshotTest/` and `screenshotTestDebug/reference/` | Compose visual comparisons and their reviewed baselines                                         | Gradle screenshot tasks            |
| `android/app/src/androidTest/` (when needed)                           | Device-only integration, system UI and platform services                                        | Gradle `connectedDebugAndroidTest` |
| `verification/`                                                        | Manual visual review tools and historical captures; not an automated test suite                 | See individual tools               |
| `docs/testing/`                                                        | Manual device procedures and suite-specific limits                                              | Human review                       |

The generated Apple XCTest projects compile the actual production Swift files.
UI projects replace only the app entry point with fixture setup. They do not
change the shipping target or introduce runtime test hooks. The macOS behavior
bundle compiles a small source subset; `ResourcePoint` is a transport-shaped test
record. HTTP/UniFFI integration and app builds cover the real generated types.

Use XCTest for the existing Apple suites and UI automation. A new pure Swift
unit suite may use Swift Testing in the same test target, but do not mix assertion
APIs within one test. Avoid another project generator or third-party testing
framework when the existing runner suffices.

## Commands

From the repository root:

```sh
bash apps/native/scripts/test.sh core
bash apps/native/scripts/test.sh android
bash apps/native/scripts/test.sh apple-host .tmp/native-host
bash apps/native/scripts/test.sh apple-integration .tmp/native-integration
bash apps/native/scripts/test.sh apple-ui .tmp/native-composer composer
bash apps/native/scripts/test.sh apple-ui .tmp/native-errors errors
bash apps/native/scripts/test.sh apple-ui .tmp/native-scroll chat-scroll
bash apps/native/scripts/test.sh apple-ui .tmp/native-gallery gallery
bash apps/native/scripts/test.sh apple-ui .tmp/native-lock app-lock
bash apps/native/scripts/test.sh apple-ui .tmp/native-split split-view
bash apps/native/scripts/test.sh apple-ui .tmp/native-ports ports
bash apps/native/scripts/test.sh apple-ui .tmp/native-loading project-loading
bash apps/native/scripts/test.sh apple-ui .tmp/native-commands slash-commands
bash apps/native/scripts/test.sh apple-all .tmp/native-all
```

Use a fresh output directory for each run. Apple `host` needs a Mac, Xcode and
`gem install --user-install xcodeproj --version 1.27.0 --no-document`.
On a headless Mac without the GUI `testmanagerd` service, set
`SAM_TEST_HEADLESS_HOST=1`: the same XCTest bundle is built with
`build-for-testing` and executed by `xcrun xctest`. That mode keeps `xctest.log`
and a counted `summary.json`, rather than claiming an `.xcresult` execution.

Apple UI/integration also need fresh `ios/Generated` bindings from
`apps/native/scripts/build-ios.sh`. UI tests use an installed simulator runtime
and a compatible device, discovered together. Set `SAM_TEST_DEVICE_PREFIX=iPad`
to run the shared UI runner on a tablet. They create/delete their own simulator
and start/stop their own loopback server with an OS-assigned port.

For a focused shared UI case, set `SAM_TEST_ONLY`, for example:

```sh
SAM_TEST_ONLY=NativeUITests/ChatScrollUITests/testActualJumpAfterMultiplePagesStaysAtBottom \
  bash apps/native/scripts/test.sh apple-ui .tmp/native-jump chat-scroll
```

`apple-ui` without a suite runs composer, errors, chat-scroll, gallery, session-tools,
app-lock, split-view and ports. split-view runs twice: on an iPhone for compact navigation
and on an iPad for the sidebar, rotation and notification-route cases.
`apple-all` also runs host, integration, project-loading and slash-commands.
Attachment-picker tests require a seeded photo library and Files content; follow
[ios/tests/ui/attachment-picker/README.md](ios/tests/ui/attachment-picker/README.md).
They are opt-in, not silently counted as CI coverage.

The project-loading and slash-command suites are assertion-based app harnesses
that report failures through process exit/result files. The new shared suites
and host checks use XCTest and `.xcresult`. Do not add another receipt-based
harness; add XCTest cases to the shared runner instead.

Android tests need the Android SDK/JDK, Rust Android targets and cargo-ndk used by
`scripts/build-android.sh`; Gradle `preBuild` generates the bindings. For visual
changes, run `validateDebugScreenshotTest`. Run `updateDebugScreenshotTest` only
to intentionally change reviewed baselines, then inspect their diff. There is no
current device-test suite; JVM success does not establish real device behavior.

## Writing and verifying tests

- Call production code and assert externally observable results. Mock the network,
  clock or OS boundary where necessary, not the behavior being verified.
- Use Rust tests for API payloads, auth isolation, paging identities, retry and
  duplicate admission; do not duplicate those rules in both platform shells.
- Use Apple/Compose behavior tests for bindings and shell state. Use device UI
  tests where gestures, native layout, focus, sheets or system pickers matter.
- Name tests after the behavior and give failures useful expected/actual values.
  Wait for observable conditions with deadlines; never leave unbounded polling.
- For a bug fix, show the test failing on the faulty behavior when feasible, then
  passing with the fix. A renderer that does not crash is only a smoke check.
- Screenshot attachments aid diagnosis. Automated visual tests must actually
  compare reviewed baselines or assert layout/accessibility measurements.
- Test phone/tablet or wide desktop, large text and light/dark appearance when
  changing adaptive UI. State which configurations ran; do not imply coverage of
  older supported OS versions or physical devices from a newer simulator run.

## CI and evidence

`ios/ci_scripts/ci_post_clone.sh` runs the same Apple runner: host/integration (headless XCTest) for
macOS, the six default/extra simulator suites for iOS. Xcode Cloud builds the
production application afterward. These checks run in Xcode Cloud, not the Linux
GitHub Actions workflow; a green GitHub check alone is not Apple test evidence.

Each Apple invocation writes `test-run.json` with source revision, dirty state,
command, toolchain, time and exit status. XCTest suites retain `.xcresult`, logs
and attachments. When testing a source archive rather than a git checkout, pass
`SAM_TEST_COMMIT=<full SHA>` and `SAM_TEST_DIRTY=true` if it contains uncommitted
changes. The default is `unknown` rather than inventing provenance.

Keep generated results in ignored `.tmp/` or a CI artifact/library upload. Link the
run in the PR and report the exact suites, counts, device/OS and limits. Do not
commit evidence folders, PASS receipts, base64 screenshots or completion-review
narratives. Commit images only when an automated comparison consumes them as
reviewed baselines. Previous captures remain in git history.

## Framework references

- [Apple testing](https://developer.apple.com/documentation/xcode/testing): Swift Testing for unit tests and XCTest/XCUIAutomation for UI tests.
- [Android testing strategy](https://developer.android.com/training/testing/fundamentals/strategies): choose the smallest scope with enough platform fidelity.
- [Rust test organization](https://doc.rust-lang.org/book/ch11-03-test-organization.html): unit tests beside implementation and public integration tests in `tests/`.
