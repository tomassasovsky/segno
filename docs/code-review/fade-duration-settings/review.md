# Fade duration settings review

Issue #1137; base `800ce2ea393dda08d0f2519bb239c7095b1bf02c`.
Human merge gate. This is the duration portion of durable Fade.

Default and explicit per-track durations now persist through startup, Session
capture/recall and shutdown. One application writer confirms stored values,
restores exact previous bytes after failure, and retains repair obligations until
Retry succeeds. Incoming Session settings remain behind the existing boot barrier
until confirmed. Duration changes affect subsequent gestures, not active ramps.

The 34-path final candidate is bound by source freeze SHA-256
`234fab1ff25c03fff19b91d57a6a17f6bcc23a012b57b4dcea56c0265c90ebe7`.
The production change adds 462 lines and removes 9 across 14 files, including
the new immutable model and small writer. No native API, engine owner, generic
transaction layer, dependency or public Fade destination is added. Session schema
10 requires the full vector; no compatibility conversion is introduced.

Root and two independent reviewers covered correctness, architecture, VGV
conventions, test quality and simplicity as grouped roles. Review repaired an
early-error drainage defect, missing Session equality/hash fields, and an
invalid-load test that did not prove capture remained armed. Direct regressions
now prove these cases. A widget fixture explicitly pumps and awaits disposal;
its earlier stalled aggregate remains recorded as incomplete. The final review
has no remaining actionable finding.

Validation: 3,162 app tests pass with 49 conditional skips and 92.671% coverage;
198 settings tests pass at 92.044%; 114 Session tests pass at 95.898%. All
applicable coverage floors pass. Strict analysis, explicit formatting and Bloc
lint covering 811 files pass. The actual-native test observes a running four-second
fade retain its rate after an eight-second duration is saved, then use the new
rate on retrigger, including literal PCM output. Native inputs and the tested
library are unchanged; their prior safety evidence is reused. A final const-only
test change reuses unchanged aggregate inputs with its focused regression rerun.

Actual Claude review, published-head CI and human merge approval remain separate
gates. No appliance, physical controller or listening verification is claimed.
Stationary Fade Session images, reconnect, Clear/history and public controls
remain subsequent parts of the accepted plan.
