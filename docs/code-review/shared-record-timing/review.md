# Bug-focused gate: shared Record timing

Base `8749688c51912f808c3f36d4eb5bca665ede3ade`; reviewed working revision is
bound by `docs/reviews/shared-record-timing/source.json`, fingerprint
`b207f4686085c3bc8a67e150b2716449a451fd9deb8f7df0427524630a024177`. The commit must contain the identical implementation,
workflow, test and render blobs. Unrelated changes are excluded.

All required angles are complete: changed hunks and enclosing methods, removed
writers/invariants, cross-file API/FFI/storage/session traces, reuse of existing
arbitration, simplicity, real-time callback safety, root-cause repair depth and
repository conventions. Independent native and runtime reviews, cross-author
model/UI review, four quality roles and root integration review are recorded in
the consolidated review. Generated bindings match the new API; callback code
adds no allocation, locks, blocking I/O or unbounded retry loop.

No unresolved actionable finding remains. Exact refusal rollback, durable
remembered timing, owed cleanup, early preparation guards, snapshot coherence
and actual shutdown Retry/Keep playing were reproduced and repaired. Current
local validation passes with unchanged coverage floors. Comment wrapping and
an equivalent split test name were the only changes after aggregate execution;
strict final static checks cover both.

This is a clean local bug-focused review. PR-readiness and published-head CI must
also be current before ready-to-merge. Human merge and appliance verification
remain separate. Full M5 live-Control recall is not certified by this slice.
