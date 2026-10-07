Model: Claude Opus (subagent), in-session

# Review of claude/render-1202-p4a: native Bounce with Keep sources (Part 4a)

## Scope

- `origin/claude/render-1202-p4a` at `07c8ebb4c`, stacked on Part 2 (`23ba2a4e6`). No PR yet.
- Part 4a's own commits:
  - `393d1b06c` and `58407efd4` (work in progress);
  - `7429ea656`, which finishes it;
  - merges of Part 2.
- Issue #1202. Plan: PR #1225 at `47e7466c2` (§5.1-5.4, Part 4a, and the Part 4a build record).
- Read in full:
  - the `engine_commands.c` Bounce section (`:4893-5205`) and every guard added elsewhere (record preflight, Clear, Undo, Redo, Peel, the queued undo, slot selection);
  - `le_bounce_install` and `le_apply_mix` in `engine_process.c`;
  - the `le_bounce_bundle`/`le_hist_entry` additions;
  - the export cut in `engine_session.c`;
  - `le_render_take`;
  - the quiesce/stop/destroy abandon calls;
  - the Dart `HistoryKind` codes;
  - `test_engine_bounce.h`.
- Engine only, so the pen is not involved.

## Runs

All in my own worktree at `07c8ebb4c`, each with its own `TMPDIR`.

- **Native plain x3:** ALL PASSED x3.
- **TSAN races:** pass, no reports.
- **Telemetry-off:** pass.
- **ASAN+UBSAN:** no sanitizer reports. One failure, `test_render_configure_mid_print`, a Part 1 timing test that ran while Dart suites loaded the machine. It passes under ASAN with no other load (Part 1 delta, L-E1).
- **Dart, with `SEGNO_ENGINE_LIB`:**
  - segno_engine: 392 passed;
  - looper_repository: 832 passed; with `--tags fuzz`, 63 passed;
  - `dart analyze --fatal-infos lib test packages/segno_engine packages/looper_repository`: clean;
  - `bloc lint lib test packages`: 0 issues in 877 files.
- **App suite:** 3,463 passed and 1 failed. The failure is `looper_bloc_test.dart` "a re-sync cancels the lane editor polls …", which this branch does not touch. It passed 3 of 3 runs on its own, under load from the other suites.
- **Mutations** (the Bounce and render tests, 2 rounds per mutant). All killed:

  | Mutation | Failures |
  |---|---|
  | slot pins removed | 33 |
  | destination reset skipped | 132 |
  | shadow reclaim removed | 3 |
  | redo export cut ignores `group_id` | 1 |
  | APPLY keeps the Redo branch | 1 |
  | re-clock position forced to 0 | 1 |
  | `start_iter` forced to now | 1 |
  | Reverse not restored | 2 |
  | mutes not restored | 2 |
  | Fade not restored | 1 |
  | image staging removed | 4 |
  | busy rule ignores a layer in flight | 1 |

- **Probes** (my own code against the production entry points):
  - Undo to a one-lane topology, then Redo to two lanes;
  - Bounce over a PLAYING destination with a Post delay, against a plain Stop;
  - a Sync-division attempt, which was inconclusive (see Notes).

## Verified correct (traced)

