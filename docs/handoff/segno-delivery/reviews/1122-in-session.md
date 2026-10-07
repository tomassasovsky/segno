Model: Claude Opus (subagent), in-session; no earlier Claude verdict exists for this packet
Base: 659792cafed98f341b208f42353a12b0f2b29e4c
Head: e160b677ae222a6ef8558c321e3e5cc0504496dc (Segno PR #1122, shared Count-in mappings, #1121/#1026 part 3)

# Verdict

Mergeable after an owner decision on finding 1 (Low). I traced no defect that loses a durable value, saves the Held value, replays stale contacts into a new lifetime, or lets a refused write take priority. The runtime change is a close copy of the reviewed Hear click (ClickMode) pattern: lifetime and ordinary revision, an optional Released pair carried through the repository receipt and recovery, and the shared holder ledger. The deduplication of the four `_supersede*Claims` helpers into one `_supersedeParameterClaims`, and of `ClickModeEndpointChoice` into `NamedValueEndpointChoice`, preserves behaviour. I compared the deleted bodies line by line.

# What I traced

- `TempoSettings._writeRecordStart` (lib/looper/application/tempo_settings.dart:584-711). Controller writes are fenced by both the captured lifetime and `_startRevision`. Only accepted ordinary writes increment the revision and publish on `_ordinaryStart`, so refusals gain no priority. The preference stores `durable`, the native pair receives `next`, and the repository receives both atomically. The pair algebra (`withCountIn`, record_start.dart:36) matches the plan's literal cases: prior Sound on with Held 2/Released 0 gives live (2,false) and saved (0,false); Held 0/Released 2 gives live (0,true) and saved (2,false). The ordinary Count-in and Sound derivations are equivalent to the base formula.
- Repository (looper_repository.dart:7281-7420). `_recordStartRestart` changes only on an acquired receipt, a stopped-engine stage or explicit recovery. A refusal leaves both values unchanged. An uncertain result records `{settings, restart}` for recovery. Startup and reconnect replay `_recordStartRestart` (2564). `replaceSession` restores without a Released pair, so restart equals settings there. Every lifetime retirement (stop, reconnect, start, replace) increments `mixGeneration`, so `ControlCubit` supersedes old claims (control_cubit.dart:3245-3249).
- Session Save and Save As run inside `runTempoExclusive` and read `durableRecordStartSettings`, which is the receipt-confirmed Released pair. Shutdown already flushes and recovers `recordStart` (app_runtime.dart:178, 216). The owed-release eligibility tuple gained the record-start capture, settled and ready flags (control_cubit.dart:1296-1298).
- External and MIDI dispatch for Count-in mirror the ClickMode blocks: origin capture, removal of stale-origin work, `_survivingMidiReleased` for cleanup, held/requested Released, and `_retireMixBaseline` on accepted holds. The ordinary holder is removed by `_retireMixBaseline` on a later accepted press, which is why "ordinary before press does not override authored Released" holds.

# Findings

## 1. Low (introduced exposure): a stale invalidation drops the authored Released after a refused Held, but only when the session has seen any earlier touch edit

- Path: control_cubit.dart:279-281 (the new ordinary listener calls `_supersedeParameterClaims` on every accepted Count-in or Sound edit). control_midi.dart:1412 adds `CountInValueTarget` to `_externalInvalidatedMix[input]` for every pedal input. The only place that clears it is control_cubit.dart:899, inside `recordParameter`, which runs only after an accepted Held. control_cubit.dart:780-788 removes the target from a `held == false` write while the invalidation is present.
- Trigger: the user changes Count-in or Sound from Loop settings at any point in the session. Later, an External Count-in button's Held is refused (pressed during record/overdub capture lock, an engine refusal or recovery). The user releases after capture ends.
- Result: the Released write is removed and Count-in stays at its prior value. Without the earlier touch edit, the same gesture applies the authored Released. That is the behaviour `count_in_dispatch_test.dart:430-447` ("capture refuses Held; eligible physical release keeps its semantics") and `:558` assert. So the outcome of one physical gesture depends on unrelated session history. The existing tests do not catch it because the rig takes its initial (1,false) from stored preferences, not from an ordinary write.
- Scope: the sticky-invalidation mechanism already exists. Decay, one-shot, length and timing supersede on ordinary "clear override" edits, and ClickMode supersedes on lifetime changes. This PR makes it reachable through the most common Count-in action.
- Smallest correction: clear `_externalInvalidatedMix[input]` for the row's targets at the physical Held edge, synchronously in the external edge handler before `_queueExternalWrite` (control_cubit.dart, around 657). Do not wait for acceptance. A press that started before the ordinary edit is still invalidated, because the ordinary edit adds the invalidation after the press cleared it. A new gesture after the edit keeps its Released semantics. Add the missing test: `r.ordinary(2)`, bind, capture, Held, end capture, Released, expect live (0,false) for External. If the owner instead wants "a refused Held never releases", that is a change of the asserted semantics and belongs in the tests, not in a sticky flag.

## 2. Nit (unnecessary complexity): `NamedValueEndpointChoice` takes any `ControlValueTarget` and throws at build time for the wrong kind

- named_value_endpoint_choice.dart:28 and :96 (`_ => throw ArgumentError`). The callers also repeat the target-kind dispatch to build `keyPrefix` (midi_control_cards.dart:342-344, 356-358).
- Simpler: pass the `(key, label, normalized)` choice list from the call site, or derive the key prefix inside the widget from `target`. Either removes the runtime throw and the duplicated ternaries. The `selected` index (`(value.clamp*3).round()`) also restates `toDomain`.

## 3. Nit: duplicated arms

- expression_catalogue.dart:484-488 repeats the ClickMode arm. Merge it with `ClickModeValueTarget() || CountInValueTarget() =>`.
- expression_controls_panel.dart:317-322 repeats the `is ClickModeValueTarget || is CountInValueTarget` predicate twice in `_endpoint` after `_range` already computed it. A small `isNamedChoice(target)` helper would cover the three uses.

# Preexisting debt (not introduced; optional)

- Every new value target needs one more `target is X ||` arm in about 10 places in control_cubit.dart and control_midi.dart (for example 669-672, 783-786, 903-906, 1236-1240, control_midi 804-807), plus a copied origin and dispatch block (control_cubit 1205-1230 duplicates the ClickMode block at 1179-1204; control_midi 1086-1115 duplicates 1056-1085). This PR follows the pattern faithfully. One predicate (`_isSettingTarget`) and a per-target origin/write strategy would remove this growth, but that refactor belongs in a separate change.
- `stopEngine` reverts click volume to its restart value but leaves live ClickMode and Count-in at a held value while the engine is stopped. The UI shows the held choice until the next start replays Released. This matches the ClickMode precedent and is not new.

# Unverified hypotheses / proof limits

- A Count-in release that arrives during an active countdown (not capture-locked; `recordStartCaptureLocked` is only recording or overdubbing) changes the pair mid-countdown. I could not verify the native result ("never launches or restarts a canceled countdown") because the native engine is omitted from the packet. The only real-native coverage is `count_in_session_shutdown_test.dart` and `count_in_dispatch_test.dart:631+`, both gated on `SEGNO_ENGINE_LIB` and tagged `fuzz`. Per test/fuzz/README.md, CI runs those in its fuzz job.
- Every Count-in move on a non-held controller (an expression pedal sweep) performs two preference writes and one native receipt round trip, serialized on the tempo queue. ClickMode does the same. I did not measure latency under a fast sweep.

# Test quality

The dispatch and transaction tests drive the real `TempoSettings`, `LooperRepository` and `ControlCubit` with a fake engine. They assert live, durable and stored pairs separately, which are observable outcomes rather than source-shaped checks. The repository receipt tests separate live from Released across acquired, refused and uncertain receipts. Gap: finding 1's sequence (an ordinary edit before a refused Held) is not covered.

# Scope and completeness

I read all of `change.diff` except `docs/code-review/shared-count-in-mappings/review.md`, which I deliberately did not read; the golden PNGs were not inspected. I also read the relevant head sources: TempoSettings record-start and ClickMode paths, the LooperRepository record-start receipt, recovery and lifetime retirement, the ControlCubit external dispatch, survivor and supersede helpers and eligibility tuple, the MIDI dispatch for ClickMode and Count-in, session capture, app shutdown, `external_pedal_page` endpoint defaults, and the plan and AGENTS.md. Test files I skimmed rather than read line by line: the screenshot tests, the page tests, and the fixture-only updates to existing tests. No code was built or run, and there was no hardware or runtime validation.
