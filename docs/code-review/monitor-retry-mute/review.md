# Monitor recovery Retry and mute ordering

Issue #1132. Base `6bf1ef006026b23b65d88f8b65322627d6f232d9`,
branch `codex/monitor-retry-mute`; human merge gate.

Retry could read an obsolete saved mute, overwrite a newer accepted change, and
sometimes persist that obsolete value. Three independent orderings reproduced
the problem; an otherwise identical serialized control passed.

The repair reuses the existing Mix exclusion. Retry drains already-admitted
FX/scalar writes before reading settings. Ordinary mute requests are visibly
refused while restore or recovery owns that boundary, and can be retried after
it finishes. No new queue, state owner or deferred toggle intent is introduced.

Root reviewed every changed production hunk and regression, including native
admission before persistence, synchronous exclusion, Session/close cancellation,
failed writes and unchanged routing/FX. The independent review found no actionable defect after tracing cross-owner
waits, shared callers, architecture, test quality and simplicity. Seven source
files are bound by freeze SHA-256
`c42bc2ad126734f45e478ec5a1804ba76f180f4e35f55fc199469b6a68583e69`.
Actual Claude review remains pending quota.

Focused checks pass 195 tests with no skips. The regression suite includes
pending storage, a pending FX receipt, a new mute during Retry, storage failure,
closed/replaced ownership, and visible pedal refusal without delayed replay.
The full app passes 3,146 tests with 49 inherited conditional skips and
92.636% coverage (90% required). Full strict analyzer, explicit-file formatting
and diff checks pass; Bloc lint scanned 805 files with zero issues. All seven
frozen source hashes and the reused native library remained unchanged.

Current-head CI, complete review and human merge approval remain separate gates.
This changes Dart coordination only; it does not claim hardware validation.
