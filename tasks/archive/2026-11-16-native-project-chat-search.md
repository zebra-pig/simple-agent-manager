# Native project chat search

User confirmed this work targets SAM native, with PR and merge authorized.

## Research

- `ProjectView` has no search field; web's `useSessionSections` searches session metadata.
- `ProjectViewModel::load` reads only 50 sessions. The authenticated session-list endpoint supports `offset` and `hasMore`.
- Native transport and filtering belong in the shared Rust core; Apple uses the standard searchable list.

## Acceptance and implementation

- [x] Search project chats by title or session ID, case-insensitively with trimmed input.
- [x] Include older sessions via API pagination; retain the list on refresh failure.
- [x] Clear search to restore all rows; provide distinct no-match state and preserve native chat navigation.
- [x] Add capability tests using the real view model and authenticated HTTP.
- [x] Validate Rust tests/clippy, Apple builds, CI post-clone and rendered native UI.
  Evidence: apps/native/verification/project-search/README.md (84 tests, both Apple builds and five reviewed captures).
- [x] Complete SwiftUI specialist and task-completion self-review; CI passed. CodeRabbit request/outcome tracked in PR #66.
- [x] Prepare PR #66 for the authorized main merge; final merge outcome is recorded in SAM task completion evidence.

## Completion validation

| Check | Result | Evidence |
| --- | --- | --- |
| A: Research → checklist | PASS | Search and the initial 50-session limit are both addressed. |
| B: Checklist → diff | PASS | Shared filtering, pagination, system search UI, documentation and verification are present. |
| C: Criteria → tests | PASS | Authenticated HTTP capability tests plus five reviewed production-view captures. |
| D: UI → core | PASS | ProjectView search onChange calls searchSessions; matchingSessions drives rows. Filtering is local by design. |
| E: Multi-resource | N/A | Existing project-scoped API and row navigation are retained. |
| F: Vertical slice | PASS | Real HTTP client/core tests plus native search field → Rust → SwiftUI capture harness. |

Review fixed pagination to advance by the requested window even when the server
omits malformed rows. No unresolved findings. Limitations: offset pagination is
eventually consistent during concurrent server activity; metadata only; Apple UI
only; keyboard gestures and macOS runtime visuals not verified.
