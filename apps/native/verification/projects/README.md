# Home and agent list verification

Captured with `xcrun simctl io booted screenshot` on the iPhone 18 Pro simulator
(iOS 27.0), through SSH to an Apple silicon Mac running Xcode 27.0.

| View | Capture |
| --- | --- |
| Home, dark | [home-dark.png](home-dark.png) |
| Home, light | [home-light.png](home-light.png) |
| Project agent/session list, dark | [agents-dark.png](agents-dark.png) |

The fixture hosts the production `ProjectsView` and `ProjectView`, with the real
Rust core and generated Swift bindings, against a localhost-only HTTP server.
Only the fixture app entry point and in-memory credentials replace production
wiring. The fixture has a separate bundle ID; it does not read account credentials,
call a live service, or create tasks. These files are outside application sources.

Reviewed all three captures for row spacing, separators, backgrounds, long names,
Unicode, repository wrapping, missing repository text and active-count badges.
Home now matches the agent list's native grouped background and standard row
spacing. The captures found a separator alignment issue caused by trailing count
badges; `listRowSeparatorLeading` now aligns separators with row content. Dark and
light Home captures include that correction. No clipping or overlap was found.

Both production macOS and iOS simulator builds passed after the separator change.
These captures verify layout, not taps, keyboard/search focus, navigation gestures,
or the live send-button interaction. The core race is covered by Rust integration
tests and a headless native Swift test. Mac desktop visuals remain unverified.

## Reproduce

First generate Apple bindings with `apps/native/scripts/build-ios.sh`.
Copy `apps/native/ios` to an isolated temporary directory, including `Generated`.
In that copy only, replace `SAM/SAMApp.swift` with `SAMVisualFixture.swift` and add
`NSAppTransportSecurity.NSAllowsArbitraryLoads = true` to `Info.plist` for localhost.
Do not change the production app entry point or transport policy.

Start `python3 fixture-server.py /absolute/path/to/port-file`; it binds to an
available loopback port and writes the port to that file. Build the copied Xcode
project for `generic/platform=iOS Simulator` with `CODE_SIGNING_ALLOWED=NO`,
`SAM_BUNDLE_ID=org.simpleagentmanager.validation.p6bhb5` and
`PRODUCT_BUNDLE_IDENTIFIER=org.simpleagentmanager.validation.p6bhb5`.

Install the fixture with `xcrun simctl install booted <fixture.app>`, then launch
with `xcrun simctl launch booted org.simpleagentmanager.validation.p6bhb5
--base=http://127.0.0.1:<port>`. Add `--project` for the agent list or `--light`
for light mode. After data loads, capture with `xcrun simctl io booted screenshot`.
Terminate/uninstall the fixture and stop the HTTP server when finished.

A logged-in Mac desktop is not required for these booted-simulator captures.
