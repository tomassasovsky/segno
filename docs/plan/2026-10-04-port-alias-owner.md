# Port alias ownership

Issue #1110, following the application ownership correction in #1111.
Implementation is authorized; merging remains human gated.

Input and output naming duplicate device-lifetime, storage ordering and rollback
logic in presentation Cubits. Move that logic into one concrete application
owner for each input/output namespace, leaving the Cubits as view adapters.
Preserve per-device names, independent port edits, same-port ordering, exact
rollback, uncertain-key retry and stale-view refusal. Explicitly clearing a name
after an initial read failure must remove its persisted key.

The production cut has four paths and removes 89 lines overall. Keep the
existing input/output Cubit tests unchanged and add direct owner cases for
ordering, failed initial load, mutation before failure, failed compensation and
closure during admitted storage. There are no new dependencies, compatibility
paths, native changes or visual changes.

Verify the exact applied patch with focused tests, app coverage, strict analysis,
explicit formatting and a nonempty Bloc scan. Review the complete delta and
removed invariants independently. Current-head CI and clean review are both
required before ready-to-merge; neither permits an automatic merge here.
