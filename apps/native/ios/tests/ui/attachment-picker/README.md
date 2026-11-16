# Attachment picker device tests

Build `ios/Generated` with `apps/native/scripts/build-ios.sh`. On a Mac, use an
English-language simulator seeded with one test photo:

```sh
python3 apps/native/ios/tests/ui/attachment-picker/make-project.py "$PWD/.tmp/Picker.xcodeproj"
xcrun simctl addmedia "$SIMULATOR_ID" /absolute/path/to/test-photo.png
xcodebuild test -project .tmp/Picker.xcodeproj -scheme Picker \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath .tmp/picker-build -resultBundlePath .tmp/picker.xcresult \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO
```

The fixture uses production Composer, AttachButton and intake code in chat and
new-task layouts. It creates `picker-check.txt` for real Files selection and
checks that intake callbacks can read the selected bytes. Tests cover loaded
Photos/Files presentation, cancellation, chooser dismissal and actual selection,
with/without the keyboard. They do not contact a backend or test live upload.

These tests are opt-in because they depend on seeded system picker content.
See [native testing](../../../../TESTING.md) for the common testing workflow.
