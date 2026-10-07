Model: Claude Fable 5.1 (subagent, extra-high effort), in-session retry; the original headless run was rate-limited
PR 1145 / issue 1142 — head `ef55f2b3273fe2431cc27effa064d86d345e591f` against base `c2e1d728293e2db03848362d6027cbc84692c468`.

## Verdict

No defect found in the Clear mailbox, history, restore identity or callback-lifetime paths. One introduced behavioural regression (Medium) in the performance drain's capacity handling, two Low notes, one trivial doc fix. The core change is sound; details and read bounds below.

## Findings (introduced)

### F1 — Medium: layer-manifest exhaustion now halts the whole capture, labelled `disk_full`

`packages/segno_engine/src/core/perf_drain.c:894` — `if (ok && d->layer_count >= LE_PD_MAX_LAYERS) ok = 0;`. The staged file was already written and closed successfully (lines 868–889); the only failure is the bounded in-memory manifest (`LE_PD_MAX_LAYERS == LE_LAYER_STAGING_RING_CAPACITY == 8 × 256 = 2048`). That `0` propagates through `le_pd_drain_staged_layers` (line 921) to `le_pd_drain_cycle` (line 1415, latches `disk_full`) and the thread loop at line 1482–1485 `break`s. From then on `master.pcm`, monitor files and `events.log` stop being written; the final pass writes `"stopped_early": "disk_full"`.

Base behaviour: the entry was silently not recorded and the capture continued (the later render of that stem was wrong, which is the stale-success problem this PR rightly closes).

Trigger: 2049 staged entries (retired overdub passes plus Clear-restore images) in one armed capture. Each loop cycle held in overdub retires one layer, so one track overdubbing a 2 s loop for ~68 min, or 8 tracks for ~9 min, reaches it. Rare, but a live performance, not a fault injection.

Observable bad result: the independently captured master — which the brief and plan say must remain usable when derived stems fail — is truncated at the moment the metadata table fills, and the sidecar reports a disk problem that did not occur. The author's `test_fade_restore_staging_and_manifest_capacity` (`test_engine_fade.h`, `manifest_full` leg) asserts the self-stop and does not check the master's length, so it encodes rather than catches this.

