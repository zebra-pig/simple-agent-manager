# Earlier chat history

The Apple chat now offers Load earlier messages above the loaded conversation.
Pages use exact [createdAt, sequence, id] cursors. Loaded transcript rows are
retained during polling and merged before display grouping, so a stream spanning
pages remains one reply. Refresh catches up through forward pages if an entire
newest window was missed. Failed/stalled pages retain loaded history and expose
Retry; concurrent older requests are coalesced. Changing sessions resets history.

Validation on the macOS build host:

- Full Rust suite passes, including six history integration tests against a
  scripted API: same timestamps/sequence ties, retries/stalled cursors, missed
  forward pages, stream grouping, repeated-text delivery receipts, session reset,
  duplicate loading, persistence across polling, and cancellation/retry after
  navigating away.
- Rust core and UniFFI bindings rebuilt for iOS, simulator and macOS.
- Full unsigned iOS Simulator and macOS app builds pass.
- Six original NSHostingView captures of the production ChatHistoryPager at
  375 and 1000 logical points show ready, loading and long error/retry states.
  They use mock supporting conversation text, not a real account or session.
  Inspected: readable wrapping and button labels, no clipping/overlap, spinner
  and disabled loading state visible. These are host renders, not iPhone photos.

SwiftUI scrollPosition tracks a visible message, with a prior stable-message
anchor fallback after prepending. Previously read text is retained rather than
jumping to the newest message. Physical-device scroll anchoring and live signed-in
server interaction remain unverified, especially a streaming group joining at a
page boundary. Android transport test fixtures were updated for the new shared
state fields; this PR adds the paging control to Apple chat only.

Reproduce fixture renders:

```sh
xcrun swiftc -parse-as-library apps/native/ios/SAM/ChatHistoryPager.swift \
  apps/native/ios/tests/chat-history-render.swift -o /tmp/sam-history-render
/tmp/sam-history-render /tmp/sam-history-images
```
