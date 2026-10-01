# M3.1 VGV review

Scope: the twelve changed M3.1 code, test and configuration paths in `final-hashes.json`, compared with base `0d601db8ec3450afb8ca94071ce96c969ffde1d9`. This includes the independent root Settings default and fuzzer timing amendments. The same reviewer performed these five role passes sequentially and authored none of this delta. Earlier M2.6 package/native work is excluded from the review's authorship claim; unchanged repository and wire code was read only to trace the current contracts. Later assignment UI/action-catalogue work and the pre-existing app overflow are outside this slice.

Binding: the final source snapshot and `final-hashes.json` bind this report. ControlCubit is `3de5752f05393cdcebe5d27e6bea600756ef128a2b6e120d2c78c545c63a5eaa`; its test is `e5f7ecad7f6fd140e66b0ca6692c2354519a7f57bf783922daca7fc0d3f99a1d`. The entire changed diff and relevant enclosing functions/callers were inspected. This is a source review, not an assertion that the eventual remote PR head has green CI.

No unresolved actionable VGV finding remains in the reviewed source.

The new immutable assignment fields participate in equality and serialization. Direct construction and copy updates reject forbidden Press/Hold pairs; persisted malformed explicit tokens reject the record. Clearing Hold resets its otherwise meaningless metadata. Omitted fixed scope is the current compact format, with no new compatibility layer or migration. The non-const constructor's affected fixture preserves the same stale-target expectation.

ControlCubit keeps dispatch and lifecycle behavior behind repository calls. Timers cancel on invalidation and close; a firing-time session/lock guard is shared by bound and system holds. Duplicate contacts do not recapture momentary state. Native admission is checked before declaring a successful toggle or adding a held restore. Equal-valued session bindings still invalidate pending gestures.

The LED repair reads the last successful function target while it belongs to the actual assignment; active-bank offsets match the wire renderer. Tests exercise both the dark Bank B target and its later lit state, rather than only an internal physical-button index. No dependency, framework or suppression was introduced. The added state tracks concrete contact, restore and display obligations; there is no speculative general-purpose dispatch layer.

Meaningful tests and independent failure-path probes accompany the changes. See `test-quality-review.md` for execution ownership and remaining gate limits. All original review failures remain recorded; no success claim is based solely on author tests.
