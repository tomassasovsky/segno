Model: Claude Opus (subagent), in-session

# Review of PR #1224 (origin/claude/instruments-1197-p1 @ 980ccafc1): feat(engine): instrument voice pool, 19-patch table and CPU bench

## Scope

- Two commits on `56033baf0`: `0cb65685c` (the voice pool, the patch table
  and the bench) and `980ccafc1` (fade slots per voice, Cut in place, the
  voice limit, the joint scenario).
- Files: `synth_voice.{h,c}`, `synth_patch.c`, the catalogue exports in
  `segno_engine_api.h`, `bench_common.h`, `bench_instruments.{c,sh}`,
  `bench_pitch_time.c` (helpers moved out), `test_engine_synth.h`, the
  build-list and forwarder wiring, `main.yaml`, the regenerated bindings and
  `docs/plan/2026-10-06-instruments-spike-findings.md`.
- About 1,050 lines of C including comments (the findings document records
  about 800 production lines, over the 700 ceiling, and gives the reason).
- Reviewed against:
  - Part 1 and D1, D2, D5 and D10 of the plan at `27fa7d945`;
  - the plan review's M2, M3 and M4;
  - the prototype in the main checkout's untracked `docs/design/`
    (`instrument-catalogue.js`, `instrument-runtime.js` `synthVoice`,
    `startNote`, `noteOff`);
  - AGENTS.md and the owner rules.

## Runs

All runs used a fresh TMPDIR in a scratch worktree at `980ccafc1`.

- Native suite, plain: `bash src/test/run_native_tests.sh`. Run three times;
  every run ALL PASSED (50 s, 60 s, 65 s).
- Native suite, ASAN: `EXTRA_CFLAGS='-fsanitize=address -g'`. ALL PASSED.
- Native suite, telemetry off: `EXTRA_CFLAGS='-DLE_CALLBACK_TELEMETRY=0'`.
  ALL PASSED.
- TSAN races job: `NATIVE_TESTS_ONLY=races EXTRA_CFLAGS='-fsanitize=thread -g'`.
  0 failures (no instrument code is threaded in this part).
- Bench smoke: `bench_instruments.sh --smoke` and `bench_pitch_time.sh --smoke`
  both build and run (rc 0).
  - On this macOS dev machine, with other suites running at the same time,
    the tails are noise and are informational only.
  - p50 figures: the costliest patch at 32 voices is 13.2 µs (2.0 % of
    667 µs), and at 64 voices 26.0 µs (3.9 %). The full-pool burst p50 is
    27.5 µs (4.1 %). The joint scenario p50 is 109.7 µs (16.5 %).
- segno_engine Dart suite:
  `SEGNO_ENGINE_LIB=$(bash tool/build_test_lib.sh) flutter test`. All 370
  tests passed.
- PR CI on `980ccafc1` is all green, including native-bench-arm64 (proxy
  thresholds).
- Probes and mutations (scratch copies; the reviewed sources were left
  untouched):
  - a drum re-strike probe (M1);
  - mutations A and B of the fade-slot overflow path, built against
    `test_engine_synth.h`; both survived (L1).

## Verified correct (traced)

- **The patch table.** All 19 entries match `instrument-catalogue.js:17-37`,
  in catalogue order: ids, family, wave, ratio, level and all 57 defaults.
  - The Q of 2.8 for lead and synth-bass, and the 5.4x partial on bells,
    match the runtime.
  - The family-to-role table `k_roles` (`synth_voice.c:70-79`) maps each of
    the seven families' parameter keys (`synth_patch.c:67-75`) to the role
    the prototype's `update` reads. Brightness falls back through
    cutoff/brightness/hardness/tone to 65, and character through
    character/harmonics/hardness to 35.
- **The voice against `synthVoice`.**
  - The partial levels are 0.62 and 0.03 + character × 0.34, with organ
    4x at character × 0.22.
  - The low-pass is at 180·70^(b/100).
  - Bass Q is 0.7 + punch/24; Synths and Strings attack is 0.008-0.908 s.
  - The peak is 0.5·velocity, followed by an exponential fall to level, or to
    0.8 over 0.4 s.
  - The LFO runs at 5 / 5.8 Hz, with vibrato at 0.35 cents per unit and
    tremolo at 0.25.
  - Release is tau = release/5, falling through
    release → decay → 35. It now ends at exactly zero instead of stopping at
    +0.04 s.
  - Drums:
    - the highpass, the kick sweep (135→47 Hz, or 180→38 Hz electronic, over
      half the hit) and the duration formulas all match;
    - the 0.85 headroom is a recorded departure.
- **Display mapping.** The display mapping equals the synthesis mapping for
  every non-drum parameter. Decay 60 reads 1.52 s, which matches `gGTXF` and
  is tested.
