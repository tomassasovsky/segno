# M3.5 independent bounded adversarial review

Verdict: complete for the released wire/physical-renderer and app/repository oracle, with no unresolved actionable findings. Existing Astra high reviewer, independent of implementation authors. Bound to base `3e67d031148f21eb9c3ee99a961f6ca4587dbc3b`, incoming `424e12d0e53a969f8887089be0ea9450404be969`, final69-path freeze-v2 fingerprint `57dcdae120419b771c9bf8ad43d7cd9c976ccaf39ce28a7cf18e884c78ffef2c`. Publication/exact-head and remote CI remain separate.

## Binding and observed evidence

All69 final source/test paths match freeze-v2. All production inputs remained unchanged throughout execution. Before/after drift is limited to two root-owned test amendments: repository cascade lint and the Clear fixture's actual positive-length audio plus empty-rig refusal neighbor. No production change or probe expectation change was needed. Native/codec fingerprints match the earlier released builder scope. Exact hashes, logs and limits are recorded in `protocol-results.json`, `final-adversarial-binding.json`, and before/after manifests.

Executed independent evidence totals: one C literal executable, one actual-sketch pixel executable, two Dart codec/value tests, and eight app/repository cases across focused runs. Fixed oracle/v8 literal bytes were prepared before implementation. The protocol/rendering results are detailed in `protocol-review.md`; no duplicate firmware or audio suite was run.

## App and repository outcomes

1. Literal HELLO6/7/9 are incompatible;8 alone enables inputs/STATE. Repeated state deduplicates, each valid HELLO replies, timeout/reconnect preserves liveness without replaying old inputs.
2. Custom RecPlay/Stop/Undo/Clear independently assigned to four fixed Mute targets start dark. Four successful toggles yield exact mask0x10f including fixed Mode; authoritative external unmute clears only Stop. Bank B adds its fixed bit while shared transport state persists.
3. Distinct Press Record/Hold Selected Mute executes Hold only. During its completed contact, the lamp stays attached to the fired target after selection changes. After release it follows the current selected target's actual state.
4. A real pending native mix causes repository Record refusal. A refused Press cannot replace the prior accepted Hold identity: its true Mute lamp remains true after release. A separate first-contact refusal with no prior identity stays dark during contact, after callback draining and after release; no phantom record completion occurs.
5. A GUI durable write stalls an earlier Custom Solo admission. A newer Hold Mute completes on the same physical button. The later successful Solo receipt does not overwrite the newer Hold identity; turning Mute off darkens the lamp even though Solo is on.
6. A normal accepted Stop contact lights while held. Protocol mismatch clears that contact before projecting the next frame; reconnection and an unmatched old release do not revive it.
7. PedalRepository stores/publishes the exact canonical frame without requiring a connected board. PedalCubit initializes from that object and mirrors subsequent hue-only and mask-only changes; duplicates do not emit. Explicitly awaited close publishes goodbye and releases the link.

The two refusal cases use the real frozen engine/repository pending-mix gate, not an always-rejecting fake. Async ordering uses one actual shared MixSettingsCoordinator and a bounded store barrier. Expected masks/booleans/targets are literal oracle outcomes; they do not call projection/invariants helpers.

## Source coverage and fixture disposition

Reviewed the changed Custom admission/completion path, accepted-contact cleanup, exact per-press/setup/session fences, canonical frame stream and PedalCubit lifecycle, plus the earlier firmware/codec/value/renderer changes. Traced actual Layout A from PedalCubit.state.frame through PedalSetupMap to frame.isLit/colorFor; selection decoration remains separate. Layout A itself was not independently widget-executed here; root/peer own that visual/UI evidence.

The first app run retained one fixture failure after its stream assertions passed: an unawaited PedalCubit.close inside FakeAsync had not completed when goodbye was asserted. The original is preserved in `app_led_oracle_fixture_v1.dart` and `app-v1.log`. Only that case was changed to real asynchronous execution and explicit `await close`; original goodbye/link-disposal expectations pass in `stream-close-v2.log`. Six earlier passing cases were not repeatedly rerun. The added first-contact refusal neighbor passes in `record-refusal-v1.log`. This is a fixture correction, not a product repair or sensitivity demonstration.

No private harness entered the checkout, no product/test/Git edits, no native audio rebuild, no broad suite duplication. No mutation or parent-red evidence is claimed. The host pixel checks prove logical addressing and fixed arithmetic, not physical gamma appearance, power draw or PIO timing; symmetric diffuser output cannot independently reveal per-group reversal, which is source-reviewed. Full ring animation/Arduino compilation and aggregate app/static/coverage remain root/peer evidence. Palette add/edit/reuse, draft preview/Save and dangling-reference behavior remain the separate1032 slice. No hardware flash, appliance certification or final CI claim.
