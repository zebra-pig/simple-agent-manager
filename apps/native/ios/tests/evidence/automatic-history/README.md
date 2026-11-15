# Automatic earlier history

Chat loads earlier pages when the history loader becomes visible. The loader stays
simple; errors retain a retry action and stop automatic requests. Completion
restarts paging while visible, including pages that produce no rendered rows.

`chat-history-loading.swift` hosts the production pager in SwiftUI and checks
appearance, in-flight suppression, continuation without message-ID changes,
error stop, hidden state and returning to history. Run on macOS:

```sh
swiftc apps/native/ios/SAM/ChatHistoryPager.swift apps/native/ios/tests/chat-history-loading.swift -o /tmp/history-test
/tmp/history-test
```

The four PNGs are native NSHostingView renders of the production pager, with mock
conversation text, at 375 and 1000 points. Loading and long retry/error states
were inspected for wrapping, clipping and readability; no issues found. They are
host renders rather than screenshots of a signed-in device.

Android's ChatHistoryTest covers the visible loader trigger, stable message/offset
after prepending, errors/retry and asynchronous initial positioning. Shared-core
chat_history integration tests cover cursor paging and transport behavior.
