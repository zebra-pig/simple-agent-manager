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

Mac: full SAM iOS Simulator and macOS builds passed with signing disabled. The
first fixed-version repetition test passed all 24 presentations; final checks and
screenshots are recorded here before merge.

Scope: native presentation and intake only. Live authenticated upload, physical
hardware, and interactive macOS picker behavior are not covered. Web deployment
cannot execute this SwiftUI change; native simulator installation is the staging
artifact for this PR.
