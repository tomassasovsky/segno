Model: Claude Opus (subagent), in-session

# Review of origin/claude/pitch-time-1179-p4a2 (508e2a9e7, stacked on #1253): feat(engine): keep a following track's pitch across a retime with a stretch render

## Scope

- **The commit:** one commit, `508e2a9e7`, on top of 4a (`d76bcaac8`). It touches 19 files; 343 production lines.
- **What it adds:**
  - `le_stretch_render_loop` with an output length (fold scaled);
  - source renders with their own `out_len`;
  - `le_src_entry_fits` with the 0.5 % tolerance (`LE_SRC_STRETCH_TOLERANCE_PER_MILLE 5`);
  - `le_track_want_out` and `le_track_play_span` from published fields;
  - `le_head_read_scaled` in the callback and the renderer;
  - the dry-through-varispeed pending rule with `pitch_effective_cents`;
  - Pitch default and per-track overrides (command 121, receipt; default 0 = Unchanged);
  - fact 331 (`SOURCE_LEN`), events.log version 11;
  - `test_engine_pitch_keep.h`.
- **Reviewed against:**
  - plan §4.3 and the 4a-ii "As built" note;
  - the ledger (121, 331);
  - the pen's 07/04-06 (Pitch Unchanged is the Defaults screen's selection);
  - the MIDI clock plan's D4 (real tempo changes at 0.05 BPM);
  - 3a's joint budget text;
  - AGENTS.md and the owner rules.

## Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | conflicts in `segno_engine_api.h` and the regenerated bindings only: the trunk's `LE_ERR_NOT_FOUND`/`LE_ERR_TRUNCATED` (#1198) sit where this stack adds `LE_ERR_TRANSFORMED`. Both are kept by hand, then ffigen is re-run. A rebase chore, not a defect. |
| Native suite, plain / ASAN / telemetry-off | ALL PASSED x5 each, exit 0 |
| `flutter test` packages/segno_engine / looper_repository | +380 / +816, all passed |
| `dart analyze --fatal-infos` on both packages | clean |
| Mutations G1-G3 (`mutate4.py`, saved here) | 2 killed, 1 survived |
| Reviewer probes (`test_rv_probes4a.h`, `test_rv_probes4a2.h`, saved here) | below |

| Mutation | Result |
|---|---|
| G1 no 331 before the 328 | killed (`test_pitch_render_parity`: the fact and stem parity) |
| G2 tolerance 0 | killed (`test_pitch_tolerance`) |
| G3 a playing follower's stretch render evictable | **survived** |

## Verified correct (traced)

- **One render, two jobs.**
  - The job renders the take at `want_st` (0 when bypassed) into `want_out` frames.
  - The key predicate stays the single `le_wet_entry_key_matches_kind`, with the length compared under the tolerance.
  - Bypass drops only the pitch and keeps the stretch.
- **Scaled read.**
  - `le_head_read_scaled` (`engine_read_head.h:151`) maps the take index by `out_len / len` and reads at `rate x k` in the render's frames.
  - The callback and `le_pr_render_track` call the same function, and any track sounding a render takes the head path (`stretched`).
  - Stem parity across the dry pending window and the swap is tested, and G1 is killed.
- **Pending rule (plan §4.3, decision 5).**
  - Until the stretch lands, the dry take plays through the varispeed: timing exact, pitch off by the ratio.
  - `pitch_effective_cents` reports it: -498 at 120 to 90 in the test, and 0 once the render plays.
- **Setting.**
  - Command 121 changes only the source selection; the head is untouched.
  - It is refused raw (`le_engine_post_command`) and excluded from the log like the other checked requests.
  - The default 0 (Unchanged) matches the pen's Defaults screen (reN7g: Unchanged selected).
- **Exact round trip.** Back at the exact recorded tempo, `want_out == len`. A non-transposed track then wants no render and plays its dry take at identity; a transposed one wants its plain transpose render, which is still cached.
- **Real-time safety.**
  - `le_head_read_scaled` adds a double division per lane-frame on tracks that sound a render.
  - `le_track_want_out` and `le_track_play_span` are a few relaxed loads per track per block.
  - There is no allocation or lock.
  - `pitch_effective_cents` (`log2`, `lround`) is computed on control in the snapshot.
- **Numbering.** 121 and 331 are inside the ledger; events.log 11 is assigned at landing.

## Findings

### High

**H1 (inherited from 4a).** Clear Undo of the last take after a retime is refused (rc -7). The probe fails identically on this head. See the 4a review.

### Medium

**M1. A retime inside the tolerance drops a transposed track to its true pitch, and makes every follower render.**

