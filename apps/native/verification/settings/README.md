# Project Settings verification

The production `ProjectSettings` runs against a localhost-only fixture using the
real Rust core and regenerated Swift bindings. The fixture has in-memory test
credentials and its own bundle identifier. It does not contact production or
write project data.

Production iOS simulator and macOS builds passed with Xcode 27.0. The presentation
change preserves field bindings, repository selection, draft submission and typed
deletion confirmation. A read-only specialist review found no blocking code issues.

## Reproduce

Generate bindings with `apps/native/scripts/build-ios.sh`. Copy `apps/native/ios`
to an isolated directory, including `Generated`, and replace `SAM/SAMApp.swift`
with `SAMVisualFixture.swift` from this folder. In the copy's root `Info.plist`,
set `NSAppTransportSecurity.NSAllowsArbitraryLoads = true` for localhost access.
Do not add a plist under the synchronized `SAM/` source folder.

Start `python3 fixture-server.py /absolute/path/to/port-file`. Build the copied
project for `generic/platform=iOS Simulator` with `CODE_SIGNING_ALLOWED=NO` and
`PRODUCT_BUNDLE_IDENTIFIER=org.simpleagentmanager.validation.settings`.
Install on an isolated iPhone simulator and launch with
`--base=http://127.0.0.1:<port>`. Add `--light` for light mode or `--create` for
project creation. Capture with `xcrun simctl io <device-id> screenshot <path>`.
Terminate/uninstall the fixture, stop its server and delete the simulator afterward.

## Results

- [Light mode](settings-light.png) and [dark mode](settings-dark.png): native
  opaque grouped sections, inset separators, trailing values and a red delete row.
  No custom glass containers, shadows or outlined text-field boxes remain.
- Reviewed the iPhone 18 Pro captures on iOS 27.0 for spacing, contrast, labels,
  repository values and description placement. No clipping or overlaps found.
- macOS compilation passes; macOS desktop visuals and save/delete interactions
  were not exercised. This change adds no API or core behavior.

Task-completion review: request and implementation coverage PASS; visual/build
coverage PASS for iOS; existing UI data propagation PASS. Provider behavior and
cross-boundary additions are not applicable because this is a presentation change.
