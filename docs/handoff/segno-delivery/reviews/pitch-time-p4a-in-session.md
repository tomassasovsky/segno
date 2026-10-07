Model: Claude Opus (subagent), in-session

# Review of PR #1253 (origin/claude/pitch-time-1179-p4a, d76bcaac8): feat(engine): retime the song clock when the tempo changes with Follow tempo on

## Scope

- **The commit:** one commit, `d76bcaac8`, on top of 3b (`50fc651f9`). It touches 16 files; 555 production lines (core and API, excluding tests, bindings and docs).
- **What it adds:**
  - the recorded tempo latch;
  - Follow tempo default and per-track override (command 120, receipt);
  - the lock relaxation for set and tap;
  - `le_tempo_retime` with divisor rounding and position scaling;
  - the per-take span model (`span_clock`, `le_head_rate = speed x len / play_len`);
  - the detached head for non-followers;
  - punch-in guards (control and callback);
  - the history fit against the recorded master;
  - mode switch back to the recorded tempo;
  - snapshot fields;
  - facts 329 (`HEAD_SPAN`) and 330 (`RETIME`), events.log version 10, and renderer replay;
  - `test_engine_tempo_follow.h`.
- **Reviewed against:**
  - plan §4.1-4.3, Part 4a and its "As built" note, and decisions 4 and 21;
  - the numbering ledger (extension 120-123; facts 328-331);
  - accepted-behavior §2.6;
  - the pen's 07/04-06 (reN7g, MfjIH, hujmY) through the pencil MCP (not saved);
  - the MIDI clock plan (`origin/claude/midi-clock-plan-1228`, D4);
  - Multiply/Divide P1 (`origin/claude/multiply-divide-1168-p1`, PR #1212);
  - AGENTS.md and the owner rules.

## Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | conflicts in `segno_engine_api.h` and the regenerated bindings only: the trunk's `LE_ERR_NOT_FOUND`/`LE_ERR_TRUNCATED` (#1198) sit where this stack adds `LE_ERR_TRANSFORMED`. Both are kept by hand, then ffigen is re-run. A rebase chore, not a defect. |
| `git merge-tree` against `origin/claude/multiply-divide-1168-p1` (via 4a-ii) | 11 conflicting files (engine.c, engine_commands.c, engine_process.c, perf_log_ring.h, the API header, bindings, tests and the format doc) |
| Native suite, plain / ASAN / telemetry-off | ALL PASSED x5 each, exit 0 |
| `flutter test` packages/segno_engine | +380, all passed |
| `dart analyze --fatal-infos` on segno_engine and looper_repository | clean |
| 6 mutations (F1-F6, through 4a-ii's head) | 6 killed |
| Reviewer probes (`test_rv_probes4a.h` and `test_rv_probes4a2.h`, saved beside the 4a-ii review) | below |

| Mutation | Killed by |
|---|---|
| F1 no callback punch-in drop off span | `test_follow_new_take_at_new_tempo` |
| F2 no control punch-in guard | `test_follow_*` (4 checks) |
| F3 no history fit against the recorded master | `test_follow_clear_undo_keeps_ratio` |
| F4 retime allowed during capture | `test_follow_guards` |
| F5 mode switch keeps the retimed tempo | `test_follow_division_and_mode_switch` |
| F6 no 329 at PERF_ARM | `test_follow_arm_while_retimed` (stem parity) |

## Verified correct (traced)

- **An exact round trip at the exact recorded tempo.** `to = ref_len` when `bpm == ref_bpm` (`engine_process.c:3069`), so the span returns to the take's length, the rate to the Speed, and the head to identity. The test proves it bit-exact, and my probe confirms it at 117.33 recorded and requested.
- **Phase and continuity.**
  - A following track keeps its origin while the rate becomes `len / play_len`. Its index stays locked to the clock: `r2 x pos_new = r1 x pos_old`, up to the position's integer truncation (see L1).
  - A non-follower re-origins and reads on at its own lap.
  - A window still mixing keeps mixing, its old head re-origined.
- **Divisions.** `to` is rounded up to a whole multiple of the largest active Sync divisor, so `base / n` stays exact. The span of a division `(len x to) / span_clock` is then exact.
- **Punch-in guards.**
  - Control refuses with `LE_ERR_TRANSFORMED` when `span_clock > 0` and it is not the master; the callback drops a press that a retime overtook.
  - This applies to followers and non-followers alike: a non-follower's read is detached, so a write at the clock position would not land where it is heard.
  - F1 and F2 are killed.
- **Lock.** Retime only with content, a bar grid, a follower, and nothing capturing, armed or counting in (`le_speed_change_safe`). Otherwise today's lock holds and the snapshot says why (`tempo_follow`). F4 is killed.
- **Reverse.** A retime with a reversed follower keeps the head reversed and moves the rate (probe: steps -0.75 at 90, -1.0 at 120). There is the same sub-sample discontinuity at the change as forward (L1).
- **Peel.** Peel swaps between slots of the same length, so the span model applies unchanged. A new layer cannot be laid on an off-span take (the punch-in guard), so a retimed take gains no peelable layer while off span.
- **Tap tempo.** A tapped pair retimes (probe: a 75 BPM pair gives master 12800, rate 0.625, punch-in refused).
- **Real-time safety.**
  - `le_tempo_retime` and `le_head_follow` are bounded loops over 8 tracks, with no allocation and no lock.
  - `llround` is a pure libm call. The callback's existing rule is "no libm" for the head; this is one call per tempo command, which is acceptable.
  - `le_tempo_follow_now` (snapshot) runs on control.
- **Renderer parity.**
  - 329 carries the span and the exact index; 330 the new length and position.
  - `le_pr_apply_span` re-anchors at the logged index, and a capture armed while retimed logs 329 at arm.
  - Parity tests exist, and F6 is killed.
- **Numbering.** Command 120 and facts 329/330 are inside the ledger's extension (120-123) and range (328-331). events.log version 10 is assigned at landing.
- **"Follow tempo off by default" against accepted-behavior 2.6.**
  - §2.6 names no default. It says what On and Off do, and that the pitch preference survives Off.
  - The pen's Defaults screen (reN7g) shows Follow tempo **On** and Pitch **Unchanged** selected (bright text on On and Unchanged).
  - Shipping Off until Part 4b's page exists (E15, decision 21) keeps every existing rig as it is today (rule 1), and Part 4b flips it to On together with the page.
  - So Off here is consistent with 2.6 and is a planned, temporary departure from the pen, not a contradiction. When 4b flips it, a tempo change on a rig with content stops being locked; that change ships with the page that explains it.

## Findings

### High

**H1. After a retime, clearing the last track loses its Clear Undo.**

- **Where:** `le_engine_history_mode_gate` (`engine_commands.c:2345`), `retimed = master > 0 && base == master && rec > 0 && rec != master`.
- **Cause:** once the last track is cleared the master is 0, so `retimed` is false. The restored take (recorded length) is checked only against the saved retimed base, and the gate answers `LE_ERR_MODE_MISMATCH`.
- **Probe:**

  | Sequence | `le_engine_undo` |
  |---|---|
  | 120 BPM, Follow on, Clear the only take, Undo | rc 0 (track PLAYING, master 8000) |
  | Same, but set 90 before the Clear | rc -7; track stays EMPTY, master 0 |

  The same probe fails identically on 4a-ii's head.
- **Why it matters:**
  - Clear Undo is the recovery path for a destructive gesture (rule 2).
  - The engine keeps `rec_bpm` and `rec_master_len` through the all-empty reset precisely "for a Clear Undo" (`engine_private.h`), but the gate does not use them when the master is 0.
  - The existing test clears a second track while track 0 holds the clock, so it never reaches this case.
- **Fix:**
  - When the master is 0 and a recorded reference exists, fit the restored take against `rec_master_len` as well as the saved base.
  - Have `le_restore_track_clock` re-establish the retimed clock, or the recorded one at the recorded tempo.
  - Add the clear-all-then-Undo case after a retime.

### Medium

**M1. The way back to the recorded tempo is exact only for the exact float, so a rig can be stranded off span with overdub refused.**

- **Where:** `bpm == ref_bpm` (`engine_process.c:3069`).
- **Cause:** any other value scales `ref_len x ref_bpm / bpm` and rounds.
- **Probe:** recorded at 117.33, set 90, then set 117.3 (what a one-decimal display or field sends). The result is master 8002 (not 8000), rate 0.999, and `le_engine_record` returns -10. At exactly 117.33 everything is exact.
- **Who hits it:**
  - a tap pair, which never lands on the recorded float;
  - a MIDI clock tempo (#1228's 0.05 BPM real-change threshold);
  - any UI that rounds the tempo it shows.
- **Effect:** the takes stay off span, overdub is refused (decision 4), and prints stay off, with no visible reason beyond "transformed".
- **Fix:**
  - Snap to `ref_len` when the scaled length is within the rounding a tempo change can express. For example, if `|to - ref_len|` is within the divisor rounding, or `|bpm - ref_bpm|` is under 0.05 BPM, use `ref_len` and `ref_bpm`.
  - Expose the recorded tempo so Part 4b can offer "back to recorded".
  - Test with a non-round recorded tempo.

**M2. The new length deviates from plan §4.2 without a label, and the MIDI clock plan relies on the plan's rule.**

- **What the plan says:** §4.2 (`plan:607`) sets `L_new = round(bars x frames_per_bar(new))`.
- **What was built:** `ref_len x ref_bpm / bpm`, the recorded length scaled. The commit message says so, but the plan text and "As built" do not.
- **When they differ:** whenever the recorded master is not a whole number of bars at the recorded tempo, for example a human-timed take with the bar count rounded to a set tempo (`sync_grid_to_loop` never alters audio length).
- **Effect under an external clock:** the MIDI clock plan (`2026-10-06-feat-midi-clock-plan.md:177-178`, D4) quotes the plan's rule. Its slips (at most 2 ms per wrap) keep a bar-exact loop locked through crystal drift. A loop off its bars by ε stays ε off after the retime, so at 0.5 % on a 2 s loop it drifts 10 ms per lap, five times what a slip can absorb.
- **The trade-off:** the as-built rule is what gives M1's exact round trip, so neither rule is simply wrong.
- **Fix:** decide in one place and record it in §4.2 and in #1228's plan. One option: bar-exact `bars x fpb` under an external tempo source, the recorded-length scale otherwise, with M1's snap at the recorded tempo.

**M3. Multiply/Divide (#1212) is not compatible with a retimed rig, and whichever lands second must handle it.**

- M/D P1 (`origin/claude/multiply-divide-1168-p1`) is written against the pre-read-head engine (`t->reversed`, `playback_offset`). It conflicts with this stack in 11 files.
- Its master re-clock (`le_length_apply`, `reclock > 0`) sets `e->clock` to the new take length in take frames. On a retimed rig that silently drops the retime for the master, while every other follower keeps a `span_clock` measured against the old clock, so `play_len = len x clock / span_clock` gives wrong ratios.
- Its swap stores `a_live` directly rather than through `le_track_publish_live`. That is safe for the Transpose content key (a fresh revision), but not cache-hot.
- **Fix:** either refuse a length edit on a track or rig that is off its span (the same rule as punch-in, `LE_ERR_TRANSFORMED`), or map the edit through the span (`len` and `span_clock` scaled together). Add a test in the PR that lands second. Record this as a landing requirement on #1212 and #1253.

### Low

**L1. Every retime moves a following head by up to a sample, and a round trip loses a frame of phase.**

- **Where:** `e->clock.position * to / from` truncates (`engine_process.c:3093`), and no window covers the rate change.
- **Probe:** with an output ramp:
  - the first step after 120 to 90 is 0.68-0.69 (expected 0.75);
  - after 90 to 120 it is 0.06-0.07 (expected 1.0);
  - reversed, -0.35 to -0.41.
  - Fifty immediate 90/120 pairs leave the master position 50 frames behind (5151, against 5201).
- **Effect:** a sub-sample click on bright material at each retime. The phase loss is relative to wall time, the click track and MIDI clock out (all tracks share it). The MIDI plan's slips will absorb the phase loss, but the clicks remain.
- **Fix:** carry the position's fractional remainder across retimes, or run the rate change through the equal-gain turn window the head already has.

**L2. Two more departures from §4.2 are not labelled.**

- A non-follower re-origins on the shared position instead of the plan's private counter that re-attaches at Stop/Play.
- "Free/Song private clocks scale" is labelled (no grid), but the detached-head change is not.
- **Fix:** add both to "As built".

**L3. A retime that cannot fit is silent.** `le_tempo_retime` returns 0 when `to` leaves `1..max_loop_frames` (`:3080`). The caller ignores it, the tempo does not change, `LE_CMD_SET_TEMPO` has no receipt, and the snapshot still reads `RETIMES`. I could not reach it in my fixture (the 30 BPM floor reached exactly 4x the take with a 4x cap), but it is reachable with a cap closer to the loop. Report it in `tempo_follow` or a fact.

## Notes

- **Mode switch.** A mode switch returns a retimed song to its recorded tempo (labelled in "As built"). That resets a tempo the player chose, so Part 4b's page should say so.
- **Session recall.** Recall in Part 4b must restore the recorded tempo before the commit and any retimed tempo after it. `LE_CMD_RESTORE_TEMPO` latches the restored tempo as the recorded one, so restoring the retimed tempo would re-label the takes as recorded at it.
- **Size.** 555 production lines, under the 700 ceiling. The Dart seam moved to 4a-iii (labelled).

Verdict: Request changes (H1; M1-M3).

## Delta review (0eacc5adb)

Model: Claude Opus (subagent), in-session

### Scope

- `ecc4aefbc`: the rebase of `d76bcaac8` onto trunk `890f04936`. `git range-diff` shows context only: the trunk's packed `a_speed_ratio` and its `LE_ERR_NOT_FOUND`/`TRUNCATED` codes.
- `0eacc5adb` "fix(engine): restore the last take after a retime, snap home, keep lengths on the bar".

### Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | clean |
| Native suite, plain / ASAN / telemetry-off | ALL PASSED x5 each, exit 0 |
| My earlier probes, rebuilt on 4a-ii's head `5d5318fb7` (this commit unchanged underneath) | below |
| 5 mutations on the fixes (`mutate5.py`, saved with the 4b review), through the follow and pitch tests on 4b's head | 5 of 5 killed |

| Mutation | Killed by |
|---|---|
| H1 no snap to the recorded tempo | `test_follow_snap_to_recorded`, `test_follow_length_on_the_bar` |
| H2 history gate without `a_retime_len` | `test_follow_clear_last_take_undo` (7 checks) |
| H3 the restore latches the tempo in force | `test_follow_clear_last_take_undo` |
| H4 no fractional carry of the position | `test_follow_retime_no_click_no_drift` |
| H5 no turn window at a retime | `test_follow_retime_no_click_no_drift` (41 checks) |

### Status

- **H1, fixed.**
  - With no master left, the history gate fits the restored take against the kept recorded master when the saved base equals `a_retime_len` (`engine_commands.c:2351`).
  - The restore re-establishes the retimed clock with the take at its ratio, and re-publishes the kept recorded tempo instead of latching the tempo in force (`engine_process.c:1487-1497`).
  - My probe: retime to 90, Clear the only take, Undo. Undo returns 0, master 10667, recorded 120, rate 749, and the way back to 120 gives master 8000, rate 1000 and a punch-in allowed.
- **M1, fixed.**
  - A tempo within `LE_TEMPO_SNAP_BPM` (0.05) of the recorded one returns to the recorded tempo and length exactly (`:3088`).
  - My probe at 117.3 with 117.33 recorded: master 8000, rate 1000, punch-in allowed. The published tempo reads 117.33, the recorded value, not the 117.3 sent, which is the honest answer.
- **M2, fixed.**
  - The new length is `round(bars x frames_per_bar(new))`, so an external clock finds the loop on its bars; the snap preserves the exact round trip.
  - `test_follow_length_on_the_bar` pins an off-bar master (8010 → 10667 at 90, back to 8010 at 120).
  - Recorded in "As built".
- **M3, deferred as a landing requirement.** Recorded in "As built": whichever of #1212 and this part lands second refuses or scales a length edit off span, with the named test.
- **L1, fixed.**
  - A sounding follower opens the turn window at a retime, and the clock position carries its fraction across retimes (`:3120-3144`).
  - My probe: the first steps after each retime are now 1.0 or 0.75 (the rate's own slope), forward and reversed, with 0 steps outside [0.4, 1.5] over 50 alternating retimes. Fifty immediate 90/120 pairs leave the position one frame from the expectation (5200 against 5201) instead of fifty.
- **L2 and L3, labelled** in "As built". The silent retime refusal (L3) stays a follow-up.

### Findings

None new.

### Notes

- One frame remains after fifty pairs, where there used to be one frame per pair. I did not run longer sequences to see whether it grows.

Verdict: Approve.
