Model: Claude Opus (subagent), in-session

# Review of PR #1262 (origin/claude/instruments-1197-p2c @ 69f6c4cdf, stacked on #1261): feat(engine): route MIDI to instruments with sustain and expression

## Scope

- The branch merges trunk and #1246 (the shared MIDI sink, `8c2f43d48`),
  then adds one instrument commit, `69f6c4cdf`. I reviewed that commit
  against its merge parent `3260322c7`, which is 12 files, +1391/−55:
  - `engine_instruments.{c,h}`: routing, the tables, the remap index,
    control sustain;
  - `synth_voice.{c,h}`: the SUSTAINED state, contributors, expression,
    `le_synth_release_matching`, chord note-on;
  - `engine_process.c` (`le_midi_port_dispatch`) and `engine_private.h`;
  - the API, the snapshot, the bench, 455 lines of tests, and the second
    scenario of `test_instrument_races.c`.
- I did not re-review the sink itself (#1246) beyond the drain order it
  hands to this part.
- Reviewed against:
  - Part 2c, D4 and §2.3 of the plan at `5e36d2666`;
  - accepted behaviour `:382-387`;
  - the prototype `instrument-runtime.js` (`noteOff`, `setSustain`,
    `silenceController`, `update`);
  - AGENTS.md and the owner rules.

## Runs

Each run used a fresh TMPDIR, in a scratch worktree at `69f6c4cdf`. The
machine's load average was about 40.

- **Native suites, first round:** plain, ASAN and telemetry off each failed
  one check. It was the same pre-existing timing flake as on Part 2a and
  Part 2b, `test_fade_restore_staging_and_manifest_capacity`
  (`test_engine_fade.h:898`), and every other check passed.
- **Re-runs:** plain ALL PASSED; ASAN failed again on the same fade check only. CI's native-tests-asan job passes on the PR head.
- **The new race scenarios**, in every build:
  - "instrument rings: 300000 pairs, 0 stuck notes";
  - "instrument routing: … 40000 publishes …, 0 stuck notes" in the plain,
    ASAN and telemetry-off builds (1.7 to 4.9 million MIDI pairs, 13,000 to
    38,000 overflow blocks).
- **TSAN races job:** 0 failures, with no TSAN report. The routing scenario
  ran 113,352 pairs and 2,000 publishes, with 0 stuck notes.
- **Bench smoke:** both benches run. The joint smoke line on this loaded
  machine is noise.
- **PR CI on `69f6c4cdf`:** 23 checks pass. **native-bench-arm64 FAILS**:
  "joint worst case p50 <= 37.5% of period (42.72 vs 37.50)" (run
  37531063193, job 112500272057; finding H1).
- **Probes** (`p2c_probe.c`, linked against the full engine, with a capture
  stand-in on the shared sink):
  1. bend, the mod wheel and a note from port 2, then MIDI turned off for
     the instrument;
  2. CC1 remapped on instrument 1 while instrument 0 uses the mod wheel;
  3. a patch change posted, then a MIDI note in the same block.

## Stuck-note hunt (traced and tested; no stuck note found)

- **GAP, LOST and REBOUND.** All three call `le_instruments_midi_gone`,
  which calls `le_synth_release_matching(port mask)`. That does four things:
  - removes the port's sustain contributors on every instrument;
  - lets the port's held voices go as a Note Off would (sustained if a
    control-thread or other-port contributor still holds the instrument);
  - releases every SUSTAINED voice that nothing holds any more;
  - resets the expression this port set (`inst_expr_port`).

  Control origins (tag bit) never match the port mask. GAP is dispatched at
  its stream position, so a note queued before the dropped Note Off plays and
  is then released. Covered by `test_midi_routing_overflow_releases_after_queue`,
  `..._gap_releases_at_its_position`, `..._detach_and_loss` and
  `..._gone_ends_sustain_and_expression`.
- **A table switch mid-chord.** A Note Off, a Note On at velocity 0 and a
  CC below 64 call `le_synth_note_off(origin)` before any table is read, on
  every instrument (`engine_instruments.c` `le_instruments_midi_event`). So
  removing a remap, disabling MIDI, changing the channel or moving the range
  while a chord or note is held cannot strand it. Covered by
  `test_midi_routing_note_off_survives_route_edits`, which runs all four
  edits with an ordinary note plus a remapped chord.
- **The routing race scenario** republishes tables 40,000 times (channel,
  range, remap, enable) against a live MIDI thread and the callback, rebinds
  in its second half, and ends with 0 stuck MIDI voices.
- **Sustain from several sources.** Contributors are per instrument (16),
  keyed by origin. Each one has its own end:
  - a CC64 is removed by origin everywhere on CC64 below 64;
  - a port's contributors are removed when the port is gone;
  - control contributors are removed through the release lane;
  - a patch change or Cut clears them all.

  `release_sustained` runs whenever the count reaches zero, so a SUSTAINED
  voice always has an exit. The pieces:
  - repeated strikes under sustain stay distinct (the restrike rule touches
    HELD only);
  - drums never sustain;
  - a seventeenth contributor is refused and counted.

  Covered by `test_midi_routing_sustain_contributors` and the gone test (a
  control pedal keeps notes ringing after the port goes).
- **Channel change or MIDI off while a note is held.** The note ends at its
  key release (by origin), and a held CC64 ends at its own release (by
  origin). Nothing is stranded. See M1 for what does stay behind.
