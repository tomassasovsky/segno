# Segno delivery: cloud handoff (2026-10-06, about 23:00 ART)

This session moved from the owner's Mac to a cloud session. Read this file first, then the newest entries at the end of `CHECKPOINT.md`. That file is the append-only log; keep appending to it here.

## Contents of this folder

- `CHECKPOINT.md`: the campaign log, with every decision and state change. `START.md`, `RUN.md`, `REVIEW.md`: the original campaign contract.
- `briefs/`:
  - `builder-common.md`, `reviewer-common.md`, `planner-brief.md`: the prompts given to builder, reviewer and planner subagents.
  - `numbering-ledger.md`: the engine command, fact, error, history and schema numbers reserved per epic. Check it before adding any number.
  - `gap-inventory.md`, `trunk_verify.sh`: the trunk verify script. Its paths are Mac paths; adapt them.
  - The Pi 5 benchmark results.
- `reviews/<name>.md`: every adversarial review, including delta sections. Most are also posted as PR comments.

## Ground rules (owner)

- Build everything on the segno-ui.pen designs before testing. The trunk is `claude/segno-integration`. Claude merges PRs into it when CI is green and `/code-review` (the adversarial review) is clean. The trunk lands on master in one merge at the end.
- Five standing rules:
  1. preserve installs;
  2. fail safe with a recovery path;
  3. no silent behaviour changes;
  4. consolidate rather than duplicate;
  5. drop uncertain native state with a notice.
- Ask the owner only for product direction, irreversible data or hardware.
- No AI attribution in commits or PRs, and no emojis.
- `dart analyze --fatal-infos` and `bloc lint lib test packages` must be clean. Native changes need the plain, ASAN and telemetry-off suites, plus TSAN where races are involved.
- The pen (`segno-ui.pen`) is read-only and lives only on the Mac. The cloud cannot read it, so pen-fidelity checks have to wait for a local session.
- **The cloud cannot reach the LAN.** The appliance (root@192.168.50.124) and the Yocto runner (taquiles@192.168.50.122) need the owner's Mac. Appliance image builds run on GitHub Actions (`appliance-release.yml`, self-hosted runner) and can be dispatched from here. The runner VM powers off at 22:00 ART every night for a backup, and any build running then dies.

## Appliance state

