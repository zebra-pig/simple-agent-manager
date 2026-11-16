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
- [ ] Validate Rust tests/clippy, Apple builds, CI post-clone and rendered native UI.
- [ ] Complete specialist/task-completion review, PR checks and CodeRabbit gate.
- [ ] Merge to main and report evidence.