- **Fade slots.**
  - `LE_SYNTH_FADE_SLOTS = LE_SYNTH_MAX_VOICES` (`synth_voice.h:42`).
  - `fade_out` moves a stolen voice to a free fade slot, and only when all 64
    are busy overwrites the most finished one, counting `stolen_hard`
    (`:290-311`).
  - Cut, patch change and limit lowering fade in place (`:281-286`).
  - `take_slot` under the limit prefers a FREE main slot over an in-place
    fade wherever it sits in the array (`:336-352`).
  - The 32-steal burst test proves every victim fades and none is hard.
- **Stealing order.** The victim order is: released of the same instrument,
  then released of any, then held of the same, then held of any
  (`:325-331`). It is tested in all three tiers.
- **`le_synth_set_voice_limit` (`:569-574`).**
  - It refuses limits outside 1..pool.
  - Lowering the limit fades the excess oldest-first, by repeated
    `victim(s, -1)` calls; the loop terminates because each fade drops the
    active count.
  - Notes stop at the limit through `take_slot`'s `active < limit` test.
- **Real-time rules.**
  - Render does no allocation, locking or syscall.
  - libm runs once per voice per 32-frame control block (`tanf`, `powf`,
    `exp2f`) and once per note event (`powf`, `expf`).
  - Every loop is bounded by the pool, the fade slots or the block.
  - Partials at or above 0.45·sr are silenced every control block.
- **Block-size determinism.** The control grid is counted from init
  (`ctrl_left`), and the test proves byte-identical output at 1, 64, 127 and
  512 frames.
- **The bench.**
  - `stats_of` computes p99.9 with the ceil index and `over` as samples
    above the budget (`bench_common.h:68-87`).
  - The joint scenario combines:
    - the 8 × 8 rig with eight device inputs carrying the source, each
      monitored through one reverb (`bench_instruments.c:191-198`);
    - the read head at 8x over 64 lanes;
    - 32 voices of the costliest patch, in one timed period.
  - The Pi set judges p99.9 and `late == 0`; `--proxy` judges p50 at half.
    `--assert` without `--proxy` is refused off a Cortex-A76.
- **Wiring.** CMake, `run_native_tests.sh`, `build_test_lib.sh`, the SPM and
  CocoaPods forwarders and the wiring script all list both TUs. CI
  smoke-runs the bench and asserts the proxy with `shell: bash`, so a build
  or threshold failure fails the job.
- **Catalogue exports.** NULL and out-of-range arguments are refused, and
  `strncpy` leaves the id and key NUL-terminated (the struct is memset first,
  and the longest id, `electronic-drums`, is 16 characters against 24).

## Findings

### Medium

**M1. A drum hit is choked by the next strike of the same pad, even after the pad was released (`synth_voice.c:444-451` with `:540`).**

`le_synth_note_on` fades every HELD voice of the same instrument and origin
(the repeated-strike rule). `le_synth_note_off` skips drum voices entirely
(`|| v->drum`), so a drum voice stays HELD until its hit ends.

The prototype behaves differently. `noteOff` calls `removeVoice` for a
drum, which deletes it from the token map while `release()` returns without
stopping the sound (`instrument-runtime.js:146`, `:155-160`, `:200-207`); the repeated-strike scan only searches that map (`:170`). A later strike
of the same token therefore does not find the old hit, and the two overlap.
Only a strike while the pad is still down cuts the old hit.

Reproduced (`drums`, origin 38, note 38):
1. hit, then render 50 ms;
2. note-off, then render 100 ms;
3. hit again.

After step 3, `le_synth_fading` = 1: the first snare, about 0.39 s long, is
cut after 3 ms.

Failure scenario: from Part 2c on, a MIDI origin is
`port | channel | kind | number`, so every hit of one pad has the same
origin. Under Part 8, a binding's id is its origin. A snare roll on one pad,
or a pedal-triggered drum, chokes every previous hit instead of letting it
ring. That is audible, and it departs from the accepted reference, which
D10 says the voice follows.

Fix: in `le_synth_note_off`, move a drum voice from HELD to RELEASED without
touching its envelope or stage, so the repeated-strike rule (HELD only) no
longer matches it. Add a test: drum hit, note-off, re-hit of the same
origin; both voices sound, and the first is byte-identical to its solo
render.

### Low

**L1. The fade-slot overflow path is untested (`synth_voice.c:298-304`).**

Two mutations both left the synth and instrument suites green:
- (A) drop `s->stolen_hard++` when all 64 fade slots are busy;
- (B) always overwrite `fades[0]` instead of the most finished fade.

