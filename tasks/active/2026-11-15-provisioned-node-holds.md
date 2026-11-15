# Hold provisioned nodes and recover placement

## Problem and research

A second task could consume the node booting for its owner. Shared placement authority has no owner hold; final workspace admission needs the same exclusion as advisory reusable selection (rules 61/69). TaskRunner then treated three final refusals as terminal even when normal placement could recover.

`placement-authority.ts:buildProvisionedNodeHoldSqlPredicate` excludes an active owner with no workspace, except for that owner. `reusable-node-authority.ts` and `workspace-admission-sql.ts` share it; node allocation validation remains independent because it runs during provisioning. Existing `idx_tasks_auto_provisioned_node` supports the correlated lookup. TaskRunner carries owner identity and permits one durable fallback from its own rejected node.

## Checklist

- [x] Shared exclusion at selection and atomic INSERT/ATTACH/restart admission.
- [x] Owner identity propagated through ranked, pinned and warm selection.
- [x] Restore and verify bounded TaskRunner fallback and crash recovery marker.
- [x] Restore SQLite controls and Worker vertical slices; targeted final checks green.
- [x] Local specialist and task completion review.
- [ ] PR with preflight and cost bounds; no merge/deployment.

## Regression evidence before workspace eviction

On original base ecaf05d86, real SQLite tests had 5 expected failures / 97 passes before hold, then 102 passes after. Authority+placement combined: 132 passes. Worker incident reproduced B taking A's node (both normal selection and stale final selection); fallback reproduced terminal state instead of alternate placement. Full checks were interrupted by VM memory eviction; those are not recorded as passing.

## Acceptance criteria

A's booting node is unavailable to B, then admits A. Idle unowned, failed/cancelled/completed/placed owner nodes remain reusable. A legitimately full own node falls back to another node, provisioning or queue under existing policy with a bounded budget. SQL tests use real SQLite D1 helper.

## Constraints

Skip staging and CodeRabbit by explicit human instruction: self-hosted fork has neither. Open PR and STOP for review. Do not merge/deploy. Branch sam/note-earlier-attempt-task-dm848c.

## Restored verification

- 132/132 SQLite admission and authority tests passed.
- 14/14 real workerd TaskRunner tests passed, including A/B selection, full-node alternative placement, crash replay, and bounded exhaustion.
- Lint passed 22 packages; typecheck passed 36 tasks; Agent Preflight checker passed.
- Local test-engineer, constitution, Cloudflare, doc-sync and task-completion reviews passed with no code findings.
- Full monorepo tests/build still in progress; infrastructure import timeouts passed with a 60-second hook limit. Two unchanged UI tests timed out at 5 seconds and will be rerun.
