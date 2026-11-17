# Native iPad split view

The user requested an iPadOS split layout in the SAM native app, using the
swiftui-pro skill, with verification and screenshots from the remote Mac.

Research: `ProjectsView` currently pushes projects and conversations on one
stack. Keep the existing Rust model boundary; use native split navigation for
projects beside project sessions/conversation, collapsing automatically in
narrow windows. Push routes must retain both project and session identities.
SAM already declares all four iPad orientations in project settings; retain
those settings and the existing iPhone configuration.

- [x] Replace projects stack with adaptive sidebar/detail navigation.
- [x] Preserve project settings, creation and notification routing.
- [x] Verify existing iPad orientations and retain the device configurations.
- [x] Run production iOS/macOS builds and `ci_post_clone.sh`.
- [x] Exercise selection, chat, project switching, rotation and compact back
  navigation against the real Rust core through an offline HTTP fixture.
- [x] Capture and inspect iPad screenshots on the remote Mac.
- [x] Live staging verification: not applicable (no backend change); the user asked
  on 2026-11-17 to merge finished native work. Offline HTTP integration and
  simulator verification passed; live staging is not claimed.
- [x] SwiftUI specialist review completed; addressed full-row hit testing and keeping
  the newest pending notification. Stable project root avoids chat state remounts.
- [x] Task-completion validator passed A–F for implementation and acceptance
  evidence; staging and CodeRabbit release gates remain explicitly pending.
- [x] Push and open draft PR #62 with validation and staging blocker.
- [x] Rebased onto main (floating error badges, app lock, session tools), moved the
  UI tests to the shared runner as `ios/tests/ui/split-view`, removed committed
  screenshots, and merged.

Acceptance: sidebar and selected project/chat are visible together on iPad;
project switching clears the previous conversation; phone back/reselect works;
rotation retains selection; notification routes open the requested conversation;
screenshots and validation evidence describe the SAM app.

Tests: `bash apps/native/scripts/test.sh apple-ui <fresh-dir> split-view`.
Initial startup push regression was found by the simulator and fixed with an
explicit pending route and stable detail-root identity. Three UI tests pass.
