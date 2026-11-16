# Native chat history pagination stability

## Request and acceptance

Scrolling up to earlier chat history must retain the message's exact visible
position, without jumping to another page or starting recursive loads. Verify
production ChatView on an iOS simulator and inspect before/after screenshots.

## Preflight

- Classification: public-surface-change, docs-sync-change (native scroll behavior).
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
- [ ] Run complete iOS touch suite and inspect screenshots.
- [ ] Review changes and task completion; push branch, PR and merge gates.

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
- Shared Rust: 89 tests pass, including two new real HTTP pagination regressions.
- Release Clippy, all targets, warnings denied: pass.
- Strict mixed-content + polling rerun: 2/2 pass. Three page loads retain exact
  final offsets and all display samples within 1pt. Polling continues, the reading
  snapshot remains fixed, and returning to latest flushes current live content.
- Final 12-test iOS run currently in progress. Screenshot review, native macOS
  compilation, task-completion review, push and PR gates remain pending.

## Limits

Fixture chats exercise production SwiftUI, core and HTTP transport. They do not
use the user's authenticated conversation. Runtime device: iPhone 16 Pro / iOS 27;
no execution on older iOS/macOS runtimes is claimed.
