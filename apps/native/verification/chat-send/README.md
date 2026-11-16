# Chat send handoff verification

`ChatView` uses `ChatSubmission.send` to lock submission and clear the durable
`ChatDraft` synchronously before starting `ChatViewModel.send`. The existing core
still owns attachments, outbox delivery, errors, and history refresh. A failed
request restores text only if the durable draft remains empty. Success leaves
any new draft untouched. Android already clears its draft before sending.

Validated on an Apple silicon Mac with Xcode 27:

- Production iOS Simulator and macOS builds passed.
- `chat-draft.swift` passed against production `ChatDraft.swift`: persistent and
  scoped drafts, immediate clear/lock, duplicate suppression while suspended,
  failure restoration, and preservation of newer drafts on success and failure.
- The same executable mounted a SwiftUI editor in navigation, reopened its draft,
  and confirmed it clears while the request is pending and restores after failure.
- Reused generated bindings from an identical Rust source tree; no core/API change.

Run from the repository root on macOS:

```sh
swiftc apps/native/ios/SAM/ChatDraft.swift apps/native/ios/tests/chat-draft.swift -o /tmp/chat-draft-tests
/tmp/chat-draft-tests
```

Task-completion review: requested clear/lock behavior, existing send propagation,
and failure/newer-draft protection are covered. Full Composer wiring was reviewed
and both targets compiled; no live-account send was performed.
