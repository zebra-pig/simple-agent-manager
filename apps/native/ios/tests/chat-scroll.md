# Chat scrolling regression

The earlier programmatic controller fixture did not exercise the real history
pager or user gestures. It missed the interaction reported by the user: repeated
history loading and scrolling after a jump. Its screenshots are historical
evidence only, not validation of the current correction.

The replacement is in `apps/native/verification/chat-scroll/`:

- Builds the full production app and Rust bindings. Only the isolated preview's
  app entry point changes to open the real `ChatView` with offline credentials.
- Uses real HTTP pagination, a held older-page response, and changing message
  heights on each production polling cycle.
- XCUITest performs touch swipes and taps the actual Jump to latest button.
- Checks that opening/polling at the bottom does not fetch history, a jump after
  multiple pages stays at the latest message across polling cycles, another
  gesture and jump work, polling preserves an older reading position, and an
  in-flight history response cannot pull the user
  back to the old anchor. The user’s exact reproduction is scroll to the top of
  this project chat and tap the down-arrow. The pending-response test holds the
  older-history response until after that actual tap, then releases it and checks
  that neither history completion nor two polling cycles restart scrolling.

Run on an Apple silicon Mac with Xcode 26+ and an installed iOS runtime:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
gem install --user-install xcodeproj -v 1.27.0 --no-document
apps/native/scripts/build-ios.sh
apps/native/verification/chat-scroll/run.sh /tmp/sam-scroll-regression
```

The runner creates and deletes a dedicated simulator and starts a loopback-only
mock server. It never reads account credentials or provisions a paid VM. Results
and screenshot attachments are recorded in `scroll-tests.xcresult`; HTTP requests
and page counters are recorded in `server.log`. `interaction.mov` records the
actual interaction for visual animation review. User interruption during an
active animation also needs explicit verification before merge. Run this suite on the Mac before considering the correction verified. No passing
result from the new interaction suite has been recorded yet.

Current correction: native offset-writing loops were removed; a SwiftUI semantic
bottom-edge request owns the scroll animation and lazy-layout correction. Bottom
tracking uses the viewport, and history loading triggers on the pager entering the
viewport rather than on lazy-row lifecycle or request completion. An explicit
jump invalidates any pending history anchor restoration. Older OS versions retain
the ScrollViewReader fallback and an explicit Load earlier messages button.

## Mac execution status

The private Mac cannot be reconnected because the SAM token expired. App Store
Connect access works, so the suite is being exercised by Xcode Cloud's Mac host.
The native iOS post-clone hook now runs it before archiving, and exports XCTest
screenshots to the build log even when tests fail.

Build 91 reached simulator test setup but failed in the generated test target
(missing PRODUCT_NAME); the parallel macOS hook also exposed a missing Loading.swift
input in the Files/Git render compile. Both harness issues were corrected. Build 93
is running commit 9ec7f2ad4e6a6d78293b22d330761ac9bc77c449; no UI success is claimed
until its results are inspected.

The current suite contains six real ChatView interaction tests. It includes four
repeated history jumps, mixed Markdown/code/tool/thinking rows, rotation, two poll
cycles after jumps, older reading-position retention, and a held history response.
A read-only display-link probe samples presentation offsets; the actual-button
test requires intermediate animation frames, rather than accepting an instant jump.

Build 93 compiled the app and ran all six UI tests, which failed: bottom visibility
was misreported despite the latest message being visible, subsequent history
loading stalled, and one retained-label query exceeded XCTest's 128-character
identifier limit. These are failures, not validation success. The next correction
uses the actual bottom sentinel's viewport visibility, excludes the pager from
String-ID position tracking, restricts the default bottom anchor to initial
placement/alignment, and uses an explicit label predicate in the tests. It adds
a seventh case for position retention while older messages actually prepend.
