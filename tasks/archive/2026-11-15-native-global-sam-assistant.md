# Native global SAM assistant

## Request

Show SAM in a new main mobile tab when the global assistant is enabled, with the web assistant's features.

## Research

- The native shells previously exposed Projects and Notifications only (`SAMApp.swift`, Android `Screens.kt`).
- Web gates SAM with both `enabled` and installation `available` from `/api/sam/settings`.
- Web's private conversation uses `/api/sam/turns`, projected action receipts, legacy history and work updates.
- The turn-history payload includes live progress snapshots, so native polling can use the same projection.
- Web voice entry uploads multipart audio to `/api/transcribe` and fills the draft without sending.
- An uncertain turn submission needs its original request key across retries and app restarts.

## Implementation checklist

- [x] Gate a new SAM tab in both native shells on account settings and installation availability.
- [x] Add a shared Rust view model using existing web endpoints and account-bound transport.
- [x] Implement conversation/legacy pagination, live progress, Markdown, suggestions and composer.
- [x] Implement stop, confirm/decline, exact receipts, reconciliation and project-work updates.
- [x] Open project chats natively; use the deployment's web UI for other resources and Settings.
- [x] Persist retry receipts in Keychain / encrypted preferences before submission.
- [x] Add bounded voice recording and transcription to the draft, with foreground cleanup.
- [x] Test the exported view model through an authenticated scripted HTTP server.
- [x] Run Rust tests and Clippy, build Android, generate and inspect phone/tablet previews.
- [x] Verify iOS/macOS compilation with Xcode Cloud #33 (all actions succeeded).
- [x] Finish completion review and preserve PR/check evidence.

## Acceptance criteria and evidence

| Criterion | Evidence |
| --- | --- |
| Tab exists only when enabled and available | `disabled_or_unavailable_never_loads_or_sends_conversation`; both root shell conditions |
| Current/older history, live output and actions match web API | `conversation_retry_restart_history_approvals_stop_and_updates` |
| Lost receipts do not duplicate work | Same test: recreates the view model, reuses held request and blocks another active send |
| Confirm, decline, stop, reconcile and mark seen reach the API | Same test: asserts each authenticated endpoint and payload |
| Account changes do not reuse private state | `signed_out_view_model_cannot_read_or_mutate_a_private_conversation`; scoped transport |
| Voice entry fills the draft | `voice_upload_uses_authenticated_multipart_and_returns_a_draft`; bounded native recorders |
| Native layouts remain usable on phone/tablet | Six renders in `apps/native/verification/assistant/` |
| Builds pass | Rust: 38 tests, Clippy clean; Android assembleDebug passed; Xcode Cloud #33 succeeded on final code |

## Verification limits

Native wire tests use a scripted server. Layout renders use mock state. Physical microphone capture,
permission prompts and signed-in device navigation have not been exercised in this Linux workspace.
The implementation changes no server endpoints. Native progress uses two-second snapshot polling,
while web can also use SSE. Settings stays in the existing web UI.

## Completion evidence

PR: https://github.com/zebra-pig/simple-agent-manager/pull/30

Verified code commit: `fd33761d757602b695db805b85920fded2685520`. Xcode Cloud run #33
(`55d86c89-3b8e-479a-86c3-23842e6295d0`) succeeded for iOS archive, macOS archive and the
TestFlight internal action. GitHub preflight, specialist evidence, UI compliance and secret scan
passed on that commit. Android `assembleDebug lintDebug`, 38 Rust tests and Clippy passed.

The final evidence commit only archives this task and records verification; native runtime sources
are unchanged from the code commit verified by Xcode Cloud. The in-session completion audit report
is in `apps/native/verification/assistant/completion-review.md`.
