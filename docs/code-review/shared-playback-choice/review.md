# Bug-focused gate: shared Playback Loop or Once

Base `f186bb952d1d000522c5e8e55226bc2ee0931538`; reviewed working revision is
bound by `docs/reviews/shared-playback-choice/source.json`, fingerprint
`d8ceaa9043a2050772f4f953c646ac326010af35159b50702c18e88924f81faf`.
This includes all new implementation, tests and renders. The final commit must
contain these identical blobs. Documentation and saved Pen are separately
bound; unrelated analyzer configuration and old raw reviews are excluded.

All eight angles are complete: changed hunks and enclosing functions, removed
direct writers, Control-to-owner-to-storage/native traces, reuse of established
control arbitration, simplification, queue/lifetime and real-time boundaries,
root-cause fix depth, and repository/VGV conventions. The independent reviewer
read all changed product and tests, then reviewed the seven late fixture
changes against the executed binding. Product, oracle, harness and native
library remained unchanged, so the independent matrix was not rerun needlessly.

No unresolved actionable finding remains. Retry validation and restart during
startup reads were reproduced before correction. Final gates: 2,666 ordinary
app results, 686 Looper results, unchanged-source Settings/Controller evidence,
50 independent probes, an intended receipt-bypass failure, actual App and
serialized-session checks, reused unchanged standard native tests, 733-file
static checks, author-only renders, actual desktop UI and saved Pen references.
Counts overlap where described and are not summed into one completion claim.

This is a clean local bug review for these source blobs. Exact-head remote CI
and human merge approval remain separate. Physical controllers, appliance
timing and OS halt were not exercised. Full Session Load with a live Control
owner remains the inherited M5 item. The independent execution record states
omitted permutations; Save and owner adoption alone are not full recall proof.
