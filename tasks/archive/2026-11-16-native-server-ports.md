# Native server ports — iOS feedback preview

User request: bring server ports, authenticated site access and public exposure controls
to SAM native. Show the iOS result. **Do not merge; await iOS feedback.**
Branch: `sam/sam-native-bring-server-avyxpb`.
Draft PR: https://github.com/zebra-pig/simple-agent-manager/pull/67

## Findings and scope

- Existing owner-only `/api/workspaces/:id/ports` provides detected servers and lifecycle.
- Existing `/port-access?port=…` supports JSON and returns a port-scoped browser grant.
  The workspace proxy exchanges the grant for an HttpOnly cookie and redirects cleanly.
- Existing `/ports-public` is workspace-wide, including future ports. UI must explain this.
- Use the shared Rust view model with SwiftUI and Compose shells. No backend changes.

## Checklist

- [x] Shared listing/readiness, guarded refresh/mutations and stale response protection.
- [x] Private browser opening through the native login without exporting the account cookie.
- [x] Public confirmation, make-private control, clean public sharing URLs.
- [x] Owner-only entry points in both mobile shells.
- [x] Rust API tests for login headers, visibility, rejection, hostile grants and refresh races.
- [x] Full Rust test suite and Clippy; Android Kotlin compile.
- [x] iOS and macOS app builds; both iOS and macOS post-clone script validation.
- [x] iPhone UI interaction test and screenshots from the production screen (2 tests pass).
- [x] Draft PR #67, pushed branch, and iPhone captures shared in the chat/library.
- [x] iOS feedback applied (native switch). On 2026-11-17 the user asked to merge
  finished native work; rebased onto main and merged.

## Acceptance and evidence

Ports list two running servers; private opening mints a grant and opens the system browser.
Public exposure asks for confirmation; cancelling preserves privacy, confirming enables clean
sharing links, making private hides them. Server rejection preserves confirmed state.
Readiness and stale refresh behavior are covered by Rust integration tests.

`apps/native/ios/tests/ui/ports/` (shared UI runner) is an isolated iPhone fixture using the actual SwiftUI
screen, generated Swift bindings and Rust HTTP transport, plus XCTest interaction coverage.
Its localhost API has no real credentials or workspace. Live production auth/proxy code is
unchanged; fixture Safari opening does not claim verification of a live hosted site.

Android validation compiles actual Compose sources and generated Kotlin bindings; the
Rust/NDK packaging task is skipped for this UI compile. No Android distribution is claimed.

## iOS feedback — native exposure toggle

Replaced the Apple exposure action with an **Expose to public** switch. Turning it
on keeps the existing confirmation; dismissing confirmation restores Off. Turning
it off closes public access. Saving failures restore the server-confirmed value.
Committed screenshots were removed at merge; the UI suite reproduces them as
result-bundle attachments.
