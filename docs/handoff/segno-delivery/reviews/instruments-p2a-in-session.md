Model: Claude Opus (subagent), in-session

# Review of PR #1234 (origin/claude/instruments-1197-p2a @ 7f266d598, stacked on #1224): feat(engine): instrument slots, ordered note rings and the synth in the callback

## Scope

- One commit on `980ccafc1`, 16 files, +1247/−24:
  - `engine_instruments.{h,c}` (new);
  - `engine_private.h` (event, ring, slot and published state);
  - `engine.c` (create, destroy, and the reset inside
    `le_engine_reset_runtime`);
  - `engine_process.c` (`le_instruments_block` after the command drain,
    `le_instruments_cut` in `handle_cut_sound`, and commands 96/97);
  - `engine_snapshot.c` and the `segno_engine_api.h` API, snapshot fields and
    error codes;
  - `synth_voice.h` (`LE_SYNTH_MAX_INSTRUMENTS` aliased to
    `LE_MAX_INSTRUMENTS`);
  - the bench's engine and joint scenarios switched to the integrated path;
  - `test_engine_instruments.h`, the forwarders, the wiring script and the
    regenerated bindings.
- About 610 production lines with comments (plan: about 550).
- Reviewed against:
  - Part 2a, §2.2, D2, D4 and D7 of the plan at `27fa7d945`, which records
    the deviation: patch changes ride the ordered note ring;
  - the plan review's H3, H4, L4 and M9;
  - AGENTS.md and the owner rules.

## Runs

Every run used a fresh TMPDIR, in a scratch worktree at `7f266d598`.

- Native suites:
  - plain `run_native_tests.sh` three times, ALL PASSED each time (57 s,
    100 s, 117 s);
  - ASAN (`-fsanitize=address -g`): ALL PASSED;
  - telemetry off (`-DLE_CALLBACK_TELEMETRY=0`): ALL PASSED.
- TSAN races job (`NATIVE_TESTS_ONLY=races`, `-fsanitize=thread`): 0
  failures. This job has no instrument coverage. My own TSAN probe is below.
- Bench smoke:
  - `bench_instruments.sh --smoke` builds and runs (rc 0);
  - **`bench_pitch_time.sh --smoke` fails to link** (rc 1; finding H1).
- segno_engine Dart suite: `SEGNO_ENGINE_LIB=$(bash tool/build_test_lib.sh) flutter test`
  passed all 370 tests against the native test library.
- PR CI on `7f266d598`: **native-tests and native-bench-arm64 FAIL**, with
  the same undefined `le_synth_*` references in "Build + smoke the pitch/time
  bench" and "Build + run the pitch/time bench" (run 37495522365). The
  remaining checks, including ASAN, telemetry off and TSAN, pass.
- **TSAN probe with a producer thread** (scratch file `inst_probe.c`, linked
  against the full engine source list).
  - The producer thread posts `note_on(origin i)` and then
    `note_off(origin i)` pairs.
  - In mix mode it also posts parameter changes, patch changes, voice
    limits, slot-1 notes and snapshots. The snapshot runs on the producer
    thread, because `le_engine_get_snapshot` is a control-thread call.
  - The main thread plays the audio thread, calling either
    `le_engine_process` at 64 frames or drain-only blocks.
  - After the last release is drained, the probe counts slot-0 voices
    still HELD; every origin got a release, so each one is a stuck note.
  - Under `-fsanitize=thread`, three modes (64-frame, sparse drain-only,
    sparse 64-frame), 20,000 pairs each: **no data race reported**.
  - A first variant that read snapshots from a third thread was my probe's
    error; it reported the existing `commands_posted` control-thread
    contract, not this PR's code.
  - The ordering result is finding M1.
- **Mutations**, each built against the synth and instrument tests in a
  scratch copy:
  - killed: voice-limit command ignored by the synth; note-off restricted to
    one slot; merge "releases always first";
  - survived (L2): merge "note-ons always first", parameter stamp check
    removed, configure keeping queued events, idle path leaving stale bus
    audio.

## Verified correct (traced)

- **Rings.**
  - `ring_push` keeps one slot empty: `tail - head >= mask`, so 255 and 1023
    are usable (tested).
  - Head and tail use acquire/release pairs. The consumer reads the slot in
    place and pops after applying it, so the producer cannot overwrite it.
  - The sequence is stamped only on a successful push, and compared through
    an `int32_t` difference, which is wrap-safe.
- **Release lane.**
  - Note-offs ride `inst_release_ring` (1024).
  - A full note-on ring refuses note-ons (`LE_ERR_CAPACITY`, counted in
    `instrument_events_refused`) and never a release.
  - The drain is capped at 512 events per block, and the rest wait in order.
