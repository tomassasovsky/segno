---
title: "feat: tempo-aware looper epic — the remainder (C2, Phase D, Phase E)"
type: feat
date: 2026-08-25
issue: 263
index: 2026-07-22-feat-tempo-aware-looper-modes-plan.md
---

# The tempo epic's remainder — what is actually left of #263 (and what is not)

The epic's part files (parts 1–5) still read as if 26 PRs lie ahead. They do
not. This document is the verified shipped/remaining split, the decisions the
owner must make before the rest can build, and the deltas that the last month
of shipped work (the D0 spike, the console IA rebuild, FX v3's pedal protocol
v3) imposes on the original part-3/4/5 specs. It **amends** those part files —
it does not replace them; the per-PR test lists and success criteria there
remain normative except where a delta below says otherwise.

## Shipped — verified in code, not from memory

Every claim below was checked against master (`61609b35`), not against the
issue's comment thread:

- **Phase A (8 PRs, #265–#283) and Phase B on master.** `tempo_grid.c/h`
  exists in `packages/segno_engine/src/core/`; the five-mode field,
  per-track clocks, Sync divisions, Band sections, and Song mode are all in
  `engine_process.c`/`engine_commands.c`; session manifest v4 carries
  `tempoBpm`/`tempoSource` (`packages/session_repository/lib/src/models/session.dart:552-687`).
- **C1 merged (#293).** `packages/segno_engine/src/midi/le_midi_clock.c/h`
  exists; the tri-state `le_clock_mode` is public API
  (`segno_engine_api.h:141-146`) with `LE_CMD_SET_CLOCK_MODE = 48` and
  `LE_CLOCK_RECEIVE` explicitly rejected until Phase E.
- **D0 merged (#267).** Signalsmith Stretch 1.1.0 is vendored **under the
  bench harness only** (`packages/segno_engine/src/test/bench/third_party/signalsmith-stretch/`),
  excluded from `run_native_tests.sh`. The findings doc
  (`docs/plan/2026-07-22-time-stretch-spike-findings.md`) is a GO with a
  design materially simpler than part 4 assumed — see the D2 deltas below.
- **B5b is not what the part-2 file thinks it is anymore.** The firmware in
  `firmware/segno_pedal/pedal_protocol.h` already decodes **v3**
  (`PEDAL_PROTOCOL_VERSION_V3 0x03`, shipped with FX v3 part 5a), which
  strictly contains v2's mode/counting-in bits. There is no "pedal firmware
  v2" left to write — only a physical flash + on-device verify, which is an
  ops action, not an engineering PR.

## Remaining — also verified in code

- **C2 (app UI + `clockMode` manifest field): not started.** `grep clockMode`
  across `lib/` and every package's `lib/` returns nothing; the only Dart
  file mentioning "clock" is `lib/control/invariants.dart`. The native
  tri-state is unreachable from the app.
- **D1 (vendor stretch into the real build): not started.** There is no
  `packages/segno_engine/src/stretch/`; the library exists only under
  `src/test/bench/`.
- **D2 (engine integration), D3 (UI + manifest D fields): not started.**
  `session.dart` has no `syncAudioToTempo`/`originalTempoBpm` fields.
- **E1–E3 (clock receive): not started.** `midi.c:84` still documents the
  real-time-byte drop ("0xF0 system/real-time/SysEx: all ignored"); no
  follower exists in `src/midi/`.

So the remainder is **seven PRs**: C2, D1, D2, D3, E1, E2, E3 — with E3
carrying the epic's `Closes #263` per the tracking contract in the index plan.

## Decisions for the owner

### Decision 1 — the varispeed leg (two-toggle model): ship it or not

The Sheeran manual (§5.9.5, transcribed in the song-mode spec) has **two
independent toggles**: *Sync Audio to Tempo* (loops follow tempo; varispeed —
pitch shifts with rate) and *Time Stretch* (pitch preserved). Part 4 was
written pitch-preserved-only with the two-toggle question deferred to the
spike. The spike answered the cost question decisively: the varispeed leg is a
linear-interp resampler measured at **~100× cheaper than stretch** (64 streams:
p99 0.07 ms) and "adding it in D2" is the spike's own recommendation.

- **Option a — ship both toggles (recommended).** Full Sheeran parity, near-
  zero engine cost, and the varispeed path is the *cheap* fallback on weaker
  hardware (the Pi console). Manifest grows a second flag (`timeStretch`
  alongside `syncAudioToTempo` — the spike found no naming conflicts).
- **Option b — pitch-preserved-only.** One fewer toggle in the tray, one
  fewer manifest field; documented deviation from the manual. Saves almost
  nothing in engine work (the resampler is ~a page of code next to the
  stretcher integration).

**Recommendation: option a.** The engineering delta is trivial and parity is
the epic's stated goal.

### Decision 2 — B5b's disposition

- **Option a — descope B5b from #263 (recommended).** The firmware work
  shipped inside FX v3 part 5a as protocol v3 (a superset of v2). What
  remains — flashing a physical pedal and verifying LEDs/mode display on
  hardware — is `autonomy:blocked-verify` ops, not part of this epic's build.
  Record the descope on #263 so the epic can close on E3 without a hardware
  session.
- **Option b — keep B5b open inside #263.** Then E3's `Closes #263` is wrong
  and the epic's close is hostage to bench time.

**Recommendation: option a**, with the flash tracked wherever pedal-hardware
ops work already lives (or a one-line issue of its own).

### Decision 3 — where the remaining UI lands (C2, D3, E3)

Parts 3/4/5 say "tempo settings section, UI conventions per index" — written
**before** the console IA rebuild. The tempo surface today is
`lib/looper/view/tempo_settings_section.dart` plus the loop-tray tabs
(`lib/looper/view/loop/tempo_loop_tab.dart`, `click_loop_tab.dart`), and the
design source of truth is `segno-ui.pen` (411 screens; the pen is
authoritative, and a shipped deviation must be written back into it).

- **Option a — spec each UI PR against the current tray + pen (recommended):**
  clock mode joins the tempo loop tab (C2); Sync Audio to Tempo / Time
  Stretch join it in D3; receive state (locked/lost, disabled tempo controls)
  in E3. Each UI PR updates the pen alongside the code.
- **Option b — a fresh mini design pass first.** Only worth it if the owner
  wants the tempo tray rethought; nothing in the remaining scope forces it.

**Recommendation: option a.** These are additive controls on an existing,
recently redesigned surface.

### Decision 4 — ordering

Hard edges: E hard-depends on C1 (done) **and** D (slave restrictions force
Sync Audio to Tempo on — index D3). C2 depends on nothing remaining.

**Recommendation:** C2 first (small, unblocks real-world use of the already-
shipped emitter), then D1 → D2 → D3, then E1 → E2 → E3. Autonomy labels as
the part files already assign them: engine PRs `auto`, UI PRs `merge-gate`.

## Implementation outline — deltas to the part files

The part-3/4/5 task lists stand. The following spike/landscape facts are now
**normative** and override part 4 where they differ:

- **D2 uses the spike's design, not part 4's open questions:**
  `presetCheaper`; **one stretcher per lane** (per-track would bake the lane
  mix behind 100 ms of latency); **inline on the audio thread** — no worker
  thread, no crossfade-fallback machinery; **hop-phase staggering at stream
  creation** (3.4× p99 win, "cheap, do it always"); fractional input
  accumulator per stream (the library has no ratio parameter); construct/
  `configure()` on the control thread, hand off to audio (allocates MBs);
  fixed RNG seed in tests; one C++ TU shim exposing a C ABI (precedent: the
  plugin-host C++ sources already compiled into the engine). The D13
  "double memory" budget is dead — measured overhead is stretcher state only
  (≤ 36 MiB at the 64-stream ceiling).
- **D2 must also log tempo into the perf event log.** Today `LE_CMD_SET_TEMPO`
  is not in the audited table — sound, because tempo is locked while content
  exists (`segno_engine_api.h:186-189`). D2's relaxation of that lock to the
  0.5×–2× window breaks the "a capture is single-tempo" assumption that
  `daw_export` relies on; the same PR that relaxes the lock must add the
  tempo transport fact (see the #279 plan,
  `2026-08-25-feat-bar-aligned-als-export-plan.md`, which consumes it).
- **D1 vendors from the bench snapshot**, not from upstream: same tag 1.1.0 /
  commit `44c8f865`, into `src/stretch/`, wired into `src/CMakeLists.txt`,
  the podspec forwarders, and `run_native_tests.sh` globs; the bench copy
  then imports from the real vendored location or is deleted.
- **E1's entry point is unchanged and verified:** the byte-drop to lift is
  `midi.c:84` (route 0xF8/FA/FB/FC to the follower only; the Dart controller
  stream never sees them — keep the regression test the part-5 file names).
- **Every FFI-crossing struct change regens ffigen in the same PR** — the B3
  heap-overflow lesson; `le_snapshot` grows fields in D2 (stretch state) and
  E1 (follower state).

PR slicing stays exactly the part files' seven: C2 / D1 / D2 / D3 / E1 / E2 /
E3, each independently green, stacked ≤ 3 deep.

## Verification plan

- Native: `bash packages/segno_engine/src/test/run_native_tests.sh`, plus the
  ASAN variant on D2/E1 (stretch buffers and follower state are the two big
  new allocations).
- Dart: `/Users/Tomas/development/flutter/bin/flutter test`, `dart analyze`,
  `bloc lint lib test packages` (run from the repo checkout, not a worktree —
  worktree bloc-lint is a silent no-op).
- The **bit-identical gate** holds at every merge: grid-off Multi behaves
  exactly as today; all pre-existing native + Dart tests unchanged.
- Manual gates as the part files specify: Ableton slaved to segno (C-side,
  already possible after C2), segno slaved to Ableton (E3), 8-track stretch
  listening pass at `presetCheaper` before D3 closes (WAV dump via the bench
  harness).

## Acceptance criteria

- All seven PRs merged; E3's merge auto-closes #263.
- `clockMode`, `syncAudioToTempo`, `originalTempoBpm` (+ `timeStretch` under
  decision 1a) round-trip through the v4 manifest.
- The D2 tempo-lock relaxation lands **with** its perf-log tempo fact.
- B5b's disposition (decision 2) recorded on #263.
- `docs/PROGRESS.md` tempo-system section updated at E3 (the part-5 closeout
  task).

## Non-goals

- Bar-aligned `.als` clips — #279, planned separately (this epic only feeds
  it the tempo fact from D2).
- Persisting capture-time tempo for re-export — #281.
- The physical pedal flash (decision 2) and any new pedal protocol work
  (protocol v4 belongs to the FX-v3 console epic, #442).
- SPP, MTC, Ableton Link; per-track independent stretch ratios.