- **Double-buffered tables.**
  - The producer refuses with `LE_ERR_NOT_READY` while
    `a_inst_routes_seen != a_inst_routes_live`, loading it with acquire
    (paired with the callback's release store in
    `le_instruments_midi_begin`).
  - It writes the idle table and its remap index, then publishes `live`
    with release.
  - The callback loads `live` with acquire once per block, before any port.
  - While stopped, the switch is immediate.
  - The same table is used for the whole drain, so a mid-block switch is
    impossible. TSAN is clean on the handover.
- **The remap index** is built on the control thread with the table (bit
  `c` for channel `c+1`, all bits for "any"). A message whose bit is clear
  skips the remap scan on every instrument, which is correct because the
  index is a superset of the remaps that match.
- **Expression** follows the prototype's `update()`:
  - bend is ±200 cents and modulation adds 45 cents of LFO depth;
  - pressure adds up to ×1.25 level;
  - all three are applied on the 32-frame control grid;
  - a 14-bit bend is centred at 8192.

## Findings

### High

**H1. The arm64 proxy bench fails, so native-bench-arm64 is red (`src/test/bench/bench_instruments.c`, the joint routing load).**

The joint scenario now posts 8 ports × 255 events and 256 control note-offs
before every period. On the proxy runner its p50 is 42.72 % against a
37.5 % limit.

The same scenario without the load is 36.3 % (#1234) and 35.3 % (#1261), so
the routing load costs about 7 points of the period. The plan's own Part 2c
criterion (line 1114) requires this job green.

Fix: this needs a budget decision first (plan delta D8):
- either keep the full-ring load and move the joint threshold, which also
  affects the Pi set the owner is about to run;
- or put a realistic MIDI rate in the joint scenario and bench the ring-full
  burst as its own scenario with its own threshold.

### Medium

**M1. Turning MIDI off or moving an instrument's port or channel leaves the port's bend, modulation and pressure on that instrument (`engine_instruments.c:406-423`, only called on GAP, LOST and REBOUND).**

Expression is reset only when the port goes away. Reproduced with the probe:
1. bend 16383, CC1 127 and a note from port 2;
2. publish a table with `midi_enabled = 0`;
3. after two blocks, bend is still 1.000 and modulation 1.000;
4. a touch note posted afterwards (`le_engine_instrument_note_on`) plays two
   semitones sharp with full vibrato.

This lasts until that same port sends a new bend or CC1 on a channel that
still routes there, or until the device is unplugged. If the user moved the
instrument to another channel, nothing on the new channel resets it.

The reference clears an instrument's MIDI expression whenever its MIDI
configuration changes or MIDI is turned off (`instrument-runtime.js:221-227`,
`silenceController`, called at `:351`). Accepted `:382-387` asks that
"disable … release the right voices", and leaving pitch bent is a silent
change (rule 3).

Fix: in `le_instruments_midi_begin`, when a new table is switched in, reset
each instrument's expression whose `inst_expr_port` port no longer routes to
it (MIDI disabled, port changed, or channel no longer matching). Add a test
for each of the three edits.

Also decide, and write down, whether held MIDI notes are cut when MIDI is
disabled (the reference) or end at their key release (the built rule,
pinned by `test_midi_routing_note_off_survives_route_edits`).

### Low

**L1. A held remapped CC suppresses the same CC on every other instrument (`engine_instruments.c:480-481`).**

`if (remapped && cc && d2 >= 64 && le_synth_held(s, origin)) return;` runs
before the per-instrument loop, so it also drops the ordinary handling for
instruments that do not remap that controller.

Reproduced: CC1 remapped on instrument 1 (a chord), mod wheel on
instrument 0. At CC1 = 80, instrument 0's modulation is 0.630. At
CC1 = 127 it stays 0.630 (expected 1.000), because the first value of 64 or
more struck the chord and every later one returns early.

Fix: apply the held-switch check per instrument, only when that
instrument's `find_remap` matched.

**L2. MIDI is drained before the control rings, so a MIDI note in the same block as a patch change plays the old patch and is faded 3 ms later (`engine_process.c:6525` vs `:6529`).**

`le_midi_ports_drain` runs before `le_instruments_block`, whose
`drain_events` applies `SET_PATCH`.

Reproduced: slot 2 plays organ. `le_engine_set_instrument(2, lead)` is
posted, then a MIDI Note On for that slot. After the block, the voice is
organ in state FADING, so the note is lost.

The plan's §2.2 (lines 794-797) orders the control rings first. Auditioning
sounds (Listen) while playing a keyboard hits this once per patch change.

Fix: drain the control rings, then the ports, then render. For example,
split `le_instruments_block` into an apply step called before
`le_midi_ports_drain` and a render step after it, as the plan says.

**L3. The bench's routing load never exercises the remap scan, and its comments say it does (`bench_instruments.c:34`, `:218`).**

The comments say "each one scans all 256 remaps". But the remaps are on
channel 16 and the load is on channel 1, so the new remap index skips every
scan. That is the index's purpose, but it means the heavy path (a message
the index admits, with eight instruments × 32 remaps compared) is
unmeasured.

Fix: correct the comments, and add one index-admitted message per port to
the load.

## Notes

- **CoreMIDI.** It does not mark loss natively. The plan states this
  (macOS is a development host; the Dart poll's close gives LOST plus
  REBOUND).
- **Origin space.** `le_engine_instrument_note_on`, `_note_off` and
  `_sustain` OR the control tag into the caller's origin, so Dart origins
  can never collide with MIDI origins, as D4 intends.
- **The fade flake** is pre-existing and load-dependent. Details are in the
  Part 2b review's Notes.

Verdict: Request changes (H1 is a red required job; M1).