- **One drain.**
  - `le_engine_bounce` validates, prepares the topology through `le_mix_valid`/`le_prepare_routing` (the structural path, review H4) and the two chain bundles. It acquires one slot, fills L/R into lanes 0/1, zero-fills the lanes above, and stages the image (#1143).
  - It posts 113 through `le_request_admit` with the receipt.
  - `le_bounce_install` then, in one callback drain:
    - records `prev` before anything moves;
    - applies the topology and chains;
    - runs `le_transform_reset` before `le_track_publish_live`, so provenance comes first;
    - sets length and clock, restored state, mutes, Fade and direction, and the destination reset (unity gain and levels, centred pans, image pans ∓1);
    - publishes STOPPED.
  - Admission makes the callback's refusal unreachable. If it does fire, nothing has been written, and `le_fx_recipe_collect` reclaims the unapplied bundles through their ticket.
- **Pins against loop-close restoration.**
  - `track_select_slot` skips the incoming image and the outgoing live slot while the Bounce is in flight.
  - A restoration commit in that window takes another slot, and its PROCESSED entry ends up beneath the BOUNCE entry, so Undo of the Bounce returns the restored image.
  - Eviction cannot return a pinned slot: neither pinned slot is on a stack.
  - Tested, and the mutation is killed.
- **The shadow drop.**
  - Spare overdub shadows no longer refuse a Bounce. The install calls `le_dub_drop_armed`, and `le_bounce_collect` resets `outstanding_count` only once the result is filed. This mirrors Clear.
  - New shadows cannot be posted in the window: replenish needs a layer in flight or a recording, and both are refused while a Bounce is in flight.
  - The mutation that removes the reclaim is killed.
- **History.**
  - Plain Undo/Redo, queued undo and Peel all refuse a BOUNCE top. Every other motion returns `NOT_READY` while `bounce_inflight` is set.
  - Collect files `prev` on the side the motion leaves, and an APPLY retires the Redo branch.
  - The export window cuts the undo side above the newest BOUNCE and the redo side at the first BOUNCE or grouped entry. `le_layer_slot_for_ordinal` follows the same window.
  - `le_engine_finalize_history` refuses kind 5, and Dart's `HistoryKind.fromCode` keeps 4 reserved.
- **Mode fit and re-clock.**
  - The rig base excludes the destination.
  - A sole-content destination whose length does not fit re-clocks to `len` at the elapsed phase, keeps `loop_iteration`, and logs `LE_PLOG_LOOP_LENGTH_LOCKED`.
  - Otherwise the destination's `start_iter` is the freeze's `I_ref`, and the phase test checks it against a kept source.
- **Reopen.** `le_mark_state_cmd` makes an unapplied 113/114 a pending state command, so reopen drops the track with the mask. `le_bounce_abandon_all` frees a bundle the callback will never apply, on stop, configure and destroy. Tested.
- **Lane growth.**
  - A one-lane PLAYING destination grows to two lanes in the 113 drain: `le_apply_routing` finds the new lane's live slot allocated at capacity, and the image slot is ensured on every lane.
  - A pending lane-count change refuses with `NOT_READY`. Tested for both Bounce and recovery.

## Findings

### High

**H1. Redo can lose the right channel of the bounce, because the shrink guard the plan relies on is not built.**
- **Where.**
  - Nothing in `le_engine_bounce`/`le_bounce_install` latches `a_recoverable` on the bounced lanes.
  - `le_mix_valid` therefore allows a topology that shrinks below them (`engine_commands.c:1405-1409`).
  - On a later regrow, `le_prepare_routing` zeroes the regrown lane's buffer at that lane's own `a_live` (`:1466-1471`). `le_track_publish_live` only moves `a_live` on active lanes (`engine_core.h:155-167`), so a lane shrunk away still names the bounce slot.
- **Plan.** 5.4 says the added lane "is recoverable, and the shrink rule refuses to drop it (`le_mix_valid`'s `a_recoverable` check …)". The build record lists "the added lane plays and records nothing while Redo holds it" as not built.
- **Probe.**
  - Bounce A+B into empty track 2 with a two-lane topology. Lane 1's `recoverable` reads 0.
  - Undo with a one-lane topology: accepted, lane count 1.
  - Redo with a two-lane topology: accepted, and lane 0 is intact.
  - But lane 1, the R channel, is all zeros: `R[5] = 0` where `A[5] + B[5]` was.
- **Second route.** `le_trim_trailing_lanes` reaches the same shrink on its own once lane 1 is un-routed after Undo, which is exactly the state plan 5.4 puts it in ("active but unrouted").
- **Failure.** The player bounces, undoes, and redoes. The bounce comes back with half its stereo image silent (rule 1).
- **Fix.**
  - Latch `a_recoverable` on lanes `[0, lanes_after)` when a BOUNCE entry is filed on either stack, so `le_mix_valid` refuses a shrink below the bounced pair while either side holds it.
  - Clear it when that entry is retired (`le_clear_redo`, the export cut on recall, or the next APPLY).
  - Add the probe above as a test, and the "plays and records nothing while Redo holds it" case from the plan.

### Medium

**M1. A Bounce over a playing destination cuts its old sound, Post tail included, in one frame.**
- **Where.** `le_bounce_install` (`engine_process.c:2806-2924`) replaces the chains (`le_fx_recipe_apply`, `:2833-2834`) and publishes STOPPED (`:2919`) in the same drain. The old Post states go, and the dry stops at once.
- **Probe.** Track 1 plays a 200 Hz sine (amplitude 0.5) through a lane Post delay. Track 0's render is bounced into it. Track 0 is muted, so only track 1 is heard.
  - Largest sample step before the swap: 0.152.
  - Across the swap: 0.477 → 0.000 in one frame.
  - The same rig with a plain Stop instead: 0.477 → 0.165, with the delay tail draining as §3.6 says Post tails do.
- **Failure.** "Replace & bounce" on a playing track clicks and cuts its echo or reverb dead, which a Stop of the same track does not do (rule 3).
- **Missed by the tests.** The plan's apply-frame probe ("no block where the image plays through the old chains") would have caught this, and the build record lists it as not built.
- **Fix.**
  - Let the replaced chain drain. One way: keep the old Post states running over silence for their tail, as Stop does. Another: crossfade the old output out over a short ramp.
  - Add the apply-frame probe as a test.
  - If the cut is intended, state it in plan 5.3 as a decision.

### Low

- **L1. Undoing a re-clocked bounce restores the master at an arbitrary phase.**
  - **Where.** For an UNDO that re-clocks, `elapsed` is computed as `(loop_iteration − g.start_iter) × clock.length + position` (`engine_process.c:2871-2873`). `g.start_iter` was counted at the old master length, but the product uses the current, bounced length.
  - **Effect.** The restored master position is not the old content's continuing phase. Only the click grid is affected, because the restored take is the sole content.
  - **Coverage.** `test_bounce_mode_fit_and_reclock` checks the restored length, not the phase.
  - **Fix.** Restore at position 0, or at a phase computed in old-length iterations. Pin it in the test.
- **L2. `le_bounce_collect` has no bound check.** It writes `undo_stack[undo_count++]` (`engine_commands.c:5020`) without checking against `LE_POOL_SLOTS`. Admission checked the bound, but a restoration commit may push a PROCESSED entry inside the window. The pool's slot accounting appears to keep this from overflowing (eviction frees an entry first), but the write has no local guard. Add `if (t->undo_count < LE_POOL_SLOTS)`, or evict, as `le_restore_commit_layer` does.
- **L3. The refusal for a newer edit differs from the plan.** Recovery with a newer edit on top returns `LE_ERR_INVALID` (documented in the build record), where plan 5.4 and the surfaces expect `TRACKS_CHANGED` ("Tracks changed"). Either map `INVALID` from `le_engine_bounce_recover` to that notice in Part 5, or change the plan text so Part 6's notice list matches.
- **L4. Tests built weaker than listed** (per the build record, and checked):
  - **Undo-stack-full refusal:** untested. The record says the pool keeps the stack below the cap, which matches my L2 reasoning.
  - **Sync division and Free/Song:** untested. I traced the code:
    - Free/Song sets `free_clock` to `len` at position 0 with `free_iteration` 0, as plan L5 says.
    - A division goes through `le_restore_multiple_or_divisor`.

    Neither path is executed by any test.
  - **Apply-frame probe:** missing; see M1.
  - **Recall round trips through `finalize_history`:** missing. The cut and the kind-5 refusal are tested.
  - **"The added lane plays and records nothing while Redo holds it":** missing; see H1.

## Notes

- **Sync-division probe.** My attempt imported a 16-frame track under a 32-frame commit in the default mode. The source itself reads `multiple 1, divisor 0`, an imported-shorter-than-base state that plays once per 32 frames. The bounced destination became `divisor 2`. That fixture is not a valid division rig, so I draw no conclusion from it beyond L4 (no test exercises a division result).
- **Rig-level behaviour.** A Bounce stops a destination that was playing (Keep sources creates a STOPPED destination, AB §4), as accepted. Solo and Loop/Once are kept, as plan B2 says.
- **Part 4b dependency.** The group fields (`group_id`, `cleared_mask`) are carried and exported correctly, ready for Part 4b. `cleared_mask` is always 0 in 4a, and `keep_sources = 0` returns `UNSUPPORTED`.

Verdict: Request changes (H1 and M1)