- It runs 0.1.0-experimental.146, built from trunk 787d51db6. It booted from slot A via tryboot, and the boot health check committed the slot. The owner is testing it by hand.
- **Known defect in this build:** at startup, `PerformanceRepository._finalize` → `_readRawPcm` → `File.readAsBytesSync` runs out of memory on two unfinalized takes on the device: `perf-20260913-003635` (about 36 GB per .pcm) and `perf-20260910-073238` (about 6 GB). The files are intact, but no notice is shown. This has been sent to the recording builder; recording P2 (#1245) and P5 (#1227) should stream the data instead.
- `/boot` was repaired (FAT dirty, broken cluster chain in rauc/central.raucs). See the checkpoint.

## Pi 5 benchmark gates

- **Instruments: PASS** with the app stopped. The 7 late periods seen with the app running were contention. This unblocks instruments 2a (#1234).
- **Pitch/time: FAIL.**
  - "8x8 with live Pre chains at 8x" is 147% of the period.
  - The 64-lane mixer at 4x/8x is 57-61%, against a 50% limit.
  - The pitch builder's analysis: Pre chains run once per output frame, so their cost does not scale with Speed. 64 live two-entry chains cost about 620 us even at 1x. Prints keep dense rigs within budget, and Speed, Transpose or a retime turns prints off.
  - Options:
    - (a) print the Pre chain over the transformed source;
    - (b) while that print is pending, read the 1x print through the head and report it;
    - (c) an admission check, which needs a per-effect cost model.
  - Builder's recommendation: a+b, plus Speed source renders for the mixer row, as a new part.
  - **This needs an owner direction call:** ask via AskUserQuestion before building. Also add the missing bench row "8x8 Pre chains at 1x, prints off" to confirm the premise.

## Open items needing the owner

1. **Pitch Pi gate:** the direction above.
2. **Settings P7 (#1230):** the Arimo font was copied from Autodesk Fusion's bundle (1.23). The fix downloads upstream Arimo from google/fonts and needs the owner's OK; the question was asked and is still unanswered. Also from P7: the Pedals crumb text and the hub card colour differ from the pen.
3. **Foot P3:** the generic "unavailable" notice now also fires for Undo with nothing to undo. The reviewer says keep it (rule 3). The owner was told and has not objected.

## Per-epic state

"Approve" means review-clean. Merge each approved part into the trunk once CI is green.

### Multiply/Divide #1168

- Approved: P1 #1212 (be963fd81), P2 #1244 (5eb8517d3, session schema 14) and P3 #1269 (8bfabe310, rebuilt to pen 16; CI green). Ready for the trunk.
- Pen write-back notes are in the plan. Hardware proof is still owed.

### USB storage

- Approved: follow-up #1266 (79924ef02) and P5 #1217 (6f3ac7cfd).
- P6 #1267: fixes pushed at f8aa7c935 (A coverage, B lease on a live take). Needs re-review. Originally at 2e0797ab0, request changes:
  - **A:** storage_repository coverage is 393/395 (`StorageBusy.props`/`toString`).
  - **B:** keep the lease when `armedDirectory != null` (a live take after an arm-snapshot write failure).
- Builder agent stopped; see the heads table below.

### Library #1178

- Approved: #1252 (7c605fb8e), p5-lows (80be1665e), p6b #1264, p7 #1265.
- p6a #1263 at 8c4cb9c48, provisional Approve. The partial review is in reviews/library-p6a-in-session.md. Still to do: the full app suite, and mutations on the L1/L2 tests. New Low D-1: park the race-test pump only around disarm. #1263 is now based on claude/backing-1200-p2.
- Restacked heads: p6b 13756eab6, p7 da9eab036, p8 7d59cdf74.
- p8 (backup/restore), request changes:
  - **High:** Delete/Move/Rename/Duplicate bypass `sessionWrite`, so a session is lost when deleted during a backup.
  - **Medium:** the `transfer`×`sessionWrite` cell is `allow`.
  - **Medium:** restore copies on the UI isolate, with no fsync.
  - Plus Lows.
- p7 merges after recording #1245.

### Render #1202

- Approved: P1 #1238 (07d65b615) and P2 #1241 (23ba2a4e6).
- 4a (claude/render-1202-p4a, 07c8ebb4c), request changes:
  - **H1:** bounced lanes are not marked recoverable, so Redo zeroes R.
  - **M1:** Bounce over a playing track cuts its tail in one frame.
  - Lows L1-L4. Also P1 L-E1/L-E2 and P2 L-F1.

### Backing #1200

- Approved: P1 #1222 (69a97e2bb), P2 #1223 (caaabe6f0), P3 #1240 (6c805c42d), P4 #1243 and P5 #1258.
- New heads after the lows: P4 ad791a57e and P5 138109774.
- **None of P1-P6 merges cleanly onto trunk 787d51db6.** The conflicts are side-by-side additions in segno_engine_api.h, engine.c, run_native_tests.sh, test_engine_core.c, the bindings, and for P3 also audio_engine.dart and engine_result_test.dart. Keep both sides and regenerate the bindings with ffigen plus `dart format`.
- Merge P1-P3 into the trunk first, then have P4-P6 restacked.
- P6 (f3343dc04, still on the old P5), request changes: M1 pen departures plus L1-L4. The builder's full to-do list is in the checkpoint.
- Session schema: P5 lands as 15.

### Recording #1198

- Approved: P3 #1256 (a74bde1d8) and P5 #1227 (abe7e6f4a).
- P4 (claude/recording-1198-p4, 200c44a07, no PR yet), request changes. **High:** checkpoints claim audio that was never flushed after a failed write (perf_drain.c:2126; `le_pd_seal_part` marks a part sealed even when the seal failed; progress is published at arm). This part is `blocked-verify` (power cut).
- P2 #1245 must land before P3. **Release order:** publish Transfer 0.2.0 (tag transfer-v0.2.0; the owner approved) right before any appliance build that contains #1245.

### Pitch/time #1179

- Approved: 4a #1253 (0eacc5adb), 4a-ii #1255 (5d5318fb7), 4a-iii #1257 (32922f796).
- 4b is split:
  - **4b-i:** claude/pitch-time-1179-p4b1 at c223ea173 (wip). To do: goldens after the icon change, the owed-state golden, the release-note line, the plan's As-built split, stripping the recorded-pair section from session-bundle-format.md, then drop "wip:".
  - **4b-ii:** a new branch on p4b1, built from 15a4acf57's recall pieces, plus M1. The builder proposes command 122 `LE_CMD_RETIME_TO` (bpm, length), which accepts a saved retimed length when it equals the bar length rounded up to a multiple of 1, 2 or 4, with the division probe as a native test.
  - 4b-i and 4b-ii must land together; they share schema 16.
- Release note: Follow is On by default, which changes what a tempo change does on existing installs.

### MIDI clock #1228

- P2 #1259 at 422f819dd: the partial delta review leans Request changes on **DM1**. Clean block-edge sources at 160-210 BPM miscount (50/50 phases wrong at 200 BPM, +20 pulses), and noisy ones at 220-300 BPM also miscount. Cause: acquisition counts any pulse more than half a period off its line as hidden pulses.
- Lows: DL1, tempo jumps of 4.7x or more are never followed; DL2, a drop plus a 45 ms stall on block edges.
- Plan #1236 at 6971de523: the D3 table should state the supported tempo range for block-edge sources and add a burst-rule clause for large jumps.
- P3a is on hold until P2 is approved.

### Foot surfaces #1229

- Approved: P1 #1247 (59cb70b72) and P2 #1260 (13ed4750a).
- P3 #1271 at 3d89de67f (rebased onto 787d51db6): provisional approve with Lows.
  - DL1: no test for exactly one toast on Record/Play with no input.
  - DL2: ControlCubit imports the recorder cubit and duplicates its low-disk check; move it into PerformanceRepository.
  - DL3: about 8 format-only hunks in looper_repository.dart; revert them.
  - DL4: the await gap in `_assignedPerformanceToggle`.

  Still to do: the mix-failure mutation at :637, toast listeners, the goldens. The final verdict is in reviews/foot-p3-in-session.md.
- P5 and P6 merge cleanly onto the trunk. P6 conflicts with P3 in the tracks_view files; keep both sides.

### Settings #1199

- Approved: P5 #1251, now e6c10deb5 with a trunk merge and its two Lows.
- P7 (claude/settings-1199-p7, d5b29e1ed) has M1/M3 and the Lows fixed. M2 (upstream Arimo) needs the owner's OK. Then open its PR with Closes #1230.

### Instruments

- Approved: P1 #1224 (ebe1cfcec) and 2b #1261 (b664972c8). 2a #1234 is now unblocked by the Pi bench.
- Still need review: 2c 805ef6de6, 3a c11aba0ff, 3a-2 d6d13be22, 3b b1ce7b858, 3b-2 f8d6c0160, 3b-3 e9331f011, plan 7c785ffec.

### Other parts still unreviewed or unbuilt

- foot P5 2cb34176d and P6 4350826f8;
- conformance #1242 (claude/conformance-1242 d0befb818, no PR yet);
- device pages plan #1272 (send the owner's four answers to a builder, then build P1, boot health, which closes #976).

## Builder heads at the cloud move

See the end of CHECKPOINT.md for the stop reports of the remaining agents.

## Next steps, in order

0. **Trunk hotfix first:** experimental.146 hits OOM at every boot on the 6 GB/36 GB raw takes (`readAsBytesSync`; the OOM is an Error that `_recoverSilently`'s `on Exception` misses). Port the 512 MiB size guard + the "could not be recovered, files kept" notice from recording P2 99e041000 to the trunk as a small PR, then rebuild the appliance image.
1. Run a trunk integration pass. Merge each approved, CI-green stack into `claude/segno-integration` in schema order:
   1. Multiply/Divide P1-P3 (schema 14);
   2. USB #1266 and #1217;
   3. Library #1252 and p5-lows;
   4. render P1 and P2;
   5. backing P1-P3, resolving the conflicts;
   6. pitch 4a, 4a-ii and 4a-iii;
   7. foot P1 and P2;
   8. instruments P1, 2a and 2b;
   9. Settings P5.

   Verify the trunk (native ×3, analyze, bloc lint, all Dart suites) after each group, then push.
2. Send the review fixes back to builders, using new subagents with the briefs in `briefs/`, and keep reviewing.
3. Ask the owner the pitch Pi-gate direction question.
