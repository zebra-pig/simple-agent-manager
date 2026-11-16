# Chat scrolling regression

The earlier programmatic controller fixture did not exercise the real history
pager or user gestures. It missed the interaction reported by the user: repeated
history loading and scrolling after a jump. Its screenshots are historical
evidence only, not validation of the current correction.

The replacement is in `apps/native/verification/chat-scroll/`:

- Builds the full production app and Rust bindings. Only the isolated preview's
  app entry point changes to open the real `ChatView` with offline credentials.
- Uses real HTTP pagination, a delayed older-page response, and changing message
  heights on each production polling cycle.
- XCUITest performs touch swipes and taps the actual Jump to latest button.
- Checks that opening/polling at the bottom does not fetch history, a jump after
  multiple pages stays at the latest message across polling cycles, another
  gesture and jump work, and an in-flight history response cannot pull the user
  back to the old anchor.

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
and page counters are recorded in `server.log`. Run this suite on the Mac before considering the correction verified. No passing
result from the new interaction suite has been recorded yet.

Current correction: native offset-writing loops were removed; a SwiftUI semantic
bottom-edge request owns the scroll animation and lazy-layout correction. Bottom
tracking uses the viewport, and history loading triggers on the pager entering the
viewport rather than on lazy-row lifecycle or request completion. An explicit
jump invalidates any pending history anchor restoration. Older OS versions retain
the ScrollViewReader fallback and an explicit Load earlier messages button.