- **Patch changes on the note ring.** This deviation is sound for its stated
  purpose: a note-on posted after `le_engine_set_instrument` is drained after
  the `SET_PATCH` in the same ring.
  - Parameters are published before the event and stamped with the new
    patch.
  - `apply_slot_params` applies values only when the stamp equals the
    slot's applied patch, and `SET_PATCH` applies the current stamped values
    right after `le_synth_set_instrument` loads defaults. So custom
    parameters given with a patch reach its first note (tested,
    byte-identical).
  - A refused push rolls back to the previous values and stamp (tested).
- **Cut.** `handle_cut_sound` calls `le_synth_cut(-1)`, which fades in place.
  Every bus is exactly zero from 144 frames on (48 kHz, 3 ms) (tested).
- **`LE_CMD_SET_VOICE_LIMIT` (96)** goes through `le_synth_set_voice_limit`.
  The snapshot's `voice_limit` changes only on success. **`LE_CMD_INSTRUMENT_RESET`
  (97)** cuts one slot (tested).
- **Configure and reopen.**
  - Both paths call `le_engine_reset_runtime` (`engine.c:897`, `:967`),
    which calls `le_instruments_reset` (`:883`).
  - The reset re-inits the synth at the new rate with a 64-voice pool and a
    limit of 32. It clears both rings, the sequence, the requested patches,
    the stamps, the revisions and the published state, and bumps
    `a_synth_epoch` with release. The snapshot loads it with acquire.
  - Reopen refuses while running (`:942`), so this runs with no callback.
  - Configure-path epoch is tested; reopen-path epoch is not (L2).
- **Real-time safety in the callback.**
  - No allocation, lock or syscall. The synth and buses are allocated at
    create, with a NULL-safe early return.
  - The work per block is bounded: 8 parameter checks, at most 512 events
    (each bounded by the 64-voice and 64-fade scans), one render, and an
    8 × frames peak scan.
  - The idle path (nothing sounding, nothing fading) renders nothing and
    clears a bus once.
  - Oversize blocks are counted and never allocate.
  - Existing tests are untouched and pass.
- **Snapshot fields.** These are trailing, read from atomics only, and
  documented: `instrument_patch` (the applied patch), `instrument_voices`,
  `instrument_peaks`, `voice_limit`, `voices_stolen`/`_hard`, `synth_epoch`,
  `instrument_events_refused` and `instrument_fallback_blocks`. The
  bindings were regenerated and carry the functions, fields and codes.
- **Single-event API refusals.**
  - `LE_ERR_NO_INSTRUMENT` (−14) is returned only by `note_on` and
    `set_instrument_param` on an empty slot.
  - `LE_ERR_UNKNOWN_PATCH` (−15) is returned for an undefined patch index.
  - `LE_ERR_NOT_RUNNING` is returned before configure.
  - These match the ledger and H4 (no batch refusal exists yet).

## Findings

### High

**H1. The pitch/time bench no longer links, so CI's native-tests and native-bench-arm64 fail (`src/test/bench/bench_pitch_time.sh:34-40`).**

`engine_instruments.c` falls inside the `src/core/engine*.c` glob and calls
`le_synth_*`. But `bench_pitch_time.sh`'s source list names
`restore_*.c` and not `synth_voice.c` / `synth_patch.c`. The Part 1 diff
added the synth TUs to `bench_instruments.sh`, `run_native_tests.sh`,
`build_test_lib.sh` and CMake only.

Reproduced locally (`ld: symbol(s) not found … _le_synth_cut`). On the PR it
fails two required jobs:
- "Build + smoke the pitch/time bench" in native-tests;
- "Build + run the pitch/time bench (arm64 proxy thresholds)" in
  native-bench-arm64.

That second job is also the pitch/time Pi artifact that D2's joint Pi
session needs.

Fix: add `src/core/synth_voice.c src/core/synth_patch.c` to
`bench_pitch_time.sh`. Then either extend
`tool/test/run_macos_rnnoise_wiring_tests.sh` to check both bench scripts,
or make the scripts share one source list, so the next pure TU cannot break
one bench silently.

`bench_devices.sh` has the same omission, but it already fails to build on
trunk (`'rnnoise.h' file not found`) and is not in CI. See Notes.

### Medium

**M1. Merging the two rings by posting order can apply a note-off before its own note-on, which leaves a stuck note (`engine_instruments.c:319-332`).**

`drain_events` loads `inst_ring`'s tail and then `inst_release_ring`'s tail,
separately, on every iteration. The producer posts the note-on (seq k) and
then the note-off (seq k+1). The failure needs this interleaving:
1. the consumer's `ring_peek(&e->inst_ring)` finds the note ring empty;
2. both pushes then land before its `ring_peek(&e->inst_release_ring)`;
3. the consumer sees only the release, takes the `off != NULL, on == NULL`
   branch and applies the note-off to a voice that does not exist yet;
