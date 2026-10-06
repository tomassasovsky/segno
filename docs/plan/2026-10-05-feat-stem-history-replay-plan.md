# Replay ordinary audio-history changes in performance stems

Tracking: #1143 (parent #1026), `autonomy:merge-gate`, human merge gate.
Status: plan approved with required review edits E1-E8, which are applied in
this text; Part 1 built on branch `claude/stem-history-replay-1143` (the build
record at the end lists where the build departed from the amended text and why).
Base: `origin/claude/manifest-failure-1144` at `cee9685ac` (PR #1155, stacked on
#1145 `codex/fade-clear-history` `270209fbc`). Unless a branch is named, every
`file:line` below is on that head. Precedent:
`docs/plan/2026-10-05-feat-fade-clear-history-plan.md` and its
captured-restoration amendment; format:
`docs/design/performance-event-log-format.md`.

## 1. Problem and current boundary

A layer Undo or Redo is a control-thread swap of `a_live` (`engine_commands.c:268-274` `le_undo_swap`, `:2242-2249` redo swap, `:2205-2240` redo-from-empty, `:1971-2035` `le_restore_clear`), all funneled through `le_track_publish_live` (`engine_core.h:116-120`). The audio thread reads the new slot at the next frame (`engine_process.c:5287-5291`). The only logged record is the control-side `LE_PLOG_UNDO`/`LE_PLOG_REDO` (304/305, `engine_commands.c:2118-2119`, `:2247-2248`), stamped within one buffer and naming neither the PCM nor its first audible sample. The offline renderer ignores 304/305 entirely (`perf_render.c:908-1061` handles only 322/323, `RECORD_END`, `LAYER_RETIRED` and `LE_CMD_CLEAR`), so after an ordinary swap it keeps playing the previous image and reports success.

#1142/#1145 closed this for Clear restoration only: the control thread stages an immutable copy of the retained slot (`engine_commands.c:1995-2002` -> `le_stage_retired_layer` `:535-587`, kind 1, `restore_id`), the callback publishes `LE_PLOG_CLEAR_RESTORE` (322) at the exact mixer frame and `LE_PLOG_RESTORE_TRANSPORT` (323) for later state/phase changes (`engine_process.c:5369-5390`), and any later same-span swap ends the source with `323/0`, failing the stem (`:5375-5378`, `perf_render.c:919-924`). `test_fade_restore_history_replacement` (`test_engine_fade.h:701-729`) and `test_fade_restore_source_end_edges` (`:795-821`) currently assert that failure.

This plan generalizes that mechanism to every callback-applied history transition. No second transport or history state machine: the existing control-side history (`undo_stack`/`redo_stack`, `engine_private.h:909-912`), the existing staging ring and drain (`layer_staging_ring.h:51-61`, `perf_drain.c:860-918`) and the existing renderer segment builder (`perf_render.c:660-728`) remain the only owners.

## 2. Provenance model

### 2.1 Definitions

- **Image**: an immutable copy of one pool slot's PCM across the track's active lanes, written by the drain as `restore-<channel>-<id>.pcm` and listed in `performance.json` `layers` with `kind: 1` and a capture-local nonzero `restore_id` (`perf_drain.c:863-865`, `:904-916`). Wire names stay; the doc redefines `kind 1` as "callback-applied immutable source image" regardless of whether the admission was a Clear Undo, a layer Undo/Redo or a Redo-from-empty (decision D1).
- **Admission**: the control-thread operation that will change which slot is live. Before it publishes `a_live`, it stages the target slot and records the image id for that slot in a new per-capture table `perf.slot_image[LE_MAX_TRACKS][LE_POOL_SLOTS]` (`_Atomic uint32_t`, 8 KB, zeroed with `engine->perf` at configure `engine.c:363` and at arm `engine_commands.c:4095-4125`). Staging refusal stores 0 in the table and counts `a_perf_layer_overruns` as today (`:567-586`).
- **Application**: the frame at which the callback first mixes the new slot while the track is PLAYING or STOPPED. The callback identifies the image by reading `slot_image[t][a_live]` at that frame and logs it. Nothing control-side is ever interpreted as the application frame.

### 2.2 Callback state (replaces `perf_restore_*`, `engine_private.h:977-978`)

Per track, audio-thread-local: `perf_source_slot` (-1 = none; the lane-0 slot the stem currently reproduces), `perf_source_id` (0 = snapshot/kind-0 provenance, nonzero = staged image), `perf_source_state`, `perf_source_next_pos`. Rules, evaluated once per frame per track while `e->perf.armed` at the existing site `engine_process.c:5369-5390`.

Application boundary (review E2, as built; see the build record): `mix_tracks_frame` loads `lanes[0].a_live` ONCE per frame per track with acquire into `live_idx[t]`, for every track including idle ones; the mixer's `buf[t][0]` and the tracker both use this value, so a fact can never name a slot the mixer did not mix at that frame, and the relaxed lane-0 load at `:5289` is replaced by this load. (The review described the load as once per block; the code loads it per frame, inside `mix_tracks_frame`, which `le_engine_process` calls from its per-frame loop at `:6252`/`:6302`.)

1. State PLAYING or STOPPED and `live0 != perf_source_slot`: set `perf_source_slot = live0`; `id = slot_image[t][live0]`. If `id != 0`: `perf_source_id = id`, `perf_source_state = -1` so the next step emits 322 `{channel, id, state, phase}` at this frame, `phase = trk_play_pos % len` as today (`:5372`). If `id == 0`: emit `323 {channel, 0, EMPTY, 0}` unconditionally (a slot became live without a staged image; provenance is lost whether the previous source was an image or the arm snapshot), then `perf_source_id = 0`. (E1.)
2. State PLAYING or STOPPED and slot unchanged, `perf_source_id != 0`: emit 323 on state change or phase discontinuity exactly as today (`:5380-5387`).
3. State RECORDING or OVERDUBBING: if `perf_source_id != 0` emit `323/0` (uncaptured material, unchanged policy) and set `perf_source_id = 0`; set `perf_source_slot = live0` so the written slot is the current snapshot-provenance source and no table lookup happens at `RECORD_END`. As built, additionally: if the slot changed and `slot_image[t][live0] != 0`, emit `323/0` too (a staged image overwritten before it was ever mixed PLAYING or STOPPED: a restore, Redo-from-empty or layer swap followed by Record in the same block; see the build record).
4. State EMPTY: no fact here. Every material reset (`le_fade_reset`, `engine_process.c:189-195`, reached from `handle_clear` `:2135`, `apply_undo_to_empty` `:1857`, void finalize `:1318`, fresh record `:1751`/`:1768`, `LE_CMD_RESET_FADE` `:2988`) sets `perf_source_slot = -1`, `perf_source_id = 0`. Safe for `LE_CMD_RESET_FADE` (82) because 82 is only pushed on EMPTY tracks (`engine_session.c:136`, `:292`); a future non-EMPTY caller must not reset provenance (E8). `apply_undo_to_empty` additionally logs the raw `LE_CMD_UNDO_TO_EMPTY` (39) at the exact apply frame (section 3). `le_perf_restore_end`'s `323/0` is no longer emitted from `apply_undo_to_empty` (`:1856`): emptying is exact silence, not lost provenance.
5. `LE_CMD_PERF_ARM` (`:3643`): `perf_source_slot = EMPTY ? -1 : a_live`, `perf_source_id = 0` for every track, so the arm snapshot stays the provenance of content that was already live, and anything that becomes live later goes through the table.

### 2.3 Which fact identifies which image for each operation

| Operation | Admission (control, before publish) | Application fact |
|---|---|---|
| Layer Undo (`le_undo_swap`) | stage `undo_stack[top].slot`, len `a_len`; `slot_image[ch][slot] = id`; publish | 322 `{ch, id, state, phase}` at the first frame the callback mixes the slot, PLAYING or STOPPED |
| Layer Redo (`le_engine_redo` swap, `:2242-2249`) | stage `redo_stack[top].slot`, len `a_len` | same |
| Redo-from-empty (`:2205-2240`) | stage `redo_stack[top].slot`, len `empty_len`; publish; push `LE_CMD_REDO_FROM_EMPTY` | the handler flips PLAYING; the mixer sees `live0 != -1` (EMPTY reset) and emits 322 with the staged id and the restored phase (`le_restore_track_clock`, `:2859`) |
| Clear Undo (`le_restore_clear`) | unchanged staging, now through the shared helper; `source_slot`/`image_id` leave `le_command.restore` (`lockfree_ring.h:129-130`) | 322 as today, discovered through the table instead of the command |
| Undo-to-empty / cancel take | none | raw 39 at the apply frame; renderer appends silence (as `LE_CMD_CLEAR` does, `perf_render.c:1056-1058`) |
| Several admissions before one callback (Undo, Undo, Redo in one block) | each stages its own target and overwrites the table entry for that slot | exactly one 322, for the slot the callback actually mixes first, with that slot's latest id. Intermediate images are listed but unreferenced; a slot's content cannot change between its staging and its application (only a live or shadow slot is written by the callback, and either state ends the source by rule 3), so a later re-staging of the same slot is byte-identical |
| Loop-close restoration commit (`le_restore_commit_layer`, `:344-404`) | publishes with image 0 (table cleared) | `323/0`: truthful failure, as the amendment already specifies for processed-material swaps |
| Fresh capture (`le_begin_empty_capture`, `:940-967`) | clear `slot_image[ch][0..LE_POOL_SLOTS)` before the RECORD push | none; rule 3 marks the written slot during RECORDING |

Invariant (E3): every control path that writes PCM into a pool slot or publishes `a_live` outside `le_publish_live_image` zeroes `slot_image[ch][0..LE_POOL_SLOTS)` first. Sites: `engine_session.c:118-136` (`le_engine_import_track_lane`, before its `memcpy`), `le_engine_import_layer` (before its `memcpy`) and `:289` (`le_engine_finalize_layers`; publish through `le_publish_live_image(…, 0)`), `engine_commands.c:845-856` and `:961` (fresh-capture zero and regrow: one call in `le_begin_empty_capture`, which precedes both and the `le_prepare_image_capture` buffer replacement of `LE_CMD_RECORD_IMAGE` in the same admission), `:367-402` (`le_restore_commit_layer`, publishes image 0). Verified during the build: `le_prepare_image_capture` only replaces the EMPTY track's live slot and a free (non-live, non-outstanding) shadow with zeroed buffers, and runs before `le_begin_empty_capture` in `le_engine_record`, so that one row zero covers it.

Memory ordering: the table store is relaxed, `le_track_publish_live` stores `a_live` with release (today relaxed, `engine_core.h:118` via `store_i32` `engine_private.h:1978-1980`), and the callback's shared lane-0 load of `a_live` is acquire. A callback that sees the new slot therefore sees its table entry.

### 2.4 Shared control helper

`le_stage_source_image(engine, channel, slot, len) -> uint32_t` in `engine_commands.c`: returns 0 without side effects when `engine->perf.drain == NULL` (nothing to stage; same gate `le_restore_clear` uses at `:1995`, which includes a queued ARM), else allocates `++perf.next_image_id` (renamed from `next_restore_id`; `UINT32_MAX` guard counts an overrun as at `:1996-1997`), calls `le_stage_retired_layer(..., len, id)` (which now returns success), and stores the id or 0 in the table. A companion `le_publish_live_image(engine, t, slot, id)` (static inline in `engine_core.h`, next to `le_track_publish_live`, so `engine_session.c` reaches it too) stores the table entry then calls `le_track_publish_live`; it becomes the only `a_live` publisher in `engine_commands.c` (`:271`, `:2011`, `:2229`, `:2244`, `:402`) and `engine_session.c` (`:289`). `le_forget_slot_images(engine, channel)` (same header) is the row zero of the E3 invariant. Staging refusal never refuses the musical operation (precedent `test_fade_restore_staging_and_manifest_capacity`, `test_engine_fade.h:859-863`).

## 3. Log format: events.log version 6

Bump `perf_drain.c:814` from 5 to 6 and add the row to the version table (`performance-event-log-format.md`), fixing the F4 blank line from the #1145 review while there. Changes covered by the bump:

- **322** is renamed in code to `LE_PLOG_SOURCE_APPLIED` and **323** to `LE_PLOG_SOURCE_TRANSPORT` (`perf_log_ring.h:139-140`; wire values unchanged, no FFI exposure). From version 6 a channel may carry several 322 facts; each names the staged image that became live at that frame. A reader switches images on every 322. 323 keeps its meaning: same image, new state/phase; `image_id == 0` with state EMPTY means provenance was lost and the stem is not reconstructible.
- **39 `LE_CMD_UNDO_TO_EMPTY`** is logged raw from `apply_undo_to_empty` at the exact apply frame (generic arm, `arg_i` = channel), next to the existing 304. The audited table row changes from "No*, logged as 304" to "Yes, plus 304", following the documented raw-command-plus-transport-fact convention.
- **303 `LE_PLOG_LAYER_RETIRED`** `evt` arm gains a fourth field `int32_t frames` (the pass length `dub_len`), mirrored verbatim from `LE_EVT_LAYER_RETIRED` (`engine_process.c:1492-1503`). Zero in older files. Part 2 adds it on the control side under this same version (E4; the version-6 row says so).
- The Reverse plan (`origin/claude/reverse-plan-1162:docs/plan/2026-10-05-feat-foot-reverse-plan.md:257-263`) also bumps 5 to 6 and allocates 324. This plan allocates no new code; whichever lands second takes version 7. The reverse plan's `perf_restore_next_pos` note (`:170-171`) applies to `perf_source_next_pos` after the rename.

Neither reader gates on the version (`perf_render.c:558-563`, `packages/daw_export/lib/src/event_log_reader.dart:13-23` reads only mix codes), so no compatibility path is needed and none is added.

### Renderer replay (`perf_render.c:829-1096`)

- 322: already resolves the image by exact `kind/channel/restore_id` with duplicate rejection and bounds (`:634-656`), appends a segment at the fact frame with the logged phase and `silent = state == STOPPED` (`:925-929`). Repeated 322 already works because each initial segment owns its image, and the error path already frees only the image the failing 322 loaded itself (`:908-918`, `if (initial) free(restore_image)`): no change needed there (E5). The only renderer change is 39.
- 323: unchanged (`:930-935`); `id == 0` fails (`:919-924`).
- 39: append a silence segment at the fact frame and clear `restore_id`, the same arm as `LE_CMD_CLEAR` (`:1056-1058`).
- Phase: the segment counter runs from the logged first-sample index (`:1088-1090`), so same-span swaps are sample-exact and Stop/Play after a swap follows 323 facts. Mute and Fade are untouched: lane mute commands pushed ahead of a redo or restore are logged on apply and replayed in the wet pass (`:1379-1386`); Fade uses 321 (`:1372-1375`); layer Undo/Redo does not reset Fade (`le_undo_swap` touches no fade field).
- Segment capacity: each swap adds one segment against `LE_PR_MAX_SEGMENTS` (`:68`); overflow already fails rather than truncates (`:696-699`).

## 4. Truthful failure

| Condition | Where it is detected | Result |
|---|---|---|
| Staging ring full, copy allocation failure, missing or short pool buffer, id exhaustion | `le_stage_retired_layer` `:562-586`, helper stores table 0 | callback emits `323/0` at the application frame; the stem fails; `a_perf_layer_overruns` reaches the sidecar as `layer_overruns` (`perf_drain.c:1258-1262`) |
| Manifest full (2048 entries) | drain drops the image, `layers_dropped` (`perf_drain.c:871-875`) | 322 names an unlisted id; `le_pr_restore_image` returns NULL (`:646`); stem fails |
| Image file missing, short or long | `le_pr_read_layer_lane0` exact-size check | stem fails (covered by `test_fade_restore_capture_lifetime`, `test_engine_fade.h:668-684`) |
| Layer file write failure | `le_pd_write_staged_layer` returns 0, drain self-stops `disk_full` (`:1503-1506`) | no manifest entry; stem fails; master and sidecar up to the stop stay usable (existing posture, unchanged) |
| Log ring overrun (`a_perf_log_overruns`, `a_perf_log_ctrl_overruns`, today not surfaced: `engine_private.h:1508`) | Part 2 writes `"log_overruns": N` to the sidecar | renderer fails every stem of that capture (a missing fact makes any stem untrustworthy); master unaffected |
| Fact lost to any other path | none claimed | not a supported success |

The master is never affected: `master.pcm` and monitors are written by the drain independently of the layer path (`perf_drain.c:1356-1367`), and only the per-stem `succeeded` flag changes (`le_perf_render_track_status`, `segno_engine_api.h:2958-2966`), which the recorder already maps to `PerformanceRecordPartial` (#1155).

## 5. Capture-staging gaps from the #1145 and #1155 threads

| # | Gap (source) | Decision |
|---|---|---|
| G1 | Kind-0 staging gated on `a_perf_armed`, and `le_perf_disarm` (`engine_commands.c:4212-4286`) never drains `evt_ring`, so a pass retiring in the last armed block is logged but never staged (#1145 follow-up gap 1) | In plan, Part 2: gate all staging on `perf.drain != NULL` (one gate, `:539-542`), and pop `evt_ring` with `le_handle_event(..., 0)` after the quiescent handshake and before `le_perf_drain_stop` (`:4274`), so the final drain cycle writes the file |
| G2 | A retire handled after a racing CLEAR reads `a_len == 0` and is skipped (`:545-546`), although the image is still in the slot (gap 2; also the review's "frozen predecessor never staged") | In plan, Part 2: `LE_EVT_LAYER_RETIRED` carries `frames = dub_len`; `le_stage_retired_layer` uses it for kind 0. Part 1 independently makes the later peel exact by staging at admission |
| G3 | Device change and destroy stop the drain without handling queued events (`engine.c:346-348`, `:1106-1108`; gap 3) | In plan, Part 2: pop `evt_ring` immediately before each `le_perf_drain_stop(..., DEVICE_CHANGED)`. With #1158 this is the pop that `le_engine_reopen_file_retired` performs at `origin/claude/engine-reopen-1140:engine_commands.c:855`, moved ahead of the stop inside `le_engine_quiesce_workers` (`engine.c:384-387` on that branch). Destroy needs nothing: no render follows |
| G4 | Renderer takes the first manifest entry matching `(channel, slot, generation)`; dub, undo, dub again in one generation repeats the key (gap 4; `perf_render.c:986-1000`; generation bumps only on clear, `engine_commands.c:1272`) | In plan, Part 2: consume kind-0 matches in manifest order per channel (retire log order, control FIFO and staging order agree) |
| G5 | A retire parked on a full `evt_ring` is dropped by `handle_clear` (`engine_process.c:2162`) and never reaches history (review "preexisting limitations" 1) | Out of plan: never logged, so no stem impact; a history-completeness issue |
| G6 | `le_restore_clear` queues lane mutes before the RESTORE push; a refused push leaves them queued (`:1983-2003`) | Out of plan: command-ring admission ordering, not provenance; note for a follow-up |
| G7 | Restore then Undo-to-empty before any mixed frame fails the stem although silence is correct (limitation 4) | Fixed by Part 1 as a consequence of the 39 fact |
| G8 | Ordinary staging refusal rendered stale success (final-delta F1) | Already fixed in #1155 (`layer_overruns`); Part 1 adds the callback-side `323/0` so the failure no longer depends on the sidecar count |
| G9 | Log ring overruns are invisible to the renderer | In plan, Part 2 (beyond the threads' list; required by the issue's capacity clause) |

## 6. Composition

- **#1155 (`layers_dropped`, `layer_overruns`, whole-render failure)**: unchanged. The flag at `perf_render.c:406-408` still governs unlisted kind-0 retires; kind-1 misses always fail. Staged Undo/Redo images consume manifest capacity (one entry per admission), so a long session can now reach the 2048 cap sooner; the consequence is dropped later images and failed stems, never stale success, and the master continues (`perf_drain.c:871-875`).
- **#1161 (capture-prep guard)**: orthogonal. The guard refuses PCM regrow/zero on an EMPTY track until its emptying command is published (`origin/claude/capture-prep-guard-1146:engine_commands.c:1607-1612`). This plan only reads pool slots that are not live or are the EMPTY track's unwritten live slot, never writes PCM, and keeps `le_undo_swap`/redo as `a_live` publications, so no ticket is needed. The `empty_command` stamp sites (`:436-454`) are untouched; a Record refused `NOT_READY` after an Undo-to-empty has no provenance effect.
- **#1158 (reopen)**: a reopen mid-capture ends the capture with `stopped_early: device_changed`: `le_engine_reopen` calls `le_engine_quiesce_workers` (`origin/claude/engine-reopen-1140:engine.c:946`), which stops the drain with `LE_PERF_STOP_DEVICE_CHANGED` (`:385`) and zeroes `engine->perf` (`:401`), clearing the table. Facts and images from the last armed block are flushed by the final drain pass inside `le_perf_drain_stop` (`perf_drain.c:1513`), provided the queued retires are popped before the stop (G3). Retained tracks come back STOPPED outside any capture; the next arm re-initializes ids and the table. Settled partial-pass reverts (`le_engine_reopen_settle`) happen after the drain stopped and are not logged, which is correct because no capture exists.
- **Reverse plan (#1162)**: the direction fact (324) and its `perf_source_next_pos` stepping compose with the renamed fields; the renderer's phase math for 322/323 segments must apply direction when that plan lands (`:264-268` there). Version sequencing as in section 3.

## 7. Parts

### Part 1: exact provenance for callback-applied history images (about 220 production lines)

Files: `packages/segno_engine/src/core/engine_private.h` (table in `le_perf_capture` `:1275-1336`; rename `perf_restore_*` `:977-978`), `engine_core.h:116-120` (release store, `le_publish_live_image`, `le_forget_slot_images`), `engine_commands.c` (helper, call sites `:271`, `:402`, `:1995-2011`, `:2229`, `:2244`, `:963`, arm reset `:4125`; `le_stage_retired_layer` returns int), `engine_session.c:118-136`, `:184-230`, `:289` (E3 sites), `engine_process.c` (`:182-195`, `:1856-1872`, `:2874-2909`, `:3643`, `:5283-5291`, `:5369-5390`), `lockfree_ring.h:122-131`, `perf_log_ring.h:139-140`, `perf_drain.c:812-819`, `perf_render.c:905-935`, `:1056-1059`, `docs/design/performance-event-log-format.md`.

Tests (patterned literal PCM, distinct per layer, through production entry points; new file `packages/segno_engine/src/test/test_engine_history_replay.h` included like `test_engine_fade.h` at `test_engine_core.c:33032`):
- `test_history_undo_redo_literal_parity`: base ramp A, overdub passes writing B and C (three distinguishable layers), Clear, arm after the layers exist, Undo (restore), layer Undo, layer Undo, Redo, Redo, Stop, Play, disarm, finalize, render; wet stem equals live output sample for sample (pattern of `test_fade_actual_arm_render`, `test_engine_fade.h:337-375`); segment boundaries at the exact frames; phase nonzero at every swap. A second leg pumped with 128-frame blocks asserts the 322 frame equals the first frame of the block that first mixes the slot (E2). Replaces the `expected 0` in `test_fade_restore_history_replacement` with parity.
- `test_history_redo_from_empty_parity`: Undo-to-empty while armed yields silence from the 39 frame; Redo-from-empty resumes with the staged image at the restored phase; muted lane stays muted through Undo-to-empty and comes back unmuted; Fade amount unchanged across layer swaps and reset across emptying.
- `test_history_batch_before_callback`: Undo, Undo, Redo admitted between two single-frame `le_engine_process` calls; exactly one 322, naming the final slot's latest id; `A -> B -> A` within one block produces no fact; the unreferenced manifest entries are listed; stem parity.
- `test_history_restore_then_empty_same_block`: G7, now succeeds with silence.
- `test_history_stopped_swap_then_play`: Undo on a STOPPED track emits 322 STOPPED at the observed frame, 323 PLAYING at Play, silent until then.
- `test_history_staging_refusal_fails_stem_keeps_undo`: staging ring held full (pattern `test_engine_fade.h:839-863`), Undo succeeds musically, `323/0` logged, stem fails, master frames intact, `layer_overruns` reported. Two legs (E1): snapshot provenance (content live at arm, no Clear first, arm image supplied) and image provenance (Clear Undo first).
- `test_history_missing_image_and_manifest_full`: delete `restore-0-N.pcm` for a layer Undo image: stem fails; manifest-full capture: later Undo image dropped, stem fails, capture continues.
- `test_history_capture_namespace`: arm, Undo (id 1), disarm, rearm, Redo (id 1 again in the new namespace); each capture renders only its own image; `test_fade_restore_capture_lifetime`'s queued-ARM leg extended with a layer Undo.
- `test_history_loop_close_restore_fails_truthfully`: `le_restore_commit_layer` during capture gives `323/0`.
- `test_history_import_during_capture_fails_truthfully` (E3): layer Undo stages slot X, Undo-to-empty keeps X live, a session import rewrites X; Play logs `323/0`, never the stale image; one leg per import entry point.
- Existing: `test_fade_restore_source_end_edges` updated to parity (both legs; see the build record), `test_fade_restore_overdub_source_end` unchanged.

```success-criteria
GOAL: Every layer Undo, Redo and recovery from empty admitted during an armed capture is replayed sample-exactly in the derived stems from an immutable staged image identified by a callback-applied fact, and every case without exact provenance fails the stem while the master stays usable.
SUCCESS CRITERIA:
- Literal stems equal live output across Clear/Undo, layer Undo/Redo, Redo-from-empty, Stop/Play and batched admissions, with nonzero phase and preserved mute and Fade. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Staging refusal, manifest capacity, missing images and id exhaustion fail the affected stem, never report stale audio, never refuse the musical operation, and leave master.pcm complete. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- No callback allocation or blocking is added; sanitizer and telemetry-off builds pass; events.log header reads 6 and the format doc's version table has the new row. | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
- No public API, FFI, snapshot field or Dart production change; bindings unchanged. | verify: git diff --stat origin/claude/manifest-failure-1144 -- packages/segno_engine/lib packages/segno_engine/src/core/segno_engine_api.h
NON-GOALS:
- Overdub-pass write-trajectory reconstruction, multi-lane offline rendering, Stop replay for snapshot-provenance tracks, reopen, Reverse, UI.
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 2: staging gaps and capacity reporting (about 90 production lines)

Files: `engine_commands.c:535-546` (gate, `frames`), `:592-597` (pass `evt->evt.frames`), `:4260-4275` (event pop before drain stop), `engine_process.c:1490-1504` (`frames` in the event), `lockfree_ring.h:69-72` and `perf_log_ring.h:193` (`evt` arm), `engine.c:346-348` (pop before `DEVICE_CHANGED` stop; with #1158, inside `le_engine_quiesce_workers`), `perf_drain.c:1252-1262` (`log_overruns`), `perf_render.c:339-460` (parse), `:978-1055` (ordered kind-0 matching), `:1545-1653` (fail all stems on log overruns), format doc.

Tests: `test_staging_last_block_retire_before_disarm` (pass retires in the final armed block; file present, stem renders it), `test_staging_retire_after_racing_clear` (image staged with `frames` from the event; frozen predecessor peel renders exactly), `test_staging_device_change_flushes_queued_retire` (configure with a queued retire; manifest lists it; sidecar `device_changed`), `test_render_ordered_key_matching` (synthetic manifest with two entries sharing `(channel, slot, generation)`; stem uses them in order), `test_render_log_overruns_fail_all_stems` (synthetic sidecar `log_overruns: 1`), `test_perf_layer_no_staging_when_unarmed` (`test_engine_core.c:11893`) still passes with `drain == NULL`.

```success-criteria
GOAL: Every logged retire has its staged image on disk, retires are matched in order, and every capacity failure a stem depends on is visible to the renderer.
SUCCESS CRITERIA:
- A retire logged in the last block before disarm, after a racing Clear, or before a device change is staged and listed; the renderer uses it. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- Repeated (channel, slot, generation) keys resolve in manifest order. | verify: bash packages/segno_engine/src/test/run_native_tests.sh
- A capture with log overruns reports `log_overruns` and renders no successful stem; master.pcm is complete. | verify: EXTRA_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g" bash packages/segno_engine/src/test/run_native_tests.sh && EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0" bash packages/segno_engine/src/test/run_native_tests.sh
NON-GOALS:
- Parked retires lost to a full event ring at Clear (G5); queued restoration mutes on a refused push (G6).
VERIFICATION COMMAND: bash packages/segno_engine/src/test/run_native_tests.sh
```

### Part 3: production manifest handoff proof and documentation (no production lines expected)

Files: new `packages/performance_repository/test/history_replay_native_test.dart` (fuzz-tagged, self-skips without `SEGNO_ENGINE_LIB`, pattern `packages/segno_engine/test/render_failure_flag_test.dart:1-33` and `packages/looper_repository/test/fade_native_test.dart:13-15`; the existing `packages/performance_repository/test/helpers/native_capture_fixture.dart` is the preferred fixture pattern, E7), `.github/workflows/main.yaml:324-365` (run it in the `fuzz` job that builds the library), `docs/PROGRESS.md` entry. The test arms through the repository, performs layer Undo/Redo and Redo-from-empty against the real engine, disarms and finalizes, asserts the finalized `performance.json` keeps `kind: 1` entries and `layer_overruns`/`log_overruns` verbatim (`packages/performance_repository/lib/src/models/performance_manifest.dart:678-690`), and that `renderPoll` reports `failed == false` with the expected stems, and `failed == true` after deleting one image. If `PerformanceLayerEntry` (`:535-580`) needs `kind`/`restoreId` for an assertion, add the two fields only then.

```success-criteria
GOAL: The repository handoff preserves image provenance end to end and reports partial renders truthfully.
SUCCESS CRITERIA:
- Native-backed repository journey passes against a freshly built library; analyzer and format are clean. | verify: SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/performance_repository/test/history_replay_native_test.dart && dart analyze --fatal-infos packages/performance_repository
- Package suites without the library still pass (self-skip). | verify: (cd packages/performance_repository && /Users/Tomas/development/flutter/bin/flutter test)
NON-GOALS:
- New Dart owner, model schema, or banner wording.
VERIFICATION COMMAND: SEGNO_ENGINE_LIB=$(bash packages/segno_engine/tool/build_test_lib.sh) /Users/Tomas/development/flutter/bin/flutter test packages/performance_repository/test/history_replay_native_test.dart
```

Part 2 depends on Part 1 (the version-6 bump). If Part 2 must land first, it carries the bump and Part 1 adds no further bump (E4). Part 3 follows Part 1. Each part runs normal, ASAN and telemetry-off native suites, `dart analyze --fatal-infos`, and independent architecture, test and adversarial review before the human merge gate.

## 8. Required proof mapped to tests

| Issue proof item | Tests |
|---|---|
| Patterned audio with multiple distinguishable layers; literal samples and phase after Undo/Redo | `test_history_undo_redo_literal_parity`, `test_history_stopped_swap_then_play` |
| Clear/Undo followed by layer Undo/Redo and Stop/Play | `test_history_undo_redo_literal_parity` (restore first), `test_fade_restore_history_replacement` (parity oracle) |
| Recovery from empty and multiple operations admitted before a callback | `test_history_redo_from_empty_parity`, `test_history_batch_before_callback`, `test_history_restore_then_empty_same_block` |
| Exact capture namespace through arm/disarm/rearm; capacity, missing-image and write failures never report stale audio | `test_history_capture_namespace`, `test_history_staging_refusal_fails_stem_keeps_undo`, `test_history_missing_image_and_manifest_full`, `test_history_import_during_capture_fails_truthfully`, existing write-failure legs of `test_fade_restore_capture_lifetime`, `test_render_log_overruns_fail_all_stems` |
| Current native matrix, production manifest handoff, independent reviews | run_native_tests normal/ASAN/telemetry-off; Part 3 Dart journey; reviews per part |

## 9. Decisions under the owner rules

- D1 (rule 4): reuse `kind 1`/`restore_id`/`restore-*.pcm` and codes 322/323 for all applied images instead of a new kind or new codes; rename only code identifiers. Rule 1: existing sidecars and logs parse unchanged.
- D2 (rules 2, 5): a slot made live without a staged image (loop-close restoration, import during capture, any unknown path) logs `323/0` and fails that stem. This turns today's stale successes for those paths into reported Partial renders; not silent (rule 3), master untouched.
- D3 (rule 4): stage a fresh image at every admission rather than tracking slot-content invalidation to reuse earlier images; cost is one loop-length copy per lane per press, the same as a retire. Each admission copies `len × lanes × 4` bytes on the control thread and writes the same to disk (a 30 s stereo-lane loop is about 11.5 MB per press); disk growth, not capacity, is the ordinary-use cost (E6). Capacity itself is not a routine risk: the staging ring is `LE_MAX_TRACKS × 256` entries drained every 10 ms, the manifest is 2048 per capture, and the fastest consumer remains one retire per overdub pass, unchanged by this plan; "fail the stem" is acceptable. Unreferenced images stay under the existing drain cleanup owner.
- D4 (rule 2): overdub or record on an image-sourced track keeps ending the source with `323/0` (accepted in the #1142 amendment); kind-0 behavior for snapshot-provenance tracks is unchanged.
- D5 (rule 1): staging refusal never refuses Undo/Redo; the musical operation and its history stay exactly as today.
- D6 (rules 2, 5): log overruns become visible and fail every stem of the capture; the master is reported complete.
- D7 (rule 4): no Dart production change; the manifest passes native fields verbatim (`packages/performance_repository/lib/src/models/performance_manifest.dart:684-690`).
- D8 (rule 1): at a mid-capture reopen the capture ends `device_changed` as it does on configure today; no attempt to continue a capture across devices.
- D9 (rule 3): `LE_CMD_UNDO_TO_EMPTY` is logged raw in addition to 304 rather than changing 304's meaning.

## 10. Findings outside this plan (no product-direction question identified)

- Kind-0 retired images are pre-pass images: `le_dub_boundary`/drain retire the backup-on-write shadow (`engine_process.c:5595-5601`, `:1627-1634`, `engine_private.h:920`), while the renderer activates the retired image as new content at the retire frame (`perf_render.c:1017-1046`) and the part-7 plan describes a post-pass image (`docs/plan/2026-07-05-feat-performance-recording-daw-export-part-7-plan.md:26-31`). No real-engine test renders an overdubbed stem (`test_perf_render_overdub_stitching` writes a synthetic post-pass file, `test_engine_core.c:18918-18931`). Overdubbed stems therefore do not contain the pass. This plan's proofs arm after layers exist so the result does not depend on it; filed as #1169.
- The dry render does not model `LE_CMD_STOP` for snapshot-provenance tracks (no handler in `perf_render.c`; only `LE_CMD_CUT_SOUND` silences, `:1360-1366`); image-sourced segments do, via 323. Filed as #1170.
- A restore admitted before `le_perf_arm` and applied in the same block as `PERF_ARM` has neither snapshot nor fact provenance (pre-existing; `engine_process.c:2895`).

## 11. Budget and review ceiling

Production additions per part stay under 700 lines (estimates: 220, 90, 0). Stop for review on any new public function, FFI change, Session schema, second history ledger or Dart owner. Tests, bindings and documentation are counted separately. Independent architecture, test-quality and adversarial reviews precede each part's publication; actual Claude review, published-head CI and the human merge gate remain separate.

## 12. Part 1 build record

Review edits E1-E8 are applied in the text above. The build departed from the amended text in these places, each checked against the code:

- **E2, application boundary.** The review's premise ("`buf[t][l]` is loaded once per block, before the per-frame loop") does not hold: `mix_tracks_frame` takes the frame index `f` as a parameter and is called from `le_engine_process`'s `for (uint32_t f = 0; f < frames; ++f)` loop (`engine_process.c:6252`, `:6302`), so the `a_live` load at `:5287-5291` is per frame. Making it once per block would have changed when the production mixer applies a control-side swap (deferring a mid-block publish to the next block), a product change outside this issue. The built rule keeps the review's intent at the granularity the mixer actually has: one acquire load of lane 0's `a_live` per frame per track (idle tracks included), shared by the mixer and the tracker through `live_idx[t]`, replacing the relaxed lane-0 load. The 128-frame block leg is kept as a block-boundary placement check (a swap admitted between blocks lands on the block's first frame under either design); the leg that discriminates the two is `test_history_mid_block_swap_frame`, which admits the swap from the stage-5 test hook at frame `f` of a 128-frame block, after that frame's live-slot loads, and asserts the fact at `block_start + f + 1`, where a per-block load would place it at the next block start (PR #1173 review, finding 3).
- **Rule 3 extension.** With the lookup moved from the restore handler to the first PLAYING/STOPPED frame, a restore (or Redo-from-empty, or layer swap) followed by Record in the same block would have produced no fact at all, and the existing `test_fade_restore_overdub_source_end` `before_first_sample` leg would have reported stale success. Rule 3 therefore also logs `323/0` when the slot changed under RECORDING/OVERDUBBING and the new slot's table entry is nonzero (a staged image overwritten before it was ever mixed). A fresh take from EMPTY is unaffected: `le_begin_empty_capture` zeroes the row (E3), so its entry is 0 and no fact is logged.
- **`test_fade_restore_source_end_edges`.** The plan said to keep its failing legs where provenance is genuinely absent and flip the racing-swap leg to parity. Neither leg has absent provenance after this change: the racing-swap leg mixes the staged Undo target in the frame the mid-frame Redo was admitted (the Redo takes effect at the next frame, which never comes), and the undo-to-empty leg is exact silence from its raw 39 (G7). Both legs now assert parity.
- **`test_history_restore_then_empty_same_block` (G7).** With only a never-mixed restore and an emptying on the channel, the renderer has nothing to collect (no 322/323 fact, no snapshot entry) and produces no stem for it, which is correct but asserts nothing. The test follows with a Redo-from-empty so the channel is collected: the stem renders silence then the staged image, with one 322 (the Redo's), one raw 39 and the unreferenced restore image listed.
- **`test_perf_layer_persists_through_redo_invalidation`.** Its manifest count of 2 counted kind-0 retires only; the layer Undo in it now stages a kind-1 image between them. The oracle is 3 entries with `restore-0-1.pcm` present, and the retire checks address entries 0 and 2.
- **`le_publish_live_image` placement.** Defined as a static inline in `engine_core.h` (next to `le_track_publish_live`) rather than in `engine_commands.c`, because E3 requires `engine_session.c` to publish through it. `le_forget_slot_images` sits beside it.
- **Arm window (PR #1173 review, finding 1).** A swap admitted after `le_perf_arm` returned and before the callback applied `LE_CMD_PERF_ARM` stages its image (the drain exists) but the handler adopted the already-swapped `a_live` as snapshot provenance, so no fact was logged and the arm image (exported before `perfArm`) rendered as success. The handler now acquire-loads `a_live` and leaves the track unresolved (`perf_source_slot = -1`) when the live slot's table entry is nonzero, so rule 1 logs 322 at capture frame 0; any nonzero entry at that point was staged after the arm's row zero, so it is this capture's. `test_history_arm_window_swap` fails without it. The sub-window before `le_perf_arm` (section 10, pre-existing) is a repository ordering question, not this part's.
- **Lane order (finding 2).** `le_track_publish_live` now stores lanes `n..1` before lane 0 (release on each), so no lane can still mix the previous slot in the frame lane 0's fact names; a lane `k >= 1` may still mix the new slot one frame before the fact. The fact is exact for lane 0, which is all the lane-0 renderer consumes; the format doc records the lane `1..n` tolerance for a future multi-lane renderer.
- **Production size.** the production diff over `packages/segno_engine/src/core` adds about 255 lines and removes 81, comments included; within the estimate.
- **Fail-without-fix evidence.** Recorded in the PR description from a run of the new test file against the base production sources (`origin/claude/manifest-failure-1144`): the parity, G7, batch, namespace, missing-image and import legs fail there, and the refusal legs fail because no `323/0` is logged for a snapshot-provenance track.
