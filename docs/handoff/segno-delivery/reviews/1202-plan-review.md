Model: Claude Opus (subagent), in-session

# Review of PR #1225: Shared render recipe, foot Bounce and Save selected audio (plan)

## Scope

- Plan `docs/plan/2026-10-06-feat-render-recipe-bounce-plan.md` on `origin/claude/render-bounce-plan-1202` at `ea66b0351` (one file, 1277 lines), issue #1202.
- File:line claims checked against trunk `56033baf0` (`origin/claude/segno-integration`).
- Accepted behaviour: `docs/handoff/segno-app/accepted-behavior.md` §2.11 (:167-172), §3.5 (:210-215), §3.11 (:243-249), §4 Bounce row (:306) and §6.6 (:443-448). Also read: the main checkout's `docs/design/selected-render-policy.js`, `bounce-performance-study.js`, `2026-09-07-bounce-performance-ux.md`, `2026-09-08-processing-behavior-proposal.md`, `2026-09-07-audio-library-ux.md` and `performance-event-log-format.md`.
- Pen, read through the pencil MCP only and never saved (`segno-ui.pen`, group `01 CURRENT UX`): section 17 (`vBT13`, `K2Ui7`, `YPpOv`, `y5o1vy`, `DhyM0`, `y5k8v`), section 18 (`bx7vK`, `B5q2Q`, `M9kyGb`, `o32NQJ`) and section 49 (`op31E`, `meZ1X`). I also searched the whole group for Bounce, Save audio, Mix FX, mono and plugin text.
- Cross-branch checks:
  - Peel P2: `origin/claude/peel-1164-p2` `531addc0d`, PR #1194.
  - Multiply/Divide P1: `origin/claude/multiply-divide-1168-p1` `4b26f6189`, PR #1212.
  - Pitch/time 3a: `origin/claude/pitch-time-1179-p3a` `fd3b8970d`, PR #1214.
  - Recording/recovery plan: `origin/claude/recording-recovery-plan-1198` `69972aa2f`.
  - Backing P2: `origin/claude/backing-1200-p2` `bd742eadf`, PR #1223.
  - Library P3: `origin/claude/library-1178-p3`.
  - Library plan: `origin/claude/library-plan-1178`.
  - USB P4: `origin/claude/usb-storage-1177-p4` `a10cd2387`.
  - Numbering ledger: the coordinating session's `numbering-ledger.md`.

## Runs

- `npx cspell -c .github/cspell.json` on the plan file: 0 issues.
- This is a plan review with no code to execute. Every finding below comes from reading the trunk code paths named in each finding. Each cited line was opened and read; none is quoted from memory.

## Verified correct (traced)

- **File:line claims.** Nearly every trunk citation is exact. This covers all `engine_process.c` sites (mix order, wce/tce, the All tracks loop, `handle_clear`, `le_transform_reset`, `le_restore_track_clock`, `le_publish_lane_mix`, `le_apply_capture_image`), every `engine_cache.c` site, `perf_render.c` (`:1219-1225` struct, `:1279-1283` "only L", `:1512` gate, `:552-566` magic-only check), `engine_commands.c` (`le_clear_track`, `le_restore_clear`, undo/redo, the mode gate, `le_request_admit`, `le_peel_depth`, `track_acquire_slot`, `le_layer_slot_frames`), `engine.c` (`:84`, `:352`, `:1523`), `engine_session.c`, the API header (`:39-52`, `:520`, `:3015-3070`), `perf_drain.c:827`, `session.dart:847`, the session repository lines, `wav.dart`, the `looper_repository.dart` Clear All ledger lines, and the Dart surface sites. Exceptions are listed under L1.
- **Live mix summary (§2.2).** It matches `mix_tracks_frame` (`engine_process.c:5524-6327`). Lanes are mono into a stereo chain. Pan is applied after the chain. `a_gain_bits × fade_sample` goes inside the track chain at the pre/post boundary. The All tracks chain runs once per output bus.
- **No routing in the render (§4.2).** This is a faithful simplification. A lane routed to an output pair receives exactly `(wl, wr)` (`le_fx_route_frame`, `:2547-2561`), and the render keeps that pair.
- **Plugins.** A fresh offline `le_fx_state` renders a plugin slot dry (`perf_render.c:30-37`).
- **Numbering.** 112-115, 332-335 and -16/-17 are inside this plan's range in the ledger. Kind 5 does not collide with Peel P2 (kinds 0-3) or with M/D P1 (`LE_HIST_LENGTH = 4`).
- **Slot pinning.** Lanes share slot indices in lockstep (`engine_private.h:458-459`), so the plan is right to pin every lane to the new length.
- **Legacy exports.** `exportMixdown`/`exportStems` have no UI caller (only `SessionCubit` and l10n keys reference them).
- **Policy defaults.** The policy (`selected-render-policy.js`) matches the plan: rational LCM capped at 1024 beats, chosen length in whole bars clamped to `floor(1024/beatsPerBar)`, Wrap default, Mix FX default off, `globalSpeedPrinted:false`, and the destination `{level 1, pan .5, mono false, pitch 0, reverse false, fade null, fx []}`.
- **Pen confirms these plan rows:**
  - Clear: Wrap/Cut tails ("Across loop edge"), Keep/Clear sources ("After bounce"), "New bounce".
  - Rec/Play: Next → Bounce / "Replace &" "bounce" → "Bounce complete".
  - "Replace audio" shows on every occupied track.
  - Bank keeps the selection across banks.
  - The result screen reads "Stopped" with Keep sources.
  - `meZ1X` puts Length and Mix FX in the route panel and no Tails row, since Tails sits on the Clear pedal.
  - `op31E` has the Length, Mix FX and Tails rows.
  - No pen screen draws a progress state.