4. the next iteration applies the note-on, and that voice stays HELD
   forever.

This breaks the PR's stated invariant ("a note-on and its note-off posted
between two blocks are applied in that order") and the plan's H3 premise
that a release is never lost.

Reproduced with the probe in sparse mode: the producer posts a pair whenever
the note ring is empty, and the consumer drains in a hot loop
(`le_instruments_block(e, 0)`).
- 300,000 pairs left 2, 6 and 16 voices HELD in three runs.
- Under TSAN with mixed traffic, 20,000 pairs left 7 HELD.
- With 64-frame `le_engine_process` blocks: 0 in 300,000. The window is
  narrow in the real callback, which drains once per period, but a
  preempted audio thread between the two loads widens it.

The opposite order (release peeked first) is no fix either: it allows the
reverse swap, which matters once a binding's id is the origin (Part 8: a
re-press would be released by the previous release).

Fix (verified): the producer publishes a high-water sequence after each
push: `atomic_store_explicit(&a_inst_seq_pub, inst_seq, release)`. At the
start of `drain_events` the consumer loads it with acquire and treats any
event whose seq is beyond it as not yet visible. Any event at or below the
high-water mark is then visible in both rings, so the merge sees a
consistent cut. With that 5-line change, the same probe gives 0 stuck notes
in 3 × 300,000 pairs.

Alternatively, use one ring that reserves capacity for releases (refuse
note-ons above about 768 queued). That gives a total order with no merge at
all.

Add a test: a two-thread version of the probe in the TSAN job, or a
deterministic test that posts the pair between the two peeks through a test
hook.

### Low

**L1. Refused patch changes have no reserved room.**

Patch changes now share the 256-entry note ring with Dart note-ons, so
`le_engine_set_instrument` returns `LE_ERR_CAPACITY` during a note burst.
The API documents this honestly, but nothing retries it: the plan's Part 3b
retries only releases. An audition Cancel or Apply refused this way would
leave the wrong sound playing.

Fix: refuse note-ons while fewer than `LE_MAX_INSTRUMENTS + 1` slots are
free, so a patch change always fits. Otherwise the repository must retry
patch changes as it retries releases. This is also delta finding D4 on the
plan.

**L2. Test gaps (each mutation listed survived).**
- The stamp check in `apply_slot_params` (`:280`) is the mechanism that
  stops one patch's values being applied to another, and no test fails
  without it. Add one: queue more than 512 events, then
  `set_instrument(P2, custom)` while P1 voices hold. Until `SET_PATCH`
  drains, P1's parameters stay P1's.
- The merge direction "release posted before a note-on is applied first"
  has no test; only note-on then note-off is covered.
- Nothing proves that configure discards queued events (`ring_init` in
  `le_instruments_reset`). A stale `SET_PATCH` replayed after configure
  would give a slot a patch that `inst_patch_requested` says it does not
  have. Add a test: post events, configure without a block in between,
  process, and assert nothing applied.
- No test covers the reopen path's epoch bump.

**L3. Documentation drift.**
- `le_engine_set_instrument_param`'s header says "Returns LE_OK or
  LE_ERR_INVALID". It also returns `LE_ERR_NOT_RUNNING` and
  `LE_ERR_NO_INSTRUMENT`, and the latter is tested.
- `publish_params`' comment says the callback "reads all of a change or
  none". It does not: there is no re-check of the revision after reading. A
  read that overlaps two publishes can take parameter 0 from one and
  parameter 1 from the other, for one block, until the next revision fixes
  it. That is harmless for continuous controls, but the comment should say
  "eventually consistent", or the reader should re-check the revision
  (seqlock).
- The plan says an oversize block "renders silence". The code leaves the
  previous block's samples in the bus and the peak stale
  (`engine_instruments.c:357-363`). Nothing reads the bus before Part 2b,
  but Part 2b's readers must treat a fallback block as silence. Zeroing
  `frames` (capped at the scratch) here would make that true at the source.

## Notes

- **Bench.** The engine and joint scenarios now hold 32 voices of the
  costliest *melodic* patch inside `le_engine_process`. A drum patch can
  no longer be the joint's patch, and there is no per-period event traffic.
  The integrated joint is therefore lighter than Part 1's when a drum kit is
  the costliest. The Pi gate rests on Part 1's run, so this is
  informational. A 255-note burst through the ring in one block is not
  benched.
- **Command ring versus note ring.** The command ring and the note ring
  still give no order between them. Cut all sound and
  `LE_CMD_INSTRUMENT_RESET` are commands, so a note posted just after a Cut
  can be played and then cut in the next block, or a note posted just
  before can sound after it. The window is one period and Cut is not a note
  operation, so I am not counting it as a finding.
