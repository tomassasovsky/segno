# Foot Peel: remove the latest overdub layer as a recoverable history entry

<!-- cspell:ignore plog evt lanei hist acks -->

Status: plan for owner review (merging this plan approves its direction); implementation not started.
Tracking: #1164 (parent #1026, M4 operations), `autonomy:merge-gate`.
Source baseline: `origin/claude/fade-duration-targets-1148` (PR #1156),
`c9b420d41cd7312f66ea5f15b0e4ed096d4a87f4`. Precedents: Foot Fade
([plan](2026-10-04-feat-foot-fade-plan.md), parts [1](2026-10-04-feat-foot-fade-part-1-plan.md),
[2](2026-10-04-feat-foot-fade-part-2-plan.md), [3](2026-10-04-feat-foot-fade-part-3-plan.md);
[Clear history](2026-10-05-feat-fade-clear-history-plan.md)) and Foot Reverse
([plan](2026-10-05-feat-foot-reverse-plan.md), PR #1163), whose surface pattern,
decision style and part structure this plan reuses.

## Accepted behavior

- `docs/handoff/segno-app/accepted-behavior.md:305`: "Remove the latest overdub layer,
  preserve the original, disable if none remain, recover through audio history."
- `:160-166` (§2.10): "One audio-edit history per track includes recording, each
  overdub pass, length edits, Peel and Clear. Undo during overdub removes the
  in-progress layer and returns to playback; Redo can recover it. Undo may remove the
  original take and leave empty [...] Peel removes only the newest overdub and
  protects the original. A new audio edit retires its Redo branch."
- `:167-171` (§2.11): grouped Clear All; "Newer dependent audio edits must be undone
  before an older group, rather than overwritten."
- `:461-462, :470` (§6.9-6.10): recall restores "audio/layers/history"; recovery
  accepts audio "including Undo/Redo dependencies".
- `:591`: verification journey "Record -> overdub passes -> Divide -> Peel ->
  Undo/Redo".
- `docs/handoff/segno-app/implementation-map.md:39`: Peel has no named engine entry
  point; "establish each operation's native contract". `:51`: one complete native
  operation at a time.

## What the engine does today (file:line)

History is one tagged stack pair per track, owned by the control thread.

- Entry kinds: `LE_HIST_LAYER` (a retired overdub pass, named by its pool slot) and
  `LE_HIST_CLEAR` (a restore point pushed on top of the layers it erased)
  (`engine_private.h:782-787`). `le_hist_entry` carries `kind`, `slot` and the CLEAR
  payload (`:794-809`); `le_hist_layer(slot)` is the positional initializer every
  C++17 consumer requires (`:810-825`).
- Stacks: `undo_stack[LE_POOL_SLOTS]`/`undo_count`, `redo_stack`/`redo_count`
  (`:905-912`), `LE_POOL_SLOTS = 256` (`:130`). Every entry names a distinct pool
  slot; `track_acquire_slot` relies on that uniqueness to find a free slot and, when
  the pool is full, evicts the lowest non-CLEAR entry (`engine_commands.c:98-140`;
  PR #1161 splits this into the pure `track_select_slot` plus the mutating acquire).
- A LAYER entry is the complete *pre-pass image*: each overdub pass backs up the
  live buffer into an armed shadow slot (`dub_*`, `engine_private.h:914-955`;
  `le_dub_session_start` `engine_process.c:1444-1485`; boundary rotation
  `le_dub_boundary` `:1542-1557`; punch-out drain `le_dub_block_update`
  `:1566-1660`). The pass retires through `LE_EVT_LAYER_RETIRED` (`le_dub_try_retire`
  `:1490-1511`), which the control thread files on top of the undo stack
  (`le_handle_retired`, `engine_commands.c:589-650`) and stages for the performance
  renderer (`le_stage_retired_layer`, `:535-586`). The deepest LAYER entry therefore
  holds the original take; the live buffer holds base plus every pass.
- In-track Undo is a control-thread swap, not a ring command: `le_undo_swap` pops the
  top entry, pushes the old live slot onto the redo stack and republishes `a_live` on
  every lane in lockstep through `le_track_publish_live` (`engine_commands.c:268-274`;
  `engine_core.h:108-120`, the `[R1]` revision bump). Its outcome is the synchronous
  return value; it logs `LE_PLOG_UNDO` (`:2112-2121`). Redo mirrors it (`:2260-2268`).
  Undo of the base take, Redo from empty and Clear restore are the exceptions that
  post state-flip commands (`LE_CMD_UNDO_TO_EMPTY`, `LE_CMD_REDO_FROM_EMPTY`,
  `LE_CMD_RESTORE_CLEAR`) acknowledged through `state_cmds_posted`/`a_state_acks`
  (`le_mark_state_cmd` `:407-412`; handlers `engine_process.c:2835-2907`).
- Undo tapped during overdub punches out and queues the peel (`queued_undo`,
  `:2065-2081`); tapped during the drain it queues (`:2098-2103`) and applies in
  `le_apply_queued_undo` (`:476-500`). Undo during RECORDING cancels the take
  (`:2082-2097`).
- Publication: `le_publish_undo_depth` publishes `a_undo_depth` (zero while the top
  is CLEAR or while a content-giving command is in flight) and `a_clear_restore`
  (`:52-91`); `a_redo_depth` beside it; snapshot fields `undo_depth`,
  `clear_restore`, `redo_depth` (`segno_engine_api.h:843-852`;
  `engine_snapshot.c:105-107`).
- Clear: `le_clear_track` pushes the CLEAR point on top and drops the redo branch
  (`le_finish_clear` `:1247-1275`); the Clear mailbox completes frozen points
  (`le_collect_clear` `:682-732`); `le_restore_clear` moves the point to redo and
  posts the restoration (`:1966-2035`); a fresh capture drops cleared history
  (`le_drop_clear_history` `:314-333`). Every edit drops redo through `le_clear_redo`
  (`:299-304`; punch-in `:990`, fresh capture `:942`, restoration `:392`).
- Loop-close restoration files its raw take as an ordinary LAYER entry
  (`le_restore_commit_layer`, `:394-399`). The API exists (`segno_engine_api.h:2511`)
  but no Dart caller binds it today.
- Multi-lane tracks share one undo span: the same slot index names the snapshot on
  every lane; `le_track_publish_live` swaps all active lanes (`engine_core.h:116-120`).
- Session: the linear timeline `undo_stack[0..undo_count)`, live, then redo top-down
  is exported by image ordinal (`le_layer_slot_for_ordinal`, `engine_session.c:145-160`;
  `le_engine_export_layer` contract `segno_engine_api.h:3039-3053`) and rebuilt by
  `le_engine_import_layer` + `le_engine_finalize_layers(undo_count, redo_count)`,
  which files every ordinal as a LAYER entry (`engine_session.c:184-300`). Capture
  reads `undoDepth`/`redoDepth` (`session_repository.dart:652-695`); import replays
  the ordinals (`looper_repository.dart:4360-4411`); `SessionLane.undoCount/redoCount`
  (`session.dart:60-61, 77-78`).
- Performance log: `LE_PLOG_UNDO = 304`, `LE_PLOG_REDO = 305` (`perf_log_ring.h:52-56`)
  are written but the stem renderer does not replay in-track swaps (it anchors on
  301, 303, 322 and 323 only, `perf_render.c:881-1000`); general replay is #1143.
  events.log is version 5 (`perf_drain.c:803-813`; audited table
  `docs/design/performance-event-log-format.md:201`).
- Dart seam: `AudioEngine.undo/redo` (synchronous `EngineResult`), repository
  `undo()` (`looper_repository.dart:3612-3621`) and `_undoTrack` (`:3656-3686`),
  projection of depths (`:2431-2433`), `Track.undoDepth/clearRestore/redoDepth`
  and `canUndo` (`track.dart:106-121, 225-228`), `Track.layers = undoDepth + 1`
  (`:241-244`) shown by `stageLayersUnit` (`track_column.dart:664`,
  `mixer_column.dart:349`, `wave_track_row.dart:230`).
- Surface precedent: `InteractionMode.fade` (`interaction_mode.dart:46-56`),
  `FootFadeProjection.pedalRoles` (`foot_fade.dart:154-193`), `_FootFadeControl` part
  (`control_foot_fade.dart`), stateless `FootFadeActions` (`foot_fade_actions.dart:
  51-63`), LED (`control_projection.dart:85-104, 253-258`), `TrackOperation.fade`
  and the dispatch arm (`control_action.dart:149-188`; `control_cubit.dart:2910-2916`),
  Tracks composition and toast (`tracks_view.dart:138-146, 209-212`).

## 1. Native contract

### 1.1 Peel versus Undo (design question 1)

Peel consumes the **topmost `LE_HIST_LAYER` entry whose only entries above it are
PEEL entries**, swaps that pre-pass image in as the live buffer, and records the
image it removed as a new history entry. It never touches the original take: the
deepest LAYER entry *is* the pre-first-overdub image, so swapping it in leaves the
original audible and nothing deeper to consume. With no reachable LAYER entry, Peel
is unavailable (`LE_ERR_INVALID`, "none remain").

How this differs from Undo on the same stack:

| Stack state (top last) | Undo does | Peel does |
| --- | --- | --- |
| `[L0, L1]`, live = base + 2 passes | swap in L1 (removes pass 2), pass 2 image to redo | same swap, but files `PEEL(pass 2 image)` and drops redo |
| `[L0, PEEL]`, live = base + 1 pass | undoes the Peel: pass 2 back | consumes L0 beneath the PEEL: live = original |
| `[]`, live = original only | empties the track (redo keeps it) | unavailable |
| `[L0, L1, CLEAR]`, track EMPTY | restores the cleared take | unavailable (track empty) |
| `[L0, RESTORED]`, live = conditioned take | swaps back to the raw take | unavailable: the newest edit is not an overdub |
| capturing / layer in flight | punches out and queues; cancels a take | refused `LE_ERR_NOT_READY` |

Non-overdub kinds above the topmost LAYER block Peel. Today that is only CLEAR
(which also makes the track EMPTY) and the restoration swap, which this plan makes
distinguishable by filing it as `LE_HIST_PROCESSED` instead of LAYER
(`le_restore_commit_layer`, `engine_commands.c:394-399`; Undo and Redo treat
PROCESSED exactly like LAYER). Future length edits (Multiply/Divide, #1026) get
their own kinds and are blocked the same way: a full-length pre-pass image must
never be swapped under a half-length edit. "Preserve the original" is therefore
structural: Peel only ever moves between images that already exist, never allocates
or writes PCM, and stops at the deepest LAYER.

### 1.2 Peel is one history step (design question 2)

New kind `LE_HIST_PEEL = 2` (`engine_private.h:782-787`) with one payload field
`int32_t skipped` on `le_hist_entry` (zero on every other kind, like the CLEAR
payload, `:794-809`). On the undo stack a PEEL entry names the slot of the image
Peel removed (the former live buffer) and `skipped` = how many PEEL entries sat above
the consumed LAYER at peel time. On the redo stack a PEEL entry is a marker with
`slot = -1`.

Motions, all control-thread and all through `le_track_publish_live`
(`engine_core.h:116-120`):

- **Peel** (`le_engine_peel`): find the target with `le_peel_target(t, &skipped)`
  (walk down from the top skipping PEEL entries; stop at the first LAYER; any other
  kind or the bottom means unavailable). Remove that LAYER from its position (shift
  the skipped PEEL entries down by one), push `PEEL{slot = old live, skipped}`,
  publish the LAYER's slot live, `le_clear_redo(t)` (Peel is an edit:
  `accepted-behavior.md:164-165`), republish depths, log `LE_PLOG_PEEL`. The stack
  count is unchanged; every slot stays referenced exactly once, which keeps
  `track_select_slot`'s uniqueness scan valid (`engine_commands.c:98-118`).
- **Undo of a PEEL** (generalize `le_undo_swap`, `:268-274`, which
  `le_apply_queued_undo` and the in-track branch at `:2112-2121` share): pop the
  PEEL at index `p`, insert `le_hist_layer(old live)` at `max(0, p - skipped)`,
  publish the PEEL's slot live, push the marker `PEEL{-1, skipped}` on redo, log
  `LE_PLOG_UNDO`. Inserting below the skipped run restores the exact pre-peel stack,
  so the history stays chronological across repeated peels and later overdubs
  (worked example in 1.7). The relative count is robust to pool eviction: eviction
  removes the lowest non-CLEAR entry (`:118-139`), so the entries between the
  insertion point and `p` can only vanish once nothing lies below them, and the
  clamp to zero then gives the correct position.
- **Redo of a PEEL marker** (`le_engine_redo`, `:2260-2268` branch): pop the marker
  and run the Peel motion without `le_clear_redo`, logging `LE_PLOG_REDO`. By
  construction the LAYER it re-consumes is the one Undo inserted, with the same
  `skipped`.
- Redo-stack effect summarized: Peel empties the redo stack (and `empty_len`,
  `:299-304`); Undo of a Peel pushes one marker; Redo of the marker re-peels. Any
  other edit (overdub, Clear, fresh capture, import) drops markers with the rest of
  the branch, as today.

`le_engine_history_mode_gate` (`:1829`) projects the next undo/redo span per
channel; PEEL and PROCESSED entries are same-span swaps and must be treated as LAYER
wherever it inspects `kind`.

### 1.3 Availability (design question 3)

`le_peel_depth(t)` = number of LAYER entries above the highest entry that is neither
LAYER nor PEEL (the whole stack when there is none). Published as `a_peel_depth` from
`le_publish_undo_depth` under its existing gates (`:66-91`: zero while a frozen Clear
point is pending or a content-giving command is in flight), so an EMPTY track never
shows a peel depth, mirroring the `undo_depth` contract. Snapshot: trailing
`int32_t peel_depth` on `le_track_snapshot` (`segno_engine_api.h:932`), filled in
`le_fill_track_snapshot` (`engine_snapshot.c:105-107`). Dart: `TrackSnapshot.peelDepth`,
`Track.peelDepth`, `Track.canPeel => peelDepth > 0 && !isCapturing && !layerInFlight
&& pendingLaunch == null`, and `Track.layers` becomes `peelDepth + (hasContent ? 1 : 0)`
so the layer badge decrements on Peel (`track.dart:241-244`; PEEL entries would
otherwise keep `undoDepth` constant while a layer disappears).
Note (Part 1 build): the badge therefore counts peelable layers only. Beneath a
non-overdub kind on top of the stack (today `LE_HIST_PROCESSED` after a loop-close
restoration; later the length-edit kinds) `peelDepth` reads 0 and the badge shows
1 while the performer hears the original plus the conditioned or edited passes.
No Dart caller binds `le_engine_restore_track` yet, so nothing shows this today;
it is the badge's intended semantics ("layers Peel can remove"), not a defect.

Control-side admission in `le_engine_peel` (after `le_engine_drain_events`, like
`le_engine_undo` `:2051-2058`): `LE_ERR_NOT_RUNNING` when not configured; `LE_ERR_INVALID`
bad channel or no target; `LE_ERR_NOT_READY` when `clear_restore_pending`,
`cancel_pending`, `a_pending_launch`, `a_layer_in_flight`, a pending state command
(`state_cmds_posted > a_state_acks`), or `le_effective_state` RECORDING/OVERDUBBING
(`engine_core.h:99-107`). No queueing: Undo owns the in-progress layer per §2.10,
and a tap inside the punch-out drain window is refused while the LED is off (1.6).
Nothing is mutated on refusal.

### 1.4 No command, no receipt (design question 4)

Peel is the same class of operation as in-track Undo: a control-thread swap of
`a_live` whose result is known when the call returns. It needs no `LE_CMD_*`, no
callback application, and therefore no slot in the request-receipt table that Fade
owns and Reverse reuses (`engine_commands.c:2281-2334`); the audio thread picks the
new slot up at its next read exactly as it does for Undo. Adding a receipt would
duplicate a confirmation the return value already is (rule 4). Public API beside
`le_engine_undo` (`segno_engine_api.h:1709-1731`):

```c
/* Removes the newest overdub layer as one history entry: the pre-pass image
 * becomes live, the removed image is kept for Undo, the Redo branch is dropped.
 * Never touches the original take. LE_ERR_INVALID when no overdub layer can be
 * peeled; LE_ERR_NOT_READY while the track captures, drains a layer, or has a
 * pending state command, cancel, Clear report or Count-in launch. */
LE_EXPORT int32_t le_engine_peel(le_engine* engine, int32_t channel);
```

Dart: `AudioEngine.peel({channel})` returning `EngineResult` (synchronous like
`undo`, `audio_engine.dart:226-250`), `NativeAudioEngine`, `MockAudioEngine`
(`invalid`/`notRunning`), the four fakes, regenerated bindings.
`LooperRepository.peel({channel})`: `notReady` while `_sessionAudioReserved`
(`looper_repository.dart:3612-3615`), otherwise the engine result; no cache work,
because a layer swap changes no take metadata (`_undoTrack` touches caches only on
Clear restore, `:3656-3686`). Group Clear All is untouched: a peel on a member is a
newer dependent edit and §2.11 says it must be undone before the group; the group's
`_intactClearAllGroup` logic already drops members with newer edits
(`:3616-3618`).

### 1.5 Interaction with capture, Fade, Reverse and #1161

- Overdub in progress or layer in flight: refused (1.3). An armed quantized punch-in
  is allowed, like Undo: the arm's shadows came from `track_select_slot`, which
  excludes every stack slot, so the capture writes into whichever image is live when
  it fires; `le_begin_punch_in` has already dropped redo (`:990`).
- Fade: the envelope lives on `le_track.fade`, independent of `a_live`; a layer swap
  keeps a running fade (the Clear-history oracles, `2026-10-05-feat-fade-clear-
  history-plan.md`, "layer Undo/Redo keeps live Fade"). Peel identical.
- Reverse (#1163): direction is a read transform over `playback_offset`, reset only
  at material transitions (Reverse plan 1.3); a swap is not one. Peel is refused
  while writing, so the reversed-overdub refusal never meets it.
- Capture-prep guard (#1161): it fences fresh capture after a track empties
  (`empty_command`). Peel never empties a track and acquires no slot; the only shared
  code is `track_select_slot`, whose eviction must skip CLEAR as today and may evict
  PEEL and PROCESSED entries (losing one recovery step, never audio the track plays).

### 1.6 Performance log and offline render

- `LE_PLOG_PEEL` takes the next free fact code after Reverse's 324, so 325
  (`perf_log_ring.h:136-143`; renumber at rebase if #1163 has not merged), payload
  `struct { int32_t channel, slot, previous; uint32_t generation; } peel_log;` in
  `le_command` and `le_log_command` (`lockfree_ring.h:99-130`; `perf_log_ring.h:178-195`):
  the slot now live, the slot filed as PEEL, and `dub_generation`, so #1143 can bind
  the fact to the staged layer `{channel, slot, generation}` key (`perf_drain.c:643,
  1234`). Pushed through `le_plog_push_ctrl` (`engine_commands.c:1942-1955`); the
  undo and redo of a peel log 304/305 like every other history path (events.log doc
  `:201`). Bump the events.log header version (`perf_drain.c:803-813`) and add the row
  to `docs/design/performance-event-log-format.md:201`.
- Offline render: the stem renderer does not reconstruct any in-track swap today
  (304/305 are not read, `perf_render.c:881-1000`); Peel changes the live slot
  without changing state, exactly the case #1143 names. This plan records the fact
  with full identity and changes no renderer code; #1143 owns replay for Undo, Redo
  and Peel together.

### 1.7 Worked example (the native oracle)

Base take `1.0`, three passes adding `0.5` (fixture of `test_per_pass_undo_layers`,
`test_engine_core.c:722-760`). Stack `[L0(1.0), L1(1.5), L2(2.0)]`, live `2.5`.

1. Peel: live `2.0`, `[L0, L1, Pa(2.5, 0)]`, redo empty, `peel_depth 2`, `undo_depth 3`.
2. Overdub `+0.25`: live `2.25`, `[L0, L1, Pa, L3(2.0)]`.
3. Peel: live `2.0`, `[L0, L1, Pa, Pb(2.25, 0)]`.
4. Peel: topmost LAYER is L1 with two PEEL entries above: live `1.5`,
   `[L0, Pa, Pb, Pc(2.0, 2)]`, `peel_depth 1`.
5. Peel: live `1.0`, `[Pa, Pb, Pc, Pd(1.5, 3)]`, `peel_depth 0`; a sixth Peel is
   `LE_ERR_INVALID` and the original plays.
6. Undo ×4 restores `1.5`, `2.0`, `2.25`, `2.0` and rebuilds `[L0, L1, Pa, L3]`;
   Undo ×2 more gives `2.5` (`[L0, L1, L2]`) and then `2.0`; Undo to `1.0` and to
   empty; Redo climbs back through every image including the four re-peels.

## 2. History and Session semantics

- Peel is an audio edit: it drops the redo branch, like Clear and punch-in. Undo
  restores the peeled layer; Redo re-peels. Fade and Reverse remain outside the
  history (their plans), and Mixer/FX configuration survives a peel (§2.10).
- Material transitions (Clear, Undo to empty, fresh capture, Session import,
  configure) already drop or rebuild the stacks; PEEL entries die with them. Clear
  on top of PEEL entries keeps them beneath the CLEAR point, so after Clear and Undo
  the next Undo still restores the last peel (`le_finish_clear` `:1251-1258`).
- Session persistence must carry entry kinds. Today's image timeline cannot
  represent a redo PEEL marker (it has no image), and a flat replay would file every
  undo image as LAYER, turning an undone peel into a plain layer swap and a
  restoration swap into something Peel may consume. §6.9-6.10 require recall of
  "history" "including Undo/Redo dependencies". Part 2 therefore:
  - replaces `le_engine_finalize_layers(undo_count, redo_count)` with
    `le_engine_finalize_history(channel, kinds[], skipped[], count, undo_count)`
    (entries oldest undo -> newest undo, then redo top-down, the image-ordinal
    order; image-bearing entries take slot == image ordinal as today,
    `engine_session.c:242-300`; markers take slot -1) and adds the read-only
    `le_engine_export_history(channel, kinds[], skipped[], max)`;
  - makes `le_layer_slot_for_ordinal` (`:145-160`) enumerate image-bearing entries
    only, so `le_engine_export_layer` never tears on a marker;
  - adds `SessionLane.history` (list of `{kind, skipped}`, length `undoCount +
    redoCount`, strict decode: markers only on the redo side, `skipped >= 0`,
    `layers.length == undoCount + 1 + image-bearing redo entries`) at the next
    schema number (12, or 13 if the Reverse Session part lands first; current-schema
    decode only, AGENTS.md), captured at `session_repository.dart:652-695` and
    replayed at `looper_repository.dart:4360-4411`.
  - Note (Part 2 build): a Clear restore point sits on the redo side after Clear
    then Undo. It is persisted as kind `clear` with an image of its own, and its
    Redo re-clears from the live state, which needs none of the CLEAR payload.
    A cleared track is EMPTY and never captured, so `finalize_history` refuses
    a CLEAR on the undo side. The in-memory `SessionRigLane` derives `redoCount`
    from its history instead of storing it twice.
  - Note (Part 2 review, PR #1194). Each finding and what was done:
    - Finding 1 (capture split by the gated depth). `le_engine_export_history`
      now returns the raw `undo_count` through an out parameter, and the Dart
      seam returns one `TrackHistory` value (entries plus that split). Capture
      splits by it, so the published `undo_depth`, which reads 0 while a Clear
      restore is in flight, never meets the raw stacks. The silent
      `continue` on a disagreement is gone because the disagreement can no
      longer happen.
    - Finding 3 (strictness). Both validators (`le_engine_finalize_history`
      and `TrackHistory.malformation`, which decode runs) now also refuse:
      a CLEAR that is not the last entry; a `skipped` of `LE_POOL_SLOTS` or
      more; an undo-side PEEL whose `skipped` exceeds the PEEL run directly
      beneath it; and a redo marker that finds no LAYER when the redo walk
      reaches it.
    - Deviation from the review's wording. The run bound has an exception
      for a run that reaches the bottom of the stack. Pool eviction removes
      the oldest entries and Undo clamps its re-insertion there, so the live
      engine can hold that shape. Refusing it would stop a real save from
      opening (rule 1).
    - The marker's own `skipped` is not checked against the walk, for two
      reasons. Redo recomputes it (`le_peel_target`). After an eviction
      clamp the two legitimately differ.
    - Finding 5 (`SessionLane` shape). `SessionLane.history` is a required
      `TrackHistory`, and `undoCount`/`redoCount` derive from it. The JSON
      keeps both fields, and decode cross-checks the stored `redoCount`.
      `SessionRigLane` carries the same value.
    - Finding 4 (docs). `docs/design/session-bundle-format.md` now describes
      v12 and the current-only rule, keeps the presence-keyed table as
      history, and lists v8-v12. The `SessionCorruptLayers` comment is
      current.
    - Not done here, pre-existing (rule 5, follow-up). A lane whose image
      export comes back short is still skipped without a notice
      (`session_repository.dart`, the `layerPcm.length != total` check).
      The native torn check accepts a stale allocated slot; Dart's decode
      and `applySession` make that unreachable today, and a staged-slot
      bitmask would close it if another caller appears.
    - Not done here, owner decision. Appliance sessions are v7 or older. The
      v7-to-current migration chain is #1196. A v11 bundle becomes v12 by
      giving each lane `history` = `undoCount + redoCount` entries of
      `{kind: layer, skipped: 0}` and keeping `undoCount`, `redoCount` and
      `layers` unchanged. That is exactly how v11 recall filed them, and v11
      capture dropped any track holding a redo marker.
- Reopen (#1158): the stacks are material (its table keeps `undo_count`,
  `redo_count`, `a_undo_depth`, `a_redo_depth` for retained tracks). Peel has no
  pending shape: it completes on the control thread and the only cross-thread
  effect is the `a_live` store the next lifetime reads fresh, so a peel at device
  loss is never a per-track drop and adds nothing to `le_engine_reopen_outcome`.
  `le_engine_reopen_file_retired` files late retire events on top (#1158 hunk), which
  is correct chronology because Peel refuses while a layer is in flight.
- #1159: Peel is not an owned setting family; no `SettingsOwner`, flush or storage
  key. The only shared surface is the `TrackOperation` dispatch switch
  (`control_cubit.dart:2905-2917`) that #1159 Part 3 intends to collapse; Part 3
  here adds one arm and rebases on whichever lands first.

## 3. Surface

- `InteractionMode.peel` (`interaction_mode.dart:46`), excluded from `bootDefaults`
  (`:56`); `toggleMode` returns to `record` from it (`control_cubit.dart:1645-1652`);
  `ModeAction` token `'peel'` (`control_action.dart:339-349`); labels
  `actionModePeel` (`control_action_labels.dart:78`).
- `lib/control/model/foot_peel.dart`: `FootPeelAction {recordPlay, stop, exit,
  peelTrack, nextBank}`, `FootPeelPedal`, `FootPeelTrack {channel, available,
  layers}` with `available = track.canPeel`, `FootPeelProjection {bank, tracks}` and
  `pedalRoles`: track1-4 `peelTrack` immediate (no hold meaning; the Reverse
  precedent for hold-less track pedals), bank `nextBank`, recPlay/stop/mode as Fade
  (`foot_fade.dart:154-193`), undo and clear inert (FX-mode precedent, Reverse
  decision 12). No transient selection: `ControlState` gains only `footPeelFailure`
  (`control_state.dart:21-24, 107-116`).
- `lib/control/foot_peel_actions.dart`: stateless `peel(channel)` over
  `LooperRepository.peel`, returning `invalid` for an unavailable track without a
  notice (`foot_fade_actions.dart:51-63`; `control_cubit.dart:2425` "unavailable, not a
  failure"); shared by the surface and assigned actions.
- `lib/control/cubit/control_foot_peel.dart` part: `_peelEditable`, `_onPeelPress`,
  `_dispatchPeelAction`, `_reportPeelFailure` mirroring `control_foot_fade.dart:
  1-80`; public `footPeelPressed/Released/Cancelled`, `activateFootPeelPedal`,
  `peelFootPeelTrack(slot)` beside `:2398-2433`; `_onPress` routing (`:2618-2625`);
  `recPlay`/`stop`/track/`_onPress recPlay` arms (`:2670-2677` and the sites the
  Reverse plan lists).
- `TrackOperation.peel('peel')` (`control_action.dart:149-176`), label
  `actionOperationPeel` (`control_action_labels.dart:100`), dispatch arm
  (`control_cubit.dart:2910-2916`) through `FootPeelActions.peel`.
  `allowsAllTracks` excludes `peel` like `clear` (`:182-188`): eight edits with eight
  undo steps behind one stomp is the case that rule documents.
- LED truthfulness (design question 6): in `peel` mode a track LED is blue while
  `track.canPeel`, off otherwise (`control_projection.dart:85-104`), so "disable if
  none remain" is visible by foot, including the drain window and capture. Physical
  mask (`:253-258`) generalized to the hold-less modes `{fade, reverse, peel}`;
  `PedalMode.custom` wire mapping (`invariants.dart:152-158`); `pedal_plate.dart:626,
  1051`; themes (`looper_theme.dart:129`, `surface_theme.dart:240`).
- `lib/looper/view/foot_peel_view.dart`: `PerformancePedal` front row and Bank as the
  Fade view, a title, and an eight-track overview cell showing the name and
  `{count} layers` / `Original only` / `Empty`; Exit and Bank B as
  `foot_fade_view.dart:405-410`. Tracks composition (`tracks_view.dart:209-212`),
  failure toast (`:138-146`, `AppToastId.footPeelFailure`), a11y and switch arms in
  `track_column.dart:364-376, 383-405`, `wave_track_row.dart:96, 111`,
  `tracks_commands.dart:122, 225, 313`. The existing layer badge
  (`track_column.dart:664`) already reports `Track.layers`, which 1.3 makes decrement.
- Localization: English and Spanish strings for the mode, operation, pedal captions,
  overview words and failure (`app_en.arb:5901-5984` pattern), generated with the
  existing l10n tooling.

## 4. Parts

Each part is independently mergeable, keeps the public app working and exposes no
unfinished destination. Parts 1 and 2 are unadvertised (no mode entry, no
assignment); Part 3 exposes the journey. Sequence Part 1 after #1158 and #1161 merge
into the stack's base: #1161 owns `track_select_slot`, whose eviction comment and
kind handling Part 1 extends, and #1158 moves the per-track init that Part 1 extends
with `a_peel_depth`.

### Part 1. Native Peel entry and engine seam (about 450 production lines)

Native (`engine_private.h`, `engine_commands.c`, `engine_core.h`, `engine_snapshot.c`,
`engine.c`, `engine_session.c`, `segno_engine_api.h`, `lockfree_ring.h`,
`perf_log_ring.h`, `perf_drain.c`): sections 1.1-1.6 complete: `LE_HIST_PEEL`,
`LE_HIST_PROCESSED`, `skipped`, `le_peel_target`, `le_peel_depth`, `le_engine_peel`,
the generalized `le_undo_swap` and redo branch, `a_peel_depth`/`peel_depth`,
`le_restore_commit_layer` filing PROCESSED, the mode gate's kind handling,
`le_layer_slot_for_ordinal` skipping markers, `le_engine_export_history`,
`LE_PLOG_PEEL`, the events.log version bump and doc row. Dart seam:
`AudioEngine.peel`, `TrackSnapshot.peelDepth`, `NativeAudioEngine`, `MockAudioEngine`,
the four fakes (`test/helpers/fake_audio_engine.dart`, `packages/looper_repository/
test/helpers/fake_audio_engine.dart`, `packages/performance_repository/test/helpers/
fake_performance_engine.dart`, `packages/session_repository/test/helpers/
fake_session_engine.dart`), regenerated and formatted bindings (`ffigen.yaml`),
`LooperRepository.peel`, `Track.peelDepth`, `canPeel`, `layers`, projection (`:2431`).

Tests (`src/test/test_engine_peel.h`, included like `test_engine_fade.h` at
`test_engine_core.c:32969`; literal PCM through `le_engine_process`): the worked
example of 1.7 with constant passes and a patterned partial pass (positions
distinguish images, `test_engine_core.c:764-800`); the sixth Peel refused with the
original intact; `peel_depth`, `undo_depth`, `redo_depth` after every step; Peel
drops a redo branch and `empty_len`; refusals while RECORDING, OVERDUBBING, during
the drain (`a_layer_in_flight`), with a pending Count-in launch, behind an unapplied
undo-to-empty, on a cleared track, and with a frozen Clear pending; Clear over PEEL
entries and Undo of that Clear leaves the next Undo restoring the peel; Peel while
STOPPED stays STOPPED and silent; Peel while PLAYING is continuous at the current
position (the output sample at the swap frame equals the new image there); two lanes
swap together; a multiple of two keeps its multiple; restoration commit files
PROCESSED and Peel above it is unavailable while Undo still swaps it; pool eviction
with PEEL entries (`test_undo_pool_eviction` pattern, `:2065-2092`) keeps every slot
referenced once (an `LE_NATIVE_TESTS` stack-scan seam beside `le_test_fade_hook`)
and Undo of a surviving peel still lands correctly; `le_engine_export_layer` ordinals
skip the marker and return exact images; `le_engine_export_history` lists the kinds;
Fade continues through a peel; the 325 fact carries slot, previous and generation;
C++17 shim compiles with the new fields. One actual-native repository case in
`packages/looper_repository/test/peel_native_test.dart` (fixture of
`fade_native_test.dart:13-45` plus one overdub pass) confirms the synchronous result,
`Track.peelDepth`, `canPeel`, `layers` and that Undo restores the layer.

```success-criteria
GOAL: A checked native Peel removes the newest overdub layer as one recoverable history entry, never touches the original take, publishes truthful depths, and leaves the public app unchanged.
SUCCESS CRITERIA:
- Literal PCM proves the worked example: repeated peels, an overdub between peels, Undo rebuilding the exact pre-peel stacks, Redo re-peeling, and refusal at the original. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Refusals (capturing, in flight, pending command/cancel/Clear report/launch, cleared, nothing to peel) return the specified codes and mutate nothing; eviction with PEEL entries keeps slot references unique. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- The 325 fact and header version are written, export ordinals skip markers, and sanitizer and telemetry-off builds pass. | verify: EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
- Bindings, symbol parity and the Dart seam are complete; the repository confirms a peel and projects peel depth and layer count. | verify: (cd packages/segno_engine && dart run ffigen --config ffigen.yaml && dart format lib/src/generated/segno_engine_bindings.dart && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
- The C++17 shim repro from docs/PROGRESS.md compiles and the ELF symbol check passes on CI. | verify: manual run the PROGRESS shim repro and packages/segno_engine/tool/check_ffi_symbols.sh on the built library.
NON-GOALS:
- Session persistence of kinds, renderer replay (#1143), mode entry, UI, mappings, queued peels, compatibility shims.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/segno_engine && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 2. History persistence and lifetime composition (about 350 production lines)

- Native: `le_engine_finalize_history` replaces `le_engine_finalize_layers`
  (`engine_session.c:242-300`; strict: marker entries only on the redo side, image
  ordinals contiguous, every lane at the same length); bindings regenerated with the
  obsolete symbol removed.
- Dart seam: `AudioEngine.exportHistory/finalizeHistory`, native, mock and fakes.
- Session: `SessionLane.history`, schema bump, strict decode (`session.dart:49-100`);
  capture (`session_repository.dart:652-695`) and import (`looper_repository.dart:
  4360-4411`) carry kinds; `undoCount`/`redoCount` keep counting entries.
- Reopen (#1158 merged): a native test in `test_engine_reopen.h` proves a retained
  track keeps its PEEL entries and markers and that Undo after reopen restores the
  layer; a dropped track loses them with its material.
- Repository: `peel_native_test.dart` gains the round trip: peel, undo, save, recall
  stopped, Redo re-peels and Undo restores with exact first samples.

```success-criteria
GOAL: Peel history survives Session save and recall and a retained reopen with the same Undo/Redo sequence, with no new owner.
SUCCESS CRITERIA:
- The new schema round-trips kinds and skipped counts strictly, rejects malformed history before side effects, and recall rebuilds the stacks so Undo and Redo reproduce the live engine's images. | verify: (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test test/session
- A retained reopen keeps PEEL entries and markers; a dropped take loses them with its material. | verify: bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS='-fsanitize=address -g' bash packages/segno_engine/src/test/run_native_tests.sh
- The actual-native round trip restores the peeled layer after recall with exact first samples. | verify: (cd packages/looper_repository && SEGNO_ENGINE_LIB=<built lib> /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test
- Static gates stay clean. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0' bash packages/segno_engine/src/test/run_native_tests.sh
NON-GOALS:
- Renderer replay, UI, mappings, legacy schema decode, a second history ledger.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh && (cd packages/session_repository && /Users/Tomas/development/flutter/bin/flutter test) && (cd packages/looper_repository && /Users/Tomas/development/flutter/bin/flutter test) && /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

### Part 3. Foot Peel surface and mappings (about 600 production lines)

Section 3 complete: mode, model, actions, cubit part, view, `TrackOperation.peel`,
labels EN/ES, LED projection and physical mask, Tracks composition, toast, pickers,
themes, a11y arms. Tests: `test/control/foot_peel_dispatch_test.dart` (pattern
`foot_fade_dispatch_test.dart:1-60`: immediate dispatch against the current bank,
bank following, stale release, refusal toast once per visit, Exit keeps the peeled
material, an unavailable track is inert without a notice),
`test/control/foot_peel_projection_test.dart` (LED lit only while `canPeel`, off
during capture, drain and when none remain), `test/looper/view/foot_peel_view_test.dart`
with goldens like `test/screenshots/goldens/foot_fade_*.png`, and `track_column`
tests for the layer badge decrementing on Peel. Selected and fixed Peel actions
exercised through the real Custom, CTRL and MIDI ingress; all-tracks refused by the
model.

```success-criteria
GOAL: The accepted Peel surface removes the newest layer by foot or assignment, shows truthful availability LEDs, and never exposes a half-wired action.
SUCCESS CRITERIA:
- Track pedals peel on contact against the current bank, Bank pages, Exit returns to Tracks, Undo/Clear are inert, an unavailable track is inert, and a refused peel shows one notice. | verify: /Users/Tomas/development/flutter/bin/flutter test test/control
- LEDs light only while a track can be peeled; the layer badge decrements; goldens match in English and Spanish. | verify: /Users/Tomas/development/flutter/bin/flutter test test/looper/view
- Selected and fixed Peel actions reach the same adapter from pedal, CTRL and MIDI ingress; all-tracks Peel is not offered. | verify: /Users/Tomas/development/flutter/bin/flutter test
- Static gates and the whole app suite pass. | verify: dart analyze --fatal-infos lib test packages && bloc lint lib test packages && /Users/Tomas/development/flutter/bin/flutter test
- Physical footswitch, LED and listening proof on the appliance: peel during playback and while stopped, peel to the original, Undo and Redo of a peel, refusal during overdub. | verify: manual appliance session per docs/PROGRESS.md hardware evidence rules.
NON-GOALS:
- Queued peels, hold gestures, new owners, native changes beyond label plumbing.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/flutter test && dart analyze --fatal-infos lib test packages && bloc lint lib test packages
```

## 5. Decisions taken under the standing rules

1. Peel is a history entry (`LE_HIST_PEEL`): Undo restores the peeled layer, Redo
   re-peels, Peel drops the redo branch. §2.10 lists Peel among the entries beside
   each overdub pass and Clear; "recover through audio history" is Undo. Rules 2 and 3.
2. Peel consumes the topmost LAYER reachable through PEEL entries only, so the deepest
   LAYER (the original) is never consumed and any non-overdub kind above blocks it.
   Rule 2: "preserve the original" by construction.
3. The restoration commit files `LE_HIST_PROCESSED`, which Peel never consumes and
   Undo/Redo swap as before. Rule 3: a conditioning swap must not peel as a layer.
4. Peel is a control-thread swap like Undo: synchronous result, no command, no
   receipt. Rule 4 over a duplicate confirmation path.
5. Refused while capturing, during the drain, and behind any pending state command,
   cancel, Clear report or Count-in launch; never queued. Rule 2 and 5: the
   in-progress layer is Undo's, and a refusal is visible as an unlit LED.
6. A pending quantized punch-in does not block Peel, matching Undo. Rule 1.
7. Pool eviction may evict PEEL and PROCESSED entries (never CLEAR); the relative
   `skipped` count with a zero clamp keeps Undo exact. Rule 2: eviction costs one
   recovery step, never audible material.
8. Availability is published as `peel_depth`; `Track.layers` derives from it so the
   badge stays truthful. Rule 3.
9. Session persists entry kinds and skipped counts at a new schema; current-schema
   decode only. Rule 3 and §6.9-6.10; rule 1 unaffected (no existing install holds
   peels).
10. No pending shape at device loss; Peel adds nothing to #1158's drop table. Rule 5
    is satisfied because nothing is uncertain.
11. Renderer replay of in-track swaps stays with #1143; Peel logs 325 with slot,
    previous slot and generation so that work can bind it. Rule 4.
12. `allowsAllTracks` excludes Peel like Clear. Rule 3 and 4.
13. LED blue while a track can be peeled; Undo/Clear inert in the mode; track pedals
    act on contact. Rules 3 and 4.
14. Not an owned setting family (#1159). Rule 4.

Genuine product-direction questions, flagged separately (defaults above stand until
the owner says otherwise):

- Confirm Peel as a history entry (Undo restores the peeled layer) rather than a
  protected Undo whose recovery is Redo. The latter removes Part 2 almost entirely
  and makes Peel-then-Undo remove a second layer.
- Should Undo in Peel mode undo the most recent peel on some track, or stay inert?
- Should a Peel tapped inside the punch-out drain window (under half a second) queue
  like Undo instead of being refused while the LED is off?

## Collisions and sequencing

- #1161 (capture-prep guard): both edit `track_select_slot`/`track_acquire_slot`
  (`engine_commands.c:98-140`) and `le_record_impl`'s neighborhood. Land Part 1 after
  #1161 and keep one selection policy.
- #1158 (reopen): Part 1 adds `a_peel_depth` to the per-track init that #1158 moves
  into `le_engine_reset_material`; Part 2 adds the reopen test. Rebase after it merges.
- #1163 (Reverse): fact code 324 and Session schema 12 are claimed there; Peel takes
  325 and the next schema; the physical LED mask generalization is shared. Whichever
  Part 3 lands second rebases on the other's switch arms.
- #1159 (settings owner): only the `TrackOperation` switch arm.
- #1143 (history replay): Peel's fact is designed for it; no renderer change here.
- Review ceiling per part: 700 production lines; generated bindings, tests and docs
  counted separately. Stop for review on any new command or receipt, a queued-peel
  mechanism, a second history ledger, a new Dart owner or a renderer change.
