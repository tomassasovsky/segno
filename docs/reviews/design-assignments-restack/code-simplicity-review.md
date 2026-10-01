# M3.1 simplicity review

Scope: the twelve changed M3.1 code, test and configuration paths in `final-hashes.json`, compared with base `0d601db8ec3450afb8ca94071ce96c969ffde1d9`. This includes the independent root Settings default and fuzzer timing amendments. The same reviewer performed these five role passes sequentially and authored none of this delta. Earlier M2.6 package/native work is excluded from the review's authorship claim; unchanged repository and wire code was read only to trace the current contracts. Later assignment UI/action-catalogue work and the pre-existing app overflow are outside this slice.

Binding: the final source snapshot and `final-hashes.json` bind this report. ControlCubit is `3de5752f05393cdcebe5d27e6bea600756ef128a2b6e120d2c78c545c63a5eaa`; its test is `e5f7ecad7f6fd140e66b0ca6692c2354519a7f57bf783922daca7fc0d3f99a1d`. The entire changed diff and relevant enclosing functions/callers were inspected. This is a source review, not an assertion that the eventual remote PR head has green CI.

No actionable simplification or YAGNI finding remains. The implementation is proportionate to two action choices plus fixed/selected resolution and the existing lifecycle obligations.

The pure address resolver switches over the two track-address stages and leaves the remaining stages alone. The assignment factory, parser and copy operation share one small validity predicate for allowed Hold combinations. Explicit invalid values are rejected rather than routed through new fallbacks or migration code.

The existing private gesture object is reused. The shared arm helper removes repeated session/lock checks from every action, while the pressed-button set handles contact deduplication. Restore target, prior value and session are retained only until the obligation is fulfilled or its identity disappears. One outstanding readiness future avoids both duplicated waits and a retry loop. Display memory holds the last successful target with assignment identity, behavior and selection context; removing that state would reintroduce the distinct-Hold LED failure.

No new package, public service abstraction, global transaction or configuration knob was added. The 800 ms change is the accepted default; saved values continue through the existing setting. The bank correction uses the established bankBaseChannel property, not a duplicate bank calculation. No required code deletion is proposed. Existing large ControlCubit organization is not expanded into an unrelated refactor for this bounded slice.
