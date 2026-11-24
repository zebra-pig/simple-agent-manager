# Native agent list refresh

The iPad agent list stays mounted beside a conversation, but only loaded on
appearance, manual refresh, or submission from its own composer. A newly spawned
agent therefore never reached the list. Native chat already uses HTTP polling;
there is no native push client to repair.

## Implementation

- [x] Refresh the visible iOS project list in an active scene; cancel its timer on disappearance/backgrounding.
- [x] Poll only the recent 50 sessions, retaining older loaded history for search. One session request per five seconds plus response time (at most 12/minute per visible window), independent of total history. More than 50 newly active sessions between polls can require an explicit full refresh to discover every intermediate session.
- [x] Preserve query, profiles, composer and conversation selection.
- [x] Reject stale responses after newer reads, including same-project manual refresh.
- [x] Add HTTP model tests for discovery, search, error/retry, bounded pagination and controlled stale-response ordering.
- [x] Add an iPad UI test that changes server sessions after opening a conversation and waits for a hittable new row without navigation/manual refresh.
- [ ] Run native tests on the build Mac and demonstrate the UI regression fails without the polling trigger.
- [ ] Complete specialist review and address findings.
- [ ] Push, open PR and reconcile checks/reviews before merge.
- [ ] Verify the merged commit's Xcode Cloud build and TestFlight distribution.

## Acceptance

A server-side spawn appears in the mounted iPad list within one polling interval
plus request latency; the selected conversation stays visible and usable. Search
still finds older loaded sessions. A failed poll preserves visible data and retries.