This is the M2 exhaustion rule that the plan names ("only more steals than
slots within 3 ms overwrite the most finished fade, counted"). The
findings document's mutation table has no row for it.

Fix: add a test with pool 64 and 128 note-ons in one burst. Assert
`stolen_hard == 64`, and assert that the overwritten fades were the most
advanced.

**L2. The drum "Decay" readout is not the hit length, yet the API comment says it is exact (`segno_engine_api.h`, `le_synth_param_desc`: "The voice uses exactly this value").**

Drums' decay is `SECS` (0.08-2.48 s), so the default 40 reads 1.04 s. The
voice derives the hit length from it:
- kick: 0.15 + d × 0.55 = 0.72 s;
- hat: 0.04 + d × 0.13 = 0.175 s;
- snare: 0.39 s.

This is the prototype's display too, so it is not a new departure. But the
comment and D5 ("the readout cannot drift from the sound") claim more than
holds for this family.

Fix: either qualify the comment for Drums, or give drum decay a percent unit.

## Notes

- **Bench.**
  - The costliest patch is chosen by mean over `--patch-seconds`. In smoke
    runs (0.25 s) it changes between runs: bells here, marimba on the Part 2a
    branch. With the Pi run's 5 s that is fine.
  - The joint scenario holds voices on one instrument with no per-period
    note events, apart from re-striking ending drum voices. Part 2c adds the
    routing cost, as the plan states.
- **Merge gate.** The Pi 5 table in the findings document is still pending.
  It gates Part 2a's merge, not this part.
- **Pool size.** `le_synth_set_voice_limit` accepts up to the pool size. The
  engine (Part 2a) inits the pool at 64 with a limit of 32, so the "raise to
  64" in D2 is a limit change, not a re-init.
- **Size.** This part is over the 700-line ceiling (recorded in the findings
  document). The overrun is the plan review's own additions, so I do not
  count it against the part.

Verdict: Request changes (M1; a small fix with one test. L1 should go in the same change).

## Delta review (302452170)

Model: Claude Opus (subagent), in-session.

### Scope

- One commit on `980ccafc1`: `302452170` "let a released drum pad ring on a
  re-strike, test fade overflow".
- Files: `synth_voice.c`, the `le_synth_param_desc` comment, the two new
  tests in `test_engine_synth.h`, `bench_pitch_time.sh`, the wiring script,
  the regenerated bindings (doc comment only) and the findings document.

### Runs

Each run used a fresh TMPDIR, in a scratch worktree at `302452170`.

- Native suites:
  - plain: ALL PASSED (59 s);
  - ASAN: ALL PASSED (132 s);
  - telemetry off: ALL PASSED (54 s).
- TSAN races job: 0 failures.
- Bench smoke: both `bench_instruments.sh --smoke` and
  `bench_pitch_time.sh --smoke` build and run (rc 0).
- PR CI on `302452170`: all 24 checks pass, including native-tests and
  native-bench-arm64.

### Disposition

**M1, drum overlap: fixed.**
- `le_synth_note_off` now moves a held drum hit to RELEASED and leaves its
  envelope and stage alone, so the repeated-strike rule (HELD only) no
  longer chokes it.
- `test_synth_drum_restrike_overlaps` covers the case. It strikes, releases
  at 50 ms and strikes again at 150 ms, then checks:
  - nothing fades;
  - two voices sound;
  - the mix equals the two solo renders within 1e-6 (same serials, so the
    noise matches);
  - a strike while the pad is still down still replaces the hit.
- This matches the reference (`instrument-runtime.js:146`, `:155-160`,
  `:170`, `:200-207`).
- One side effect: after a release, a drum hit is in the released class, so
  it is stolen before held voices. That is reasonable, and the reference has
  no pool to compare against.

**L1, fade-overflow test: fixed.**
- `test_synth_fade_slot_overflow` fills all 64 fade slots with two
  generations and makes one more steal. It asserts `stolen_hard == 1`, that
  one of the older generation (B) was overwritten, and that every fresh
  fade (C) stayed fresh.
- That kills both mutations from the first review: the uncounted overwrite
  and the overwrite that always takes `fades[0]`. The findings document
  records both.

**L2, decay doc: fixed.**
- `le_synth_param_desc`'s comment now gives the one exception: drums' decay
  sets each piece's hit length through its own formula.
- The findings document states the per-piece lengths at the default:
  kick 0.72 s, snare 0.39 s, hat 0.175 s.

**Bench link (Part 2a review H1): fixed here.**
- `bench_pitch_time.sh` lists `synth_voice.c` and `synth_patch.c`.
- The wiring script now checks both bench scripts for both TUs, so the next
  pure TU cannot break a bench silently.

### Findings

None new.

### Notes

- The Pi 5 table in the findings document is still pending. It gates
  Part 2a, not this part.

Verdict: Approve