Smallest correction: on manifest exhaustion keep `ok = 1`, record the exhaustion as an incomplete marker (the existing `a_perf_layer_overruns` counter already fails the affected restore stem via the renderer's missing-identity path; a distinct sidecar key such as `layer_manifest_full` would be clearer than reusing `disk_full`), optionally `remove()` the orphan file, and keep the master running. If the owner prefers the halt as a deliberate choice, rename the marker and add a master-length assertion to the test so the trade-off is explicit. Note the renderer silently continues when a kind-0 `LAYER_RETIRED` has no manifest match (`perf_render.c:944–1013`), so a "keep capturing" fix should also set `load_failed` there to keep the no-stale-success property.

### F2 — Low: capturing-at-arm lanes now export an arm-time device chain (unrequested, untested)

`packages/performance_repository/lib/src/performance_repository.dart:1066–1078`. The deferred-lane branch is shared by `capturing` and the new `writeChains && lengthFrames <= 0` case, so a lane mid-overdub at arm now carries `effects`/`chainEnabled` (the model only emits `effects` when non-empty, so this is a real manifest change for lanes with chains). daw_export's `manifest_reader.dart:112–128` builds `effectsByChannel` from every arm lane and `resolveDeviceChain` (line ~181) therefore resolves a device chain for a lane whose PCM arrives via the disarm snapshot; the ALS switches from the wet stem to dry stem + device chain. Previously that lane had "no evidence" and kept the wet stem. Probably an improvement and consistent with settled lanes, but it is outside the described scope and no test covers it. Correction: either restrict the chain fields to the `lengthFrames <= 0` case, or keep it and add a performance_repository test asserting the capturing-lane manifest.

### F3 — Low/optional: mute-only lane Undo now defers to the next poll

`looper_repository.dart:3577–3603` (snapshot) plus the existing `_stageClearUndoFx` → `_requestHistoryFx` → `setLaneEffects` fence. A lane with a remembered mute but no chain previously had no snapshot entry, so Undo ran immediately; it now stages an empty recipe and the audio Undo waits for the ack and the ticker (the new Dart test needs `pump` + `ticks.add` for exactly this). Correct, and the same latency any lane with a chain already pays. Optional: restore `_laneMute` for lanes whose snapshot has empty effects and an enabled chain without staging a recipe.

### F4 — Trivial: version table split

`docs/design/performance-event-log-format.md` — the new `| 5 | … |` row is separated from the version table by blank lines, so Markdown renders it as a second, header-less table. Remove the blank line.

## Verified sound (key reasoning)

- Mailbox protocol: `handle_clear` samples `t->fade.amount` before `le_reset_track_playback`/`le_fade_reset`, publishes a seq-cst odd/even revision around four atomic fields, then releases `a_state_acks` (`engine_process.c:2085, 2219–2230`). `le_collect_clear` (`engine_commands.c:682–730`) requires `clear_cmd_ack <= a_state_acks` (acquire), rejects odd/changed revisions and mismatched generations, so a torn or stale read is a no-op, never a default. One slot suffices: every CLEAR producer, including the internal `clear_first` grid-redefine (`engine_commands.c:1503–1512`), runs `le_prepare_clear`/`le_finish_clear`, keeping `dub_generation` and `dub_gen_audio` in lock-step and bumping `clear_cmd_ack`, so an older publication can never satisfy a newer point.
- Post-before-finish: `le_clear_track` pushes, prepares, drains (D-LAYER), then finishes. If the callback lands in that window the ordinary top entry is not yet pushed (no attach, attaches on the next drain with `fade_ready=0 → 1`); the frozen point is filed by the drain and `le_finish_clear(freeze=1, NULL)` keeps it. Covered by the existing `test_freezing_clear_completion_before_second_drain` and the new interleave legs.
- Frozen predecessor retirements: accepted only when `evt.generation + 1 == clear_restore_generation` while pending (`:598–602`); `le_post_dub_shadows` refuses to re-arm slots while pending (`:190`); record-from-empty drops pending before posting shadows (`le_begin_empty_capture:946` precedes `:1669`). The unbounded `undo_stack[undo_count++]` in the frozen filing is safe: every undo entry under a pending frozen point is a LAYER owning a distinct pool slot, the live slot is pinned, so ≤255 layers precede CLEAR.
- Capacity refusal before mutation: the new `LE_ERR_NOT_READY` at `:1763–1766` precedes the push; a refused push leaves `clear_cmd_ack`, history and pending untouched.
- Restore identity: the image is copied synchronously on the control thread from the retained slot before `RESTORE_CLEAR` is pushed; `le_lanes_active` lanes, `pool_cap` checked. `perf.drain != NULL` (not `a_perf_armed`) lets a queued ARM own staging; FIFO guarantees ARM applies before RESTORE. Staging refusal increments the overrun counter and never refuses the musical Undo. `next_restore_id` resets per arm after the joined disarm.
- Source-end detection compares the frame's selected `buf[t][0]` (captured once per frame at `engine_process.c:5283`, the dry live pool pointer, not a wet-cache buffer) against `pool[perf_restore_slot]`, so an A→B→A swap that rendered B ends the source, and a swap the callback never observed does not. Overdub (state) and undo-to-empty (`le_perf_restore_end`) log an explicit `323/0`; the renderer fails on it (`perf_render.c:883–890`). `LE_CMD_RESET_FADE` is only posted on EMPTY import paths, so its silent `perf_restore_active = 0` cannot hide a live change.
- Renderer: identity resolved by exact kind/channel/id with duplicate rejection, bounds, overflow and exact-EOF checks; segment-cap overflow now fails rather than truncates; non-owning 323 segments share the 322's image and are freed once. `restore_log` is 16 bytes of 4-byte fields, so the block `memcpy` in `le_log_extract` and `le_pr_load_log` is exact; 322/323 are unique enum values; only 102 is removed from the bindings.
- Dart: `_snapshotForClearRestore` runs before `_dropTakeState` forgets mutes, and `_restoreClearedTake` writes `_laneMute` back; `_finalize` merges through `.native`, preserving `kind`/`restore_id`; arm "empty" tracks are skipped by `le_pr_collect_channels` and by `manifest_reader`'s `arrangementFile == null && sessionClips.isEmpty` guard, so no empty DAW tracks appear; the 8192-node JSON arena absorbs the larger arm snapshot (≈650 nodes worst case).

## Preexisting limitations observed (not introduced)

- A retirement parked on a full `evt_ring` (`le_dub_try_retire`) is dropped by `handle_clear` (`dub_retire_slot = -1`), so that layer never reaches history; the plan scopes this out.
- A frozen predecessor's layer is filed in history but never staged for capture (`le_stage_retired_layer` reads `a_len == 0` on the now-EMPTY track); a later peel to it ends the restored source and fails the stem — explicit, not stale.
- `le_restore_clear` queues lane mutes before the RESTORE push; a refused push leaves them queued.
- Restore followed by Undo-to-empty before any frame is mixed fails the stem although the correct stem is silence; the plan declares this.

## Read bounds

Full `change.diff` (2448 lines). `engine_commands.c` 40–100, 300–470, 530–665, 675–800, 930–1000, 1225–1335, 1460–1530, 1655–2260 plus grep sites; `engine_process.c` 110–135, 1300–1325, 1480–1500, 1735–1775, 2060–2240, 2850–2935, 2975–2995, 3600–3665, 5180–5300 plus every diff hunk; `perf_drain.c` 856–915, 1395–1500; `perf_render.c` 517–580, 795–870, 943–1020, 1480–1545 plus hunks; `perf_log_ring.h` 200–275; `engine_session.c` 120–140, 280–295; headers via hunks and greps; test seams (`test_engine_core.c` 120–150, 487–500, 24140–24175; `test_engine_fade.h` 1–45 and all new tests). Dart: `looper_repository.dart` 975–1060, 3200–3215, 3340–3420, 3540–3610, 3650–3710; `performance_repository.dart` 300–330, 505–600, 941–990 and the hunk; `performance_manifest.dart` 55–170; `manifest_reader.dart` 80–290; test/fake hunks. Not read in full: the 33k-line `test_engine_core.c`, unchanged regions of the large C files, `event_log_reader.dart` (grep only), `als_builder.dart`, `manifest.json`. Evidence logs were not used as proof. No existing author review document was read before forming this verdict.
