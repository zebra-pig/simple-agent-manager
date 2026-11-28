# Native chat history pagination stability

## Request and acceptance

Scrolling up to earlier chat history must retain the message's exact visible
position, without jumping to another page or starting recursive loads. Verify
production ChatView on an iOS simulator and inspect before/after screenshots.

## Preflight

- Classification: public-surface-change, docs-sync-change, cross-component-change,
  business-logic-change (native scrolling and stable shared timeline groups).
- Target: zebra-pig/simple-agent-manager/apps/native, confirmed by SAM context.
- Existing path: ChatHistoryPager viewport + drag intent -> ChatView -> Rust
  ChatViewModel::load_older -> HTTP before cursor -> state observer -> lazy rows
  -> ChatHistoryAnchor -> ChatScrollControl semantic ScrollPosition restore.
- No API, dependency, data schema or deployment changes planned.
- Use existing SwiftUI ownership; first reproduce and fix this path.
- Direct Mac access and Xcode 27 confirmed. Dedicated simulator and directory.
- Prior PR #54 merged with incomplete Mac verification. Baseline required.
- Update ios/tests/chat-scroll.md with actual observed results, not source claims.

## Investigation

The pager admits every visibility entry, including layout-driven ones, and keeps
pending entries across response completion. A reading anchor is captured before
loading and updated while waiting; restoration runs after loadingHistory flips.
These are hypotheses to verify against real rendered behavior.

## Checklist

- [x] Inspect existing paging, model state delivery and scroll ownership.
- [x] Reproduce baseline with production app and actual touch gestures.
- [x] Fix measured position drift and layout-triggered duplicate pagination.
- [x] Add regression checking consecutive prepends and no chained loads.
- [x] Run complete iOS touch suite and inspect screenshots.
- [x] Review implementation/task completion, push branch and open PR #73.

## Findings and corrections

1. A visibility reentry could admit another page without another drag. The Mac
   ScrollView fixture fails the new guard assertion on baseline and passes the fix.
2. Final-offset tests missed an intermediate frame with the newly prepended page.
   A newest-first logical layout leaves existing row coordinates unchanged when
   older items extend the far end. Rows remain upright and visually chronological.
3. Mixed content replaced the visible m-60 thought with an older activity card.
   Loaded page boundaries now preserve existing reply/thought/activity groups.
   Global tool resolution keeps status updates and a single stable card.
4. Background streaming caused transient reflow even with a correct final anchor.
   The Apple model holds a reading transcript, adds fetched older items, keeps
   canonical polling/composer state live, and catches up on returning to latest.
5. Reading preservation is applied to the same SwiftUI position before publishing
   changed displayed items. Real drags resume reading; explicit jumps bypass it.

## Validation

- Baseline production iOS suite: 10 executed, 7 passed, 3 failed. Expanded checks
  reproduced replacement of an existing card and transient background-poll drift.
- Shared Rust: 89 tests passed initially; all 88 remaining tests pass after main's
  independent audio-recording removal. Two new tests use real HTTP pagination.
- Release Clippy, all targets, warnings denied: pass on both bases.
- Final viewport-clipped production iOS suite: 12 executed, 12 passed, 0 skipped,
  473.958 seconds. All six controlled page loads have zero final drift and every
  display sample remains within 1pt. Background polling remains fixed and catches
  up on return to latest. Real moving responses, animation, repeated jumps,
  rotation, provisioning and the exact held-response top→arrow sequence pass.
- Current-main integration UI: 4/4 pass (plain/mixed pagination, initial polling,
  stable background polling and live catch-up), 129.271 seconds.
- Native macOS build passes on current main; all Apple core libraries regenerated.
- Mac ScrollView pager behavioral regression passes, including baseline red/green.
- Sixteen final simulator screenshots reviewed; no title/composer overlap remains.
  Pixel checks confirm matching mixed/polling regions and unchanged plain glyphs.
- Evidence: `apps/native/ios/tests/evidence/pagination-stability/verification.md`.

## Completion validation

| Check                      | Verdict | Evidence                                                                                                       |
| -------------------------- | ------- | -------------------------------------------------------------------------------------------------------------- |
| A: Findings → checklist    | PASS    | All five measured findings have code and regression coverage.                                                  |
| B: Checklist → diff        | PASS    | Pager, layout, model snapshot and core grouping changes are substantive.                                       |
| C: Criteria → verification | PASS    | Real iOS touch/frame checks, exact offsets and reviewed screenshots.                                           |
| D: UI → backend            | PASS    | Pager/retry/accessibility load action uses the existing core HTTP intent; reading state is deliberately local. |
| E: Multiple resources      | N/A     | No provider/auth/resource selection change.                                                                    |
| F: Vertical slice          | PASS    | Actual SwiftUI → UniFFI → Rust → loopback HTTP → rendered frame outcomes.                                      |

No uncovered research findings, acceptance criteria or critical/high review
findings remain. SwiftUI/API, state lifetime, accessibility order, shared grouping
and tool-update resolution were self-reviewed using swiftui-pro and the
repository task-completion-validator procedure.

## Release tracking

[PR #73](https://github.com/zebra-pig/simple-agent-manager/pull/73) is the source
of truth for current GitHub checks, the required CodeRabbit observation window,
and merge status. The task's implementation and native verification are complete;
SAM task completion is recorded only after the release gates and merge.

## Limits

Fixture chats exercise production SwiftUI, core and HTTP transport. They do not
use the user's authenticated conversation. Runtime device: iPhone 16 Pro / iOS 27;
no execution on older iOS/macOS runtimes is claimed.
