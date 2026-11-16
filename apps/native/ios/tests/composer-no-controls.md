# SAM composer without recording controls

Build 120's TestFlight crash report shows `EXC_BREAKPOINT` / `Index out of range`
in `ComposerInputLayout.placeSubviews` (`ProjectView.swift:343`) immediately after
opening SAM. Removing microphone recording left `attachmentControl` empty when
`files == nil`. SwiftUI omits that conditional view from `Layout.Subviews`, so the
layout's fixed editor/leading/send indices referred to only two children.

Keep the leading control inside a concrete `ZStack` with a clear backing view.
The layout now always receives its three slots, without adding any microphone or
attachment button to SAM. Composers with attachments retain their real button.

Run on a Mac with Xcode, an installed iOS simulator runtime, and freshly generated
bindings/XCFramework from `apps/native/scripts/build-ios.sh`:

```sh
bash apps/native/ios/tests/composer-no-controls.sh /tmp/composer-evidence
```

The runner compiles the production Swift sources, renders the production composer
at phone and desktop widths in five states on macOS, then builds an isolated iOS
fixture using the same production composer. iOS must survive empty, expanded,
Stop, Retry, and busy transitions and write its PASS receipt. No account, backend,
microphone permission, or recording is used. Temporary simulator/app copies are
removed afterward. Xcode Cloud invokes this regression before its iOS archive.

The original removal was checked with Rust tests and source audits, which cannot
exercise SwiftUI layout child counts. Running this native layout regression in
Xcode Cloud prevents that gap from recurring.

## Verified 2026-11-16

- Xcode 27.0, iPhone 17 Pro simulator on iOS 27.0: build succeeded; all five
  production composer states survived and wrote the [PASS receipt](evidence/composer-no-controls/result.txt).
- macOS production sources compiled; all 10 phone/desktop render cases passed.
- Negative control using the original conditional control with the same macOS
  renderer trapped with exit 133, reproducing the production failure.
- [iOS screenshot](evidence/composer-no-controls/ios.png) reviewed: no microphone
  control; editor and busy action remain within the composer. No signed-in
  account or physical-device test was performed.

Task-completion review: crash finding → fix/fixture/CI coverage PASS; planned
changes → diff PASS; acceptance → native render/simulator/negative-control tests
PASS. UI-to-backend and multi-resource selection are unchanged (N/A).
