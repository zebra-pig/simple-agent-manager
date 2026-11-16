# Composer attachment picker regression

The iOS native `Menu` intermittently swallows a source-row tap after returning
from a system picker. In an isolated iOS 27 / iPhone 17 Pro simulator on the Mac,
Photos → cancel → Files reproduced this on the first cycle. Files still had not
opened after 15 seconds; the accessibility hierarchy retained the source menu.
Temporary action logging recorded Photos true/false but no Files action. This
also reproduced with a plain menu button and with noninteractive composer glass.

`AttachButton` now uses a compact iOS source sheet. A row records its source and
dismisses the sheet; only `onDismiss` presents the selected system picker. Closing
the chooser without selecting clears no picker state and opens nothing. No timer
or extra UIKit presenter is needed. macOS retains its existing native menu.

## Run

Build `ios/Generated` using `apps/native/scripts/build-ios.sh` first. On a Mac:

```sh
python3 apps/native/ios/tests/attachment-picker/make-project.py "$PWD/.tmp/Picker.xcodeproj"
xcrun simctl addmedia "$SIMULATOR_ID" /absolute/path/to/a/test-photo.png
xcodebuild test -project .tmp/Picker.xcodeproj -scheme Picker \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath .tmp/picker-build -resultBundlePath .tmp/picker.xcresult \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
```

Use an English-language simulator with one test photo in its library. The fixture
uses production `Composer`, `AttachButton`, and intake code in a NavigationStack /
List / bottom safe-area inset. Its two composer layouts correspond to chat and
new-task creation. It creates a local `picker-check.txt` for Files selection. No
server, credentials, or upload requests are involved.

The UI tests cover repeated Photos/Files opening and cancellation in both layouts,
with and without a keyboard (24 presentations), dismissing the source chooser,
and accepting actual Photos/Files selections into `ComposerFiles.add`. Tests wait
for picker contents to load before cancelling: the remote Photos service initially
shows a loading screen whose toolbar changes as it loads. Merely finding its
initial Cancel button is insufficient for a stable repeated-interaction test.

## Validation

Mac / Xcode 27.0 / iPhone 17 Pro / iOS 27.0, 2026-11-16:

- Full SAM iOS Simulator and macOS builds: passed, signing disabled, including
  after rebasing onto main's immediate-send composer fix.
- `testRepeatedPickerPresentation`: passed, 24 loaded-picker open/cancel cycles
  across both layouts and keyboard states (251.984 seconds).
- Final targeted selection/cancellation run: 3 tests, 0 failures (53.719 seconds).
  Both selection tests verify the callback's source can read the reported bytes.
- Original-code negative control: failed on first Files selection after Photos
  cancellation, even with a 15-second presentation timeout. Diagnostic variants
  removing glass button styling or interactive composer glass also failed.

Early test runs exposed fixture issues: first-launch remote picker loading can
outlast a short wait, a whole-screen swipe misses the compact sheet, and Xcode's
generated Info.plist omitted the fixture's file-sharing key. Tests now wait for
loaded picker content, drag the sheet itself, and use an explicit fixture plist.
These are harness corrections; the production source-sheet fix did not change.

Reviewed simulator captures: [source chooser](evidence/source-chooser.png),
[Photos](evidence/photos.png), [Files](evidence/files.png). Source rows are legible,
without clipping or overflow; both system browsers render correctly.

## Completion review

Local native code/interaction review and task-completion skill review:

| Check | Result | Evidence |
| --- | --- | --- |
| A: Findings → implementation | PASS | Swallowed menu selection replaced with a native source sheet. |
| B: Checklist → diff | PASS | Shared AttachButton changed; real UI regression harness added. |
| C: Criteria → verification | PASS | Original reproduction, repeated system dialogs, intake and full builds above; PR/release evidence is on the PR. |
| D: UI → intake | PASS | pendingSource → onDismiss → picker binding → existing AttachmentIntake → ComposerFiles.add; actual source bytes read in fixture. No API contract changes. |
| E: Source selection | PASS | One optional source discriminator, consumed before presentation; file/photo callbacks tested separately. |
| F: Interaction boundary | PASS | XCTest taps production controls and actual system pickers, rather than mocked presentation booleans. |

No blocking code/interaction findings remain. The review corrected unstable
system-picker loading assumptions and fixture file sharing before final evidence.
The source chooser clears pending selection on reopening, and cancelling it
cannot open a stale picker.

Scope: native presentation and intake only. Live authenticated upload, physical
hardware, and interactive macOS picker behavior are not covered. Web deployment
cannot execute this SwiftUI change; native simulator installation is the staging
artifact for this PR.