## Findings

### High

**H1. The phase origin leaves out `playback_offset`, so a reversed or Once-relaunched source renders out of phase and Clear sources jumps.**
- **Where.** Plan §4.4 R3 and §5.3 step 2. The freeze record holds `I_ref`, the segment origin `((I_ref - start_iter) mod k) × base`, `reversed`, slots and rev. On trunk the read index is `le_direction_index(reversed, playback_offset, base_position, len)` (`engine_process.c:146-156`, `engine_direction.h`). A Reverse toggle re-origins `playback_offset` so the index stays continuous at the turn (`engine_private.h:1283-1295`, `engine_process.c:3271`, `:3288`), and a launch after an automatic Once end sets it too (`:170`).
- **Failure.** The player reverses track 2 mid-loop, which is the normal use ("toggles direction at its current position"). Then they Bounce with Clear sources while playing. The render reads track 2 from origin 0, but live reads from `playback_offset`. The destination starts at `start_iter = I_ref` with the wrong material under the playhead: an audible jump at commit, and a bounced loop that does not match what was heard.
- **Why tests miss it.** `test_render_reverse_frozen_direction` ("reads 16..1 from the origin") uses offset 0 and would pass. The Part 4b continuity test only fails if one of its sources was toggled.
- **Fix.** Freeze each source's complete read law at the freeze frame: `reversed`, `playback_offset`, the segment, and after P2a the read-head phase. Read through `le_track_read_index`, not a recomputed segment. Add a literal test with a mid-loop Reverse toggle and one with a Once relaunch.

**H2. Clearing the sources first can trigger the all-empty master reset inside the Bounce drain.**
- **Where.** Plan §5.3 runs `handle_clear` on every cleared source (step 1) before installing the destination (step 2). `handle_clear` resets the master when every track reads EMPTY (`engine_process.c:2405-2420`). It sets clock length 0, `loop_iteration = 0`, master length/position 0, `a_loop_bars = 0` and the grid beat. Step 2's re-clock then calls `le_restore_track_clock`, which sets `loop_iteration = 0` again (`:1296-1303`).
- **Failure.** This is the flagship case: all recorded tracks bounced into an empty track with Clear sources while playing. After the reset, `start_iter = I_ref` (for example 57) against `loop_iteration = 0` reads segment `(0 - 57) mod k'`, which is the wrong phase. The click grid also restarts from beat 0. The Part 4b continuity test, with "two playing sources" on a two-track rig, hits this case.
- **Fix.** Install the destination before clearing the sources so the rig never reads all-empty, or suppress the reset for group members. Define `start_iter` against the preserved `loop_iteration`. Say explicitly that the sole-content re-clock keeps the clock running. Add the "every content track into an empty track" case to Part 4b.

**H3. Wrap with Clear sources doubles the Post tails at commit.**
- **Where.** §5.3 step 1 says the cleared sources' "Post tails drain (§3.6)". The destination's Wrap render already carries those tails in its first lap: the end-of-window tail is folded into the start (§4.5). Both sound together for one tail length after the commit block.
- **Contradiction.** Part 4b's test claims "no frame where both sound… output equals the render buffer at the mapped phase". It cannot pass with a Post delay or reverb on a source.
- **Fix.** With Wrap, flush the cleared sources' lane Post, track Post and their share of the live tails in the same drain, because the destination's baked tail replaces them. With Cut, let them drain, since the destination starts without a tail. State this in §5.3 and test both with a Post delay.

