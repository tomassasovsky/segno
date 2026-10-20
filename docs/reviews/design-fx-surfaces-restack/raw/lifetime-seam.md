<!-- cspell:words xhigh -->

# FX lifetime seam — bounded architecture recommendation

Reviewer: existing independent Astra reviewer at **high**, not xhigh. Requested additional xhigh spawn was unavailable; no new reviewer or escalation effort is claimed. Read-only inspection, no implementation changes, tests or builds. Current held-source hashes are recorded in `lifetime-seam-escalation-source.json`; this is advice about the replacement seam, not approval of the held top-level helper.

## Minimum correct choice

Restore one read-only boolean query on the existing `LooperBloc`, equivalent to the already-reviewed `hasMixGeneration(expected)` contract: true only while the Bloc remains open and its repository's actual `mixGeneration` still equals the expected generation. Add one method-scoped `avoid_public_bloc_methods` exception with its actual reason: this is a synchronous engine/session lifetime guard used after asynchronous UI work, not a command or alternative mutable state API. Keep all mutation through events. Do not disable the rule for the class/file or add a general query framework.

Prefer this boolean guard over a live integer getter. A guard validates a previously captured identity; it does not tempt callers to attach a new engine generation to old displayed chain data. Initial edit and Add capture **must stay `bloc.state.mixGeneration`**, matching the projected chain the user actually selected. The live query is only a final validity predicate before dispatch, during pending receipt cancellation, and after receipt/projection before navigation. Presentation does not import/read `LooperRepository` directly.

Remove the newly injected repository dependency and top-level `currentFxMixGeneration(FxCubit)` helper from the selection-only FxCubit. The helper accesses the Cubit's private repository from the same library solely to move the query outside the linter's member check. It adds no ownership boundary or stronger lifetime contract. This is rule evasion and unnecessary coupling, not a preferable architecture.

## Why the narrow exception is justified

- `LooperRepository.state` is a fresh projection of `_engine.snapshot()` (line1449), while LooperBloc receives `LooperStateUpdated` through its subscription and event queue. The displayed state is intentionally delayed. `mixGeneration` changes on session/device lifecycle invalidation (`_cancelMix`, line642), ahead of a later presentation event.
- Source data and its generation must remain a coherent pair. Replacing an initial projected generation with the current repository generation can admit an old editor's chain into a new session before the next projected state arrives. The dispatch fence would then validate the wrong lifetime.
- The confirmed receipt establishes that its recipe applied in the captured lifetime. Another lifecycle action can occur after receipt completion and before the UI continuation or projection waiter opens an editor. A synchronous check in that continuation must consult the actual owner; projected state alone cannot certify that interval.
- Keeping the check on LooperBloc preserves the existing presentation → Bloc → repository boundary and existing ownership. It creates no mirrored generation state, no subscription, no new Cubit and no persistence owner. Its non-mutating result is narrowly confined to a safety/lifetime question.

The Bloc rule's command-entry intent remains intact: application writes stay explicit events and ordinary UI values remain state. The documented exception exists because a lagged display value cannot substitute for an immediate lifetime validity check. Hiding exactly that query in another library would weaken review visibility without enforcing the intended architecture.

## Alternatives considered and rejected for this bounded fix

1. **Applied-and-published append receipt.** Publishing a fresh repository snapshot before completing an append receipt could remove part of the projection wait, but requires changing the current synchronous handler/unawaited receipt pattern to retain a valid emitter or add a publication event. `LooperStateUpdated` currently emits queued snapshots directly, so ordering against already-queued old snapshots must also be addressed. Monitor publication is owned separately. Most importantly, a reset can still occur between receipt completion and the UI continuation. This changes more behavior and still does not replace the final synchronous lifetime guard.
2. **Mirrored live-generation field/stream or a new state owner.** Adds synchronization and ownership to duplicate an existing repository fact. No necessity for this slice.
3. **Direct repository query in presentation, or FxCubit top-level helper.** The former violates the requested boundary; the latter only disguises the same query while burdening the selection owner.
4. **Return to projection-only checks.** Reopens the proven stale-generation interval. Do not sacrifice runtime correctness to satisfy a syntactic rule.

## Bounded acceptance after the chosen edit

Check source equality of the receipt/append mechanisms and retain prior real-pump evidence. Confirm all initial captures use projected generation and all subsequent live predicates pass that captured value into the boolean query. Confirm closed Bloc returns false. Remove the temporary FxCubit repository/query plumbing and its mock setup. Rerun the strict static gate to verify that only the documented local exception exists; no broad native/package retest is warranted by this query relocation. If runtime expressions change beyond the equivalent query and initial-capture restoration, re-evaluate that delta before reusing behavioral evidence.

Existing receipt and append lifecycle evidence, including the preserved failing→passing capacity case, stays separate from this architecture recommendation. Final whole-candidate readiness still requires exact amended source binding and root gates; this note does not grant publication or merge approval.
