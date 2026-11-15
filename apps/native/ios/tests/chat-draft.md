# Chat draft persistence

Unsent Apple chat text is saved locally per server, viewer, project and session
on every edit. Navigating away or recreating the composer restores that draft.
Failed sends retain it. An accepted send clears only unchanged submitted text,
including when its response arrives after the composer has been reopened.
Attachments retain their existing lifecycle; this change persists typed text.

Run on macOS:

```sh
xcrun swiftc -parse-as-library apps/native/ios/SAM/ChatDraft.swift \
  apps/native/ios/tests/chat-draft.swift -o /tmp/sam-chat-draft-tests
/tmp/sam-chat-draft-tests
```

Tests use isolated UserDefaults suites and remove them afterward. Coverage:
recreated views/storage, multiline Unicode and whitespace, scope isolation,
composer binding edits, explicit deletion, failed-send retention, stale send
completion and successful clearing. A real NSHostingView/NavigationStack test
pushes, pops and recreates the composer and verifies mounted editor updates.
This does not simulate finger gestures or a real network send.

Validation on the macOS build host: CHAT_DRAFT_TESTS_PASS; full SAM iOS Simulator
and macOS builds succeeded with Xcode 27.0. The existing main-compatible generated
UniFFI artifacts were reused read-only from the other SAM build checkout; no Rust
or generated API changed. Builds used isolated DerivedData and disabled signing.
No on-device or signed archive test is claimed. Xcode Cloud runs the draft tests
in its existing macOS post-clone validation hook as well.