**H4. The destination's lane topology is not committed to the Dart mix intent, and it is grown with the wrong helper.**
- **Wrong helper.** §5.2 step 5 grows lanes with "the import path's helper" (`engine_session.c:109-114`). That code writes `lane_count` directly and is only legal because import requires an EMPTY track (`:84`, "its buffers are not read by the audio thread"). An occupied, possibly playing destination needs the structural `le_engine_set_lane_count` → `LE_CMD_SET_LANE_COUNT` path with its `lane_growth_command` fence (`engine_commands.c:4358-4378`).
- **Undo list incomplete.** The §5.4 Undo restore list does not include lane count, so Undo leaves lane 1 active over a slot that held nothing for it.
- **Dart intent incomplete.** §5.5 step 5 commits only levels, pans, mutes and `_laneBasePan`. `_MixIntent` also carries `counts`, `balances`, `inputs` and `routes` (`looper_repository.dart:629-642`). Every replay re-sends all of them (`:704-731`, `replay ||`).
- **Failure.** After a device reopen (#1140/#1158), a configure or a session recall replays the mix. `counts[dest]` is still 1, so the bounce loses its R lane. A stale `_laneBalance` republishes the old image gain, which is a silent level change.
- **Fix.** Grow and shrink through the structural command, folding it into the 113/114 drain or fencing it before. Snapshot and restore the lane count. Commit `_laneCount`, `_laneBalance = 1`, `_laneInput` and `_laneOutput` for the new lanes. Restore all of them on Undo. Test with a replayed mix after the bounce.

**H5. An overdub on a bounced destination records the player hard-left, plus an unrelated input on the right.**
- **Where.** A grown lane 1 takes `le_lane_reset`'s default input, `input == lane index` (`engine_session.c:103-108`; Dart `_laneInput[key] ?? lane`, `looper_repository.dart:3021`). Lane 0 keeps its image pan −1 through an overdub (`:3020`), and the plan relies on this (B5).
- **Failure.** A mono-input track (input 0, one lane) is bounced into and then overdubbed. The mic goes into lane 0 and plays hard left, while hardware input 1 is captured into lane 1 and plays hard right. This changes recording without telling the player (rule 3) and contradicts B2's "recording inputs … unchanged".
- **Fix.** Define the destination's recording routing. One option: lane 1 records the same input(s) as lane 0, so a mono overdub lands centred across ±1. Another: lane 1 is unrouted, marked `a_recoverable` so `le_trim_trailing_lanes` (`engine_commands.c:4398-4419`) cannot reclaim it, with a notice. Add an overdub-after-bounce test. This is the substance behind planner question 3.

**H6. A session saved after a Bounce Undo can fail to reopen, or can split the group.**
- **Where.** Peel P2 changes `le_engine_export_history` to export both stacks with `undo_count` (`peel-1164-p2 engine_session.c:167-192`). Its strict `le_engine_finalize_history` rejects any kind other than 0-3 (`:293-296`). The plan's cut is "stop below the newest BOUNCE entry" (§5.4), which covers the undo side.
- **Failure.** After a Bounce Undo, the destination is captured with a redo-side `LE_HIST_BOUNCE` entry. Exported as kind 5, it makes recall return INVALID, and Dart's `TrackHistory.malformation` refuses the Session: a saved session that will not open (rule 1). The restored sources are captured with a redo-side `CLEAR(group)`. Peel P2 accepts that as a plain CLEAR, so after recall Redo re-clears one source alone, which the plan says no path may do.
- **Fix.** Write §5.4 against Peel P2's signature:
  - export drops a redo-side BOUNCE entry and every redo entry with a nonzero `group_id`, on every member;
  - `undo_count` and the ordinal map follow that cut.
  - Part 4a/5 add "Bounce, Undo, save, recall" round trips for the destination and for a source.

### Medium

**M1. No tempo leaves the cap undefined and offers no render at all.**
- `a_tempo_bpm_bits` is 0 when unset, and that is a valid restored state (`engine_private.h:1635`, `le_restored_tempo_valid` `:2208-2212`). §4.4's cap `round(1024 × 60 × sr / tempo)` divides by zero. Chosen length is refused without a tempo.
- In Free/Song with unequal lengths, which is the usual Free case since lengths are arbitrary frames, Save audio and Bounce are both impossible and the plan gives no message.
- Fix: define the no-tempo rule. Either cap in frames (for example `max_loop_frames` for Bounce plus a seconds ceiling for files) and allow common cycle, or refuse with a specific "Set a tempo" notice. Test it.

**M2. Cut also cuts Pre, which is part of the take.**
- §4.5 renders the whole chain cold for Cut. AB §3.5 (`:210`) makes Pre "part of the take's playable representation", and the cache prints it wrapped at the lane's own length (`engine_cache.c:1208-1214`).
- A Pre reverb on a loop therefore loses its wash at the start of a Cut file or bounce, which changes the take rather than the render boundary.
- Fix: Pre (the lane prefix and track Pre) always renders as the take does, wrapped per lane length. Wrap/Cut governs Post, track Post and Mix FX at the render window. Consider staging the key-matched published print instead of re-running Pre: it is exactly what is heard, including the [R5] periodic behaviour.

**M3. Mix FX On in Bounce applies the All tracks chain twice.**
- The destination reset empties lane and track chains (B2), but the All tracks chain is global and still processes the destination live (`engine_process.c:6305-6320`).
- With Mix FX On, `meZ1X`'s option bakes the chain in and live playback applies it again. This contradicts "resets destination processing so it is not printed twice" (AB §3.11) and the processing proposal's "shared processing applies once when the neutral destination later plays".
- Fix: add it to §11 as an owner question (offer Mix FX for Save audio only, or keep it with a "Mix FX will also apply live" notice). Do not ship it silently.

**M4. The freeze waits up to one whole master loop.**
- §4.4 applies 112 "at the next master top". With a 16-bar base at 60 BPM, that is up to 64 s of "Saving… 0%" or a stalled Bounce, and the plan does not state the wait.
- `I_ref` and every source's phase are computable at any frame from `loop_iteration`, `clock.position` and the H1 read law.
- Fix: apply immediately and define render frame 0 as the current iteration's top, or document the latency and test it.

**M5. Save audio defaults and folder contradict the pen.**
- §6 says "the policy and pen say nothing on preselection" and defaults to no tracks selected. `M9kyGb` and `op31E` both draw Tracks 1-3 (the recorded ones) selected, with 4-8 dimmed as empty. The planned goldens "matching M9kyGb … op31E" cannot match a none-selected default.
- The pen's Save-to folder line is "Saved audio". The plan writes `<documents>/audio/<name>.wav` and `Segno/Audio/<name>.wav`.
- §8 item 2 says "18/01 draws Prepared audio only". `bx7vK` is a folder browser (folder "Backing tracks", with "Prepared audio" as a heading button), so "Saved audio" fits as a folder, not a new group.
- Fix: preselect every recorded track, write into a "Saved audio" folder, and correct §8. Otherwise record these as pen deviations.

**M6. Consolidation: a third native WAV writer.**
- #1198 Part 2 builds a streaming float32 WAV part writer in `perf_drain.c`: zero-size header, append, seal by patching sizes, `fflush`, incremental SHA-256 and overs. #1198 P1 (PR #1220) adds directory sync.
- The plan adds its own streaming writer in `engine_render.c` and points `perf_render.c` at it. That is three writers where one fits (rule 4).
- Fix: one native streaming float WAV writer module used by `perf_drain`, `perf_render` and the recipe, landing with whichever goes first. Publish with `.part`, fsync, rename and #1220's directory fsync.
- Related: §4.7 charges "staging bytes plus output bytes" against 512 MiB. For the file target, output should be the slice buffer. Otherwise a 256-bar file at 96 kHz below about 85 BPM (for example 80 BPM = 589,824,000 bytes) is refused although the policy allows it.

**M7. Contention on the shared worker is unspecified.**
- **Pick priority.** `le_cache_pick` ranks jobs by `e->tracks[job->channel].a_state` (`engine_cache.c:1193-1206`, unchanged in 3a). A recipe job has no channel, so the plan must state its rank: below playing-lane prints and Transpose renders, above or below stopped-lane prints.
- **Starvation.** Starvation of the recipe is bounded by the 250 ms settle debounce (`engine_cache.h:33`). It is not impossible: 4 job slots with continuous re-keys can hold it off. Add a bounded-wait or aging rule.
- **Transpose reversal.** §4.6 renders Transpose "through the same offline transposition function the kind-1 cache job uses". In 3a that is `le_stretch_render_loop` over a whole lane, unsliced (`p3a engine_cache.c:1466-1497`). Inside a recipe it breaks the "one slice" bound, and it repeats work the cache has already published as the SOURCE entry. Stage the key-matched published source render, or slice the stretch per lane.
- **Memory.** 3a raises `LE_CACHE_DEFAULT_CAP_BYTES` to 384 MiB. The recipe adds a separate fixed 512 MiB. Size `LE_RENDER_MAX_BYTES` against the cache cap and the device, not as a constant, and record both on the appliance in the Part 1 hardware criterion.

**M8. Stale group redo entries have no dissolution rule.**
- Case: Bounce, Undo, then a new edit on the destination. That edit retires the destination's redo branch, but each restored source keeps a redo-side `CLEAR(group)`.
- Plain redo on such a source is refused INVALID (§5.4), and the group redo is refused TRACKS_CHANGED. The source's Redo is stuck until some other edit retires it.
- Clear All's ledger dissolves broken groups (`_intactClearAllGroup`, `looper_repository.dart:3420-3445`).
- Fix: when any member's redo branch is retired, retire the group's redo entries on every member. Test it.

### Low

- **L1. Citation drift:**
  - `a_len` is `engine_private.h:491` and is a lane field, not `:490`.
  - `le_mode_base_channel(e, mode)` (`:2224`) takes no exclusion mask, so the "tracks that will still hold content" base needs a new variant.
  - USB P4 at `a10cd2387` has `withWriteLease` at `:232`, `space` at `:394` and `copyFile` at `:484` (plan: 192-207/314/388-422).
  - Library P3's Sessions tab is at `library_page.dart:155`.
  - Peel P2's undo-side CLEAR rule is at `engine_session.c:304`.
  - The ledger already lists kind 5, so "Not in the ledger yet" is stale.
- **L2.** `le_peel_depth` already stops at any kind other than LAYER and PEEL (`engine_commands.c:91-99`). Part 4a's "Peel depth exclusion" needs only a test, not a code change.
- **L3.** `le_transform_reset` resets capture provenance, and its comment forbids non-EMPTY callers from doing so casually (`engine_process.c:236-247`). §5.3 should order the reset before the image staging and publish, and the #1143 test should cover a destination that was occupied at arm.
- **L4. events.log version.** The format doc says the version "covers the code vocabulary" (`performance-event-log-format.md:38`), and version 7 was bumped for 324/325. Under the ledger rule, 332 therefore takes the next version at landing, not "no bump" (§5.6).
- **L5. Free/Song destination.** With Clear sources, the destination starts at position 0 (§5.3), which is an audible jump against sources at arbitrary phase. Scope the Part 4b sample-exact continuity test to shared-clock modes and document the Free/Song behaviour.
- **L6. Pen captions.** The plan table's "Exit without applying" and "Exit, result kept" are behaviours: every pen step reads only "Exit". Stop on the sources and done steps is drawn as "Back / Sources" dimmed, not blank. `meZ1X` shows a "Selected" hint on a selected source pedal. Spell out captions so the goldens match the pen.
- **L7.** The legacy bundle `_mixdown` LCM is uncapped (`session_repository.dart:818-822`). A save with coprime Free lengths can allocate an unbounded buffer. Put that risk in the S1 follow-up issue.
- **L8. Save audio to USB.**
  - Check space on both Internal (where the render lands) and the drive.
  - The audio library UX doc names conflict choices "Cancel, Rename or Replace file", but the plan uses Keep both / Replace. Reconcile the two.
  - Name #1198's `wav_codec` header read for the listing's duration, and #1223's `le_backing_decode_file` for preview and Use as backing, so no new reader appears.
- **L9.** B2 does not reset track Mono because trunk has none. The policy's `mono:false` and the processing proposal's "resets … Mono" mean the reset table must grow when Track Mono lands. Add a sentence so that part does not miss it.

## Planner's three questions, judged against accepted behaviour

1. **Fade in the render.** The policy's `recipe()` keeps `fade` on the source and resets it on the destination "so it is not printed twice". Printing the frozen amount is therefore the accepted contract, not an open question. Rendering a faded-out track as silence is still an unannounced result (rule 3). Keep the default, have `measure` report a `faded_mask`, and show "Track N is faded out" before the render.
2. **Plugins dry.** AB §3.11 says "runnable Post processing", which supports dry-with-notice as the boundary. One caveat: a plugin in Pre belongs to the take (§3.5), and the cache cannot print it either. The notice should name the tracks affected. A second offline instance is a later product decision. Keep the default.
3. **Mono destination.** The policy fixes `destination.mono:false`, and the processing proposal resets Mono. Stereo is the accepted behaviour, so this is not a direction question. The real gap is H5, overdubbing onto the stereo destination, which the plan has to settle.

## Decisions scrutinized (summary)

- **Executor on the cache worker (R1).** Right under rule 4. It needs the M7 priority, starvation, Transpose and memory rules.
- **Exact LCM capped at 1024 beats (R7).** Exact for shared-clock modes, because lengths are integer multiples or divisions of the base. M1 is a hole. Most Free-mode sets will refuse, which is acceptable only with a clear notice.
- **Freeze command (R3).** Needs H1 (complete read law) and M4 (no wait for a top).
- **Wrap/Cut (R4).** Reusing the cache's two-pass rule is sound. Fix H3 and M2.
- **"As heard" with global Speed (R5).** Sound: Speed is applied once outside the bounce. After P2a, the freeze must capture the read-head phase (H1).
- **One-block install with command 113 and group Undo with 114 (B1).** The right answer to §2.11's "publish together". Fix H2 and H4.
- **`LE_HIST_BOUNCE` = 5.** No collision with LENGTH 4 (M/D P1) or Peel P2's kinds. `group_id` sits beside M/D's new `start` field in `le_hist_entry`, which is a textual merge conflict depending on landing order.
- **Destination reset table (B2).** Matches the policy except lane topology, input routing and balance (H4, H5) and future Track Mono (L9).
- **Dropping the Bounce Undo at save (B4).** Consistent with how trunk drops Clear points, and acceptable with a notice. The redo-side cut (H6) is required.
- **Consolidation.** WAV writer (M6). The backing decoder #1223 and `wav_codec` should be named as the only readers (L8). The legacy exports are correctly left to Library P1, and the bundle mixdown is deferred with a follow-up (L7).

## Notes

- Pen (via pencil MCP): sections 17, 18 and 49 have no `c/` rationale notes. No pen text covers mono/stereo, plugins or Fade in a bounce or save context. "Tracks changed", "Loop exceeds length limit" and the policy's no-common-cycle sentence come from the study and policy JS, not the pen.
- The plan is well sourced, and its trunk citations are among the most accurate I have checked. The findings are design gaps in the Bounce commit path and the shared-material topology, not citation errors.

Verdict: Request changes

## Delta review (c73995889)

### Scope

- PR #1225 at `c73995889` (`origin/claude/render-bounce-plan-1202`): two commits since my review of `ea66b0351`:
  - `c36301920`, the revision for H1-H6, M1-M8 and L1-L9;
  - `c73995889`, the Part 1 build record, plus the Once wording.
- I read the whole revised plan (1,733 lines) and diffed it against `ea66b0351`.
- Each finding was checked against the revision and, where Part 1 now builds it, against the code on `origin/claude/render-1202-p1` at `88390a548` (PR #1238, reviewed separately in `render-p1-in-session/review.md`).
- Claims I re-verified on the trunk for this delta:
  - `le_apply_routing` grows lanes from `lane_count_mask` (`engine_process.c:2686-2723`);
  - the live mixer never engages a print on a reversed track (`:5976-5980`, `:6137`, `:3330-3337`);
  - `le_cache_ensure_budget` evicts published entries.
- Pen: the revised §6/§8 adopt exactly the `M9kyGb`/`op31E`/`bx7vK` readings I took through the pencil MCP in the first round. Nothing in the delta needed a new pen read.

### Runs

- Plan review only. The Part 1 suites and probes behind the code-backed rows below are in the Part 1 review: native x3, TSAN, ASAN, telemetry-off, Dart, app, byte-identity, probes and mutations.

### Status of the first-round findings

| Finding | Status | Where |
|---|---|---|
| H1 read law | Resolved. The freeze records `reversed`, `playback_offset` and the segment origin, and applies at the next drain. Built and tested (`test_render_live_phase_and_reverse_offset`). The Once relaunch is still untested (build record) | 4.4 |
| H2 all-empty reset | Resolved. The destination is installed before any clear, and the re-clock keeps `loop_iteration`. Part 4b has the every-track-into-empty test | 5.2 step 4, 5.3 steps 2 and 4 |
| H3 doubled Post tails | Resolved. Wrap clears the cleared sources' Post and track tails in the 113 drain; Cut lets them drain. Both are tested in 4b | 5.3 step 4, B6 |
| H4 topology and Dart intent | Resolved. The topology rides in 113 through `le_apply_routing` (verified: it grows lanes), Undo handles lane count with the `a_recoverable` lag, and `_MixIntent` commits counts, balances, inputs and routes | 5.2 step 5, 5.4, 5.5 step 5 |
| H5 overdub routing | Resolved. A grown lane 1 mirrors lane 0's input, and centre pan is unity, so a mono overdub plays centred | 5.5 step 3, B5 |
| H6 saved session after Undo | Resolved on paper. Both export sides cut BOUNCE and grouped entries, with recall round trips in 4a/4b | 5.4 Persistence |
| M1 no tempo | Resolved and built. A 512 s cap, `tempo_set`, chosen length refused, and both notices | 4.4 |
| M2 Cut cuts Pre | Resolved and built, but it opened new finding D-H1 below | 4.3 |
| M3 Mix FX twice | Escalated to the owner as §11, with default (a) | §11 |
| M4 wait for a top | Resolved and built (freeze at the next drain) | 4.4 |
| M5 defaults and folder | Resolved. Recorded tracks are preselected, "Saved audio" is a folder, §8 is corrected | §6, §8 |
| M6 one WAV writer | Resolved and built (`engine_wav.c`). The 84-byte layout matches #1198's `RecordedPartHeader` on PR #1227. The file target charges one slice | 4.7 |
| M7 contention | Partly resolved. Priority, aging, the shared cap and staging the published SOURCE entry are specified. Two consequences are not stated: D-M2 and D-L1 below | 4.1, 4.7 |
| M8 stale group redo | Resolved | 5.4 |
| L1 citations | Resolved (spot-checked `:491`, `:2224`, the USB lines, Library `:155`, Peel `:304`) | throughout |
| L2 Peel depth | Resolved (test only) | 5.6 |
| L3 provenance order | Resolved | 5.3 step 1 |
| L4 events.log version | Resolved | 5.6 |
| L5 Free/Song phase | Resolved (documented; continuity test scoped to shared-clock modes) | 5.3 step 2, 4b |
| L6 pen captions | Resolved | 7.2 |
| L7 unbounded mixdown LCM | Resolved (follow-up issue) | §6 Legacy |
| L8 Save audio to USB | Resolved (space on both volumes; Cancel/Rename/Replace; one reader each) | §6 |
| L9 Track Mono | Resolved | 4.6 |

### The new Once rule against AB §3.11 ("Once contributes once then silence")

The rule: a pass that runs past the window end continues at the window start (4.4, plan `:442-449`).

**On a common cycle, accept it.** A common-cycle window is a multiple of every span, and it is itself a loop.
- Wrapping keeps every sample of the pass exactly once and keeps the pass in phase with the other sources. That is "contributes once".
- Clipping, the old wording, would contribute less than once: it drops the end of the pass a relaunched source plays across the top.
- The rest of the window is silent, which is the "then silence".
- The Part 1 code does this correctly. A probe with a Once relaunched at a non-zero origin, alone on a 16-frame cycle, reads `3..16, 1, 2`.
- When the span equals the window there is no silent part, and that is inherent: one pass fills the loop.

**On a chosen length, the rule is wrong as built and underspecified as written.**
- *Not a multiple of the span.* The code wraps the pass by window phase but still reads the live law's index, so the wrapped part plays the wrong part of the take instead of continuing the pass. Probe: span 30,000, window 38,400, d = 20,000; 11,600 wrapped frames read indices 10,000.. instead of 18,400... This is Part 1 review M3.
- *Window shorter than the span.* The pass cannot fit. The code then sounds on every frame, and the plan does not say what should happen.

**Requested text.** "On a common cycle the pass wraps. On a chosen length the wrapped part continues the pass from the lap index `p = (f − d) mod W`. A window shorter than the span renders one pass from d, truncated at the window." Add tests for all three cases; today no test covers the wrap (a mutation that clips survives).

### New findings in the revision

**D-H1 (High). Pre for a reversed source.**
- **Where.**
  - 4.3 (`:349-352`) says the lane's Pre material is the cache print "byte-identical to the published print whether or not the print is engaged".
  - The 4.6 Reverse row (`:484`) prints Reverse by reading through the frozen law.
- **Why that is wrong.** The live rig never plays a print on a reversed track. A print engages only on a forward track and a toggle disengages it (`engine_process.c:5980`, `:6137`, `:3330-3337`). The mixer comment reads: "reversing a loop reverses the recording, not its effects, so the live chains run forward over the backward read."
- **Failure.** The plan as written, and Part 1 as built, play the forward print backwards: a reverse echo or swell where the player heard a normal echo after each note.
- **Probe.** A Pre delay of 2,400 frames on a reversed 6,000-frame loop:
  - live: echo 2,400 frames after the impulse;
  - render: echo 2,400 frames before the next impulse.
- **Fix.**
  - State in 4.3 and 4.6 that a reversed source's Pre (lane and whole-track) is printed over its reversed lap: dry in read order, wrapped at `len`. That is the steady state of the live forward chain over the backward read.
  - Add the reversed-Pre live-parity test to Part 1's list.

**D-M1 (Medium). Once on a chosen length.** As above.

**D-M2 (Medium). Sharing the cache cap evicts live prints.**
- **Where.** 4.7 (`:531`) charges the job "through the same `le_cache_ensure_budget` LRU eviction the cache uses". The plan does not state the consequence.
- **Failure.**
  - A Save audio started mid-performance can evict the engaged Pre print of a playing track. The lane drops to its live Pre through the clean re-enable path, an audible restart of the wash (rule 3).
  - The job holds its bytes until cancel, even after a file is published, so the print cannot come back until then.
  - Proven by a probe on Part 1.
- **Fix.** The plan must choose and state one of:
  - never evict prints published for PLAYING lanes (refuse with `CAPACITY` instead);
  - give the recipe its own budget.

  It must also release a file job's buffers at DONE.

**D-L1 (Low). The slice bound.** 4.1 (`:290-293`) and 4.7 (`:552-559`) promise that a long render never holds an audible print back "by more than one slice". The lane and track prints are setup units of two passes over the source length. Either slice them or say the bound is one source-length print.

**D-L2 (Low). The build record under-reports test deviations.**
- It names two omitted tests.
- In fact Part 1 also built weaker versions of:
  - `test_render_excludes_buses` (no monitors, click, master gain or limiter);
  - `test_render_wrap_vs_cut_tail` (an energy check, not equality with pass 2);
  - `test_render_fade_frozen_amount` (no fade moving during staging);
  - `test_render_origin_phase` (no Free source);
  - `test_render_staging_tracks_changed` (a Clear, not an overdub admitted while staging).
- No test covers the whole-track print or a track chain at all (Part 1 review M4).

**D-L3 (Low). §11 default ships a pen deviation before the answer.** "Until the owner answers, Part 6 builds (a)" removes `meZ1X`'s Mix FX row, a pen deviation, ahead of the answer. §8 lists that write-back only "if §11's question is answered with (a)". Add it to §8 unconditionally while (a) is the built default, or have Part 6 wait for the answer.

### Notes

- The revision is careful and closes every first-round High. The numbering stays inside the ledger. The H4/H5 answers (structural topology through `le_apply_routing`, mirrored input) are the right shape, and I verified the `le_apply_routing` lane growth they rely on.
- Plan text and build disagree in two places, both harmless:
  - 4.7 still names `wav_writer.c` and a `CANCELLED` state, while the build has `engine_wav.c` and retires a cancelled id;
  - the build record explains the first; the second should be edited.

Verdict: Request changes (D-H1 and the chosen-length Once rule must be settled in the plan before Part 1 merges)

## Delta review (0f1297987)

### Scope

- PR #1225 at `0f1297987`, three commits since `c73995889`:
  - `f2c9c0a4f`, the owner's Mix FX decision;
  - `dd864387a`, the Part 2 build record;
  - `0f1297987`, which settles reversed Pre, Once on a chosen length and the render budget.
- I read the whole diff against `c73995889` and checked it against the Part 1 code at `1ac22cb9b` and the Part 2 code at `eebc8b160`, both reviewed separately. Their suites, probes and mutations back the "built" claims below.

### Status of the c73995889 delta findings

| Finding | Status |
|---|---|
| D-H1 reversed Pre | Resolved. 4.3 prints a reversed source's Pre (lane and track) over the dry in read order, and the 4.6 Reverse row says so. Built and verified by live-parity probe and test |
| D-M1 Once on a chosen length | Resolved. The three cases are stated in 4.4 (common cycle wraps; chosen W ≥ len continues the pass phase; W < len is one pass from d, cut at the end). Built as written and tested literally |
| D-M2 shared cap evicts live prints | Resolved. The recipe has its own 256 MiB budget, never evicts, and releases on finish, and 4.7 states the worst case (cache cap plus budget). Built; the eviction probe shows the print kept |
| D-L1 slice bound | Resolved in 4.1. See L-E1 below for one stale sentence |
| D-L2 build record | Resolved. Every weaker or missing test is listed |
| D-L3 §11 | Resolved. The owner decided (Bounce without Mix FX), §8 item 2 records the `meZ1X` write-back, and the Part 6 golden criterion excludes the row |

### On the Once rule as now written (AB §3.11)

All three cases satisfy "contributes once then silence" as far as one window can:
- on a common cycle and on W ≥ len, every sample of the pass sounds exactly once and the rest is silent;
- with W < len the pass cannot fit, and a truncated single pass is the honest reading.

One gap remains. When the pass start `d` lies at or after a short window's end, the source contributes nothing at all. A probe on Part 1 gave 0 sounding frames. The plan should name that case, and the measure should report it (Part 1 delta L-D1), so the player is told rather than surprised.

### New findings

- **L-E1 (Low). One stale sentence on the slice bound.** 4.7 "Worker scheduling" (`:603-606`) still ends "a slice never holds a playing print back by more than one slice". 4.1 (`:290-296`) now correctly says "one slice or one source-length print". Make 4.7 agree.
- **L-E2 (Low). The writer's consumers are listed without the seal truncation.** 4.7's writer bullet (`:623-628`) lists #1198's use of `le_wav_flush` and `le_wav_patch_sizes`. It does not mention the seal truncation that #1245 already depends on (Part 1 delta M-D1). Add "seal truncates the file to header plus data" to the writer's contract, so whichever branch lands second keeps it.
- **L-E3 (Low). The build record overstates the writer's fit.** It says #1245 "rebases onto this part without reaching into the writer". #1245 still rewinds `w.file` itself after a torn write, and its salvage patches sizes in Dart. Reword it, or have #1245 move onto `le_wav_flush` and the seal truncation and record that.

### Notes

- **Budget arithmetic.** The plan's figure checks out: eight stereo 30 s tracks at 96 kHz stage 176 MiB. Pre-heavy sets can still exceed 256 MiB, because each Pre lane print is twice its dry. Part 1's build record should note that limit for the appliance criterion.
- **Cache figure.** Pitch/time 3a's cap is now 192 MiB on `origin/claude/pitch-time-1179-p3a`. The plan's figure is updated to match.

Verdict: Approve