- **Where:** `le_src_entry_fits` (`engine_private.h:481-492`).
- **Cause:** the line `if (want_out == len || ent->out_len == len) return ent->out_len == want_out;` exempts the take's own length from the tolerance. A plain transpose render (`out_len == len`) therefore never serves a span within 0.5 %, and neither does the dry take.
- **Probe (`probe_transposed_small_retime`):**

  | Case | After 120 → 120.3 BPM (0.25 %, inside the tolerance) | Back after |
  |---|---|---|
  | Track at +5 st, engaged | `transpose_effective_st` drops from 5 to 0: the track sounds 5 semitones lower | 11 blocks of 256 at 8 kHz (about 350 ms, a 2 s take); seconds on the appliance for 30 s lanes |
  | Untransposed follower | renders a fresh stretch for a 4-cent change | — |

- **Why it matters:**
  - #1228 (D4) retimes on any real external change above 0.05 BPM.
  - A Follow-on rig under a MIDI clock would therefore drop every transposed track to its true pitch, and re-render every follower, at the first small tempo move.
  - That is a reported, audible regression for the case the tolerance exists to absorb.
- **Fix:** apply the tolerance to every candidate. A render of length `len`, or the dry take when the pitch is 0, serves any `want_out` within 0.5 % (the head absorbs the residual, as it already does for stretch renders). Add a test: a transposed track and a plain follower through a 0.25 % retime, no dry block, no new render.

**M2. The joint memory and CPU budget does not count the stretch renders this part creates.**

- **The cap:** the 192 MiB cap and the joint table (3a delta) are sized for eight transposed single-lane tracks plus one job.
- **What this part adds:**
  - With Pitch Unchanged as the default, every following track wants a stretch render after any retime beyond 0.5 %.
  - When 4b flips Follow to On by default, that is every tempo change on a populated rig.
  - Slowing down makes renders longer (x1.33 from 120 to 90).
- **Effect:**
  - On a dense rig most tracks are refused for budget and stay at the varispeed pitch (reported, but Unchanged is not what they get).
  - The worker re-renders up to 64 lanes per tempo move. At the ≥ 20x Part 1 floor, a 30 s 8 x 8 rig is about 96 s of worker time on a 4-core Pi beside the UI and instruments.
- **Fix:** add the retime case to the joint memory table and to the appliance list (eight followers x 8 lanes, 120 → 90, renders landed, peak RSS, late periods). Then decide, on those numbers, whether Unchanged renders need their own share of the cap or a per-retime priority (sounding tracks first). This is an owner-visible gate, like 3a's.

### Low

**L1. A playing follower's stretch render is protected from eviction, but no test pins it.** `le_ca_evictable` (`engine_cache.c:494`) protects it. G3, which makes stretch-only renders evictable, passes the suite. Add the cap-pressure case for a stretch render, as 3a has for a transpose render.

**L2. The pending rule makes every retime audibly change pitch for the render's duration.** The plan sanctions this (decision 5) and it is reported. With Follow On by default (4b), the face must show it. The listening check should include a retime on a sustained chord with Pitch Unchanged.

## Notes

- **Inherited from 4a:** M1 (rounded return tempo strands the rig off span; the probe fails identically here), M2 (length rule against #1228's slips), M3 (#1212) and L1 (sub-sample step at each retime). The probes for those run on this head unchanged.
- **Size.** 343 production lines.

Verdict: Request changes (H1 via 4a; M1; M2 is a gate item).

## Delta review (5d5318fb7)

Model: Claude Opus (subagent), in-session

### Scope

- `38c1419de`: the rebase of `508e2a9e7` onto trunk `890f04936`. `git range-diff` shows context only, plus the trunk's packed Speed ratio.
- `5d5318fb7` "fix(engine): keep sources through a retime inside the tolerance; budget the stretch renders".
- 4a's fixes underneath, reviewed in the 4a delta.

### Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | clean |
| Native suites | run on 4b's head, which contains this commit unchanged (see the 4b review) |
| My earlier probes, rebuilt on this head (`test_rv_probes4a*.h`, saved here) | below |

### Status

- **M1, fixed.**
  - `le_track_want_out` returns the take's own length for any span within 0.5 % of it (`le_src_len_within`). A small retime now keeps a transposed track on its plain transpose render and an untransposed track on its dry take; the head absorbs the residual.
  - `probe_transposed_small_retime` at 120 → 120.3: the +5 track keeps `transpose_effective_st` 5 from the first block, with one render (no new one). The plain follower stays dry at 4 cents with no render.
  - The new test pins both cases.
- **M2, addressed as a gate.**
  - The plan's joint table gains the retime rows: 8 x 1 needs 123 MiB of stretch, which fits; 8 x 8 needs 983 MiB, mostly refused and reported, with 128 s of worker time at the 20x floor.
  - The Pi 5 list adds the 8 x 8 retime case (peak RSS, late periods).
  - The cap share stays an owner decision on those numbers (4b records the coordinator's call: shared cap, renders a track uses never evicted).
- **H1 (inherited), fixed in 4a.** `probe_clear_all_undo_baseline(retime=1)` on this head gives rc 0, with the take back at 10667 frames, rate 749.

### Findings

None new.

Verdict: Approve.