- **Merge gate.** Part 2a's own HARDWARE criterion (the Part 1 Pi table) is
  still open, so it cannot merge yet regardless.
- **`bench_devices.sh`.** It globs `engine*.c` without the restore or synth
  TUs and lacks the RNNoise include. It already fails on trunk
  (pre-existing), and is outside CI.

Verdict: Request changes (H1 is a red CI; M1 is the ordering guarantee the PR exists to provide).

## Delta review (46327b5ed)

Model: Claude Opus (subagent), in-session.

### Scope

- The branch was rebased onto the new Part 1 head: the original commit is
  now `01156c6bb`.
- One fix commit, `46327b5ed` "apply note rings in a consistent cut and keep
  room for patches". It touches:
  - `engine_instruments.c` and `engine_private.h` (`a_inst_seq_pub`);
  - the API comments;
  - `test_engine_instruments.h` (three new tests and adjusted counts);
  - a new `test_instrument_races.c`, wired into `run_native_tests.sh`
    before the races-only exit, so the TSAN job runs it too;
  - the regenerated bindings.

### Runs

Each run used a fresh TMPDIR, in a scratch worktree at `46327b5ed`.

- Native suites:
  - plain: ALL PASSED (66 s);
  - ASAN: ALL PASSED (88 s);
  - telemetry off: ALL PASSED (59 s).
  - The new race binary reported "300000 pairs, 0 stuck notes" in all three
    builds.
- TSAN races job: 0 failures. Its new instrument scenario ran
  "20000 pairs, 0 stuck notes" with no TSAN report.
- Bench smoke: `bench_instruments.sh --smoke` and
  `bench_pitch_time.sh --smoke` both pass (rc 0). The pitch/time link is
  fixed by the new Part 1 base.
- **The new race test catches the original bug.** I compiled
  `test_instrument_races.c` from `46327b5ed` against the pre-fix engine
  (`01156c6bb`). It failed three runs out of three, with 6, 2 and 5 stuck
  notes ("a note-off was applied before its own note-on").
- PR CI on `46327b5ed`: all 23 checks pass, including native-tests and
  native-bench-arm64.

### Disposition

**H1, bench link: fixed** (in Part 1, `302452170`; this branch is rebased
onto it).

**M1, one high-water sequence across both rings: fixed.**
- `push_event` publishes `a_inst_seq_pub` with release after each successful
  push.
- `drain_events` loads it with acquire once per block, and hides any event
  whose sequence is above it before merging.
- This is the fix I verified in the first review. Every event at or below
  the mark was pushed before the mark was published, so it is visible in
  both rings, and the merge sees a consistent cut.
- `le_instruments_reset` clears the mark with the sequence.
- Events above the mark wait one block.
- `test_instrument_release_before_note_keeps_it` pins the reverse order as
  well: a release posted before a same-origin note-on applies first.

**L1, patch room: fixed.**
- `le_engine_instrument_note_on` refuses a note-on while
  `ring_free <= LE_MAX_INSTRUMENTS`, so 247 note-ons fit and 8 slots stay
  for patch changes (tested: 247 accepted, 53 refused, then one patch change
  per slot accepted).
- More than eight patch changes queued within one block can still be
  refused. The plan's Part 3b now retries refused patch changes, so that is
  covered.

**L2, tests: fixed.**
- `test_instrument_params_stay_with_their_patch` keeps the change behind
  600 queued releases. The old patch keeps its own parameters for that
  block, and the new values apply with the change. This is the stamp check
  that the first review's mutation G removed.
- `test_instrument_reset_drops_queued_events` covers both reset paths:
  - configure drops a queued note and patch;
  - after it, new events still apply;
  - `le_engine_reopen_configured` (material kept) bumps the epoch and drops
    queued events.
- The oversized-block test now asserts a silent bus and a zero peak.

**L3, docs: fixed.**
- The return codes of `le_engine_set_instrument_param` are complete.
- The parameter comment now says reads are eventually consistent instead of
  "all or none".
- The oversized-block path zeroes every bus and peak
  (`engine_instruments.c`, the fallback branch), as the plan says.

**test_instrument_races.c: sound.**
- The producer posts each pair the moment the note ring is empty, against a
  hot `le_instruments_block(e, 0)` loop. That is exactly the window the bug
  needs, and it fails against the old code.
- `RACE_PAIRS` drops to 20,000 under TSAN, and the test checks HELD voices
  only.

### Findings

None new.

### Notes

- Zeroing all eight buses on a fallback block costs 256 KB of memset, but it
  happens only on synthetic blocks above 8,192 frames.
- The Part 1 Pi table, the HARDWARE merge gate, is still open.

Verdict: Approve
