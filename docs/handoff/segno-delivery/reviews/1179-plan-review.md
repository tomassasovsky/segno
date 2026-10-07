## Verdict: approve with required plan edits

The direction (D1 stream varispeed, D2 pre-render pitch-preserving work on the one cache worker, D3 clock untouched) is sound and matches the accepted text and the whole-track render doc. The defects below are concrete and mechanical; none needs a redesign.

### 1. Fractional read head

**E1 (correctness, blocking). The head position must be unbounded.** §2.3 defines `song_pos = seg_base + trk_pos`, "the per-frame musical position within `play_len`". With `rate = 0.5`, `index = origin + 0.5*pos` spans only `[origin, origin + play_len/2)`; when `pos` wraps the index snaps back and the second half of the take never plays. Same for a Sync division (`trk_pos = pos % len` wraps `n` times) and Free/Song. The §2.1 signature already takes `int64_t pos`; §2.3 must define it as the unbounded count: shared clock `((loop_iteration - start_iter) * clock.length + clock.position)` (reproduces `seg_base + trk_pos` at rate 1 for multiples and divisions, since `L % (L/n) == 0`), Free/Song `free_iteration * free_clock.length + free_clock.position`. Re-origin at every discontinuity of that count: transport hold, Stop/Play, `le_restart_once`, the Part 4a position scaling. Add a Part 2 test: ½× over two song laps reads indices `0 .. len-1` once (ramp oracle), and a division at ½×.

**E2 (provenance, blocking). The 322/323 tracker floods under a non-identity head.** `engine_process.c:5596-5615` emits 323 whenever `perf_source_next_pos != phase` with `next_pos = (phase + 1) % len` and `phase = trk_play_pos % len`. With `trk_play_pos = floor(idx)` the expectation fails every other frame at ½× and every frame at 2×+ (the Reverse plan already had to special-case `-1` for direction). Edit §2.6: `perf_source_next_pos` becomes `floor(le_head_index(head, pos+1, len))`, or (preferred, keeps 322/323 integer and exact under Part 4a where `phase >= restore_len` would otherwise fail `perf_render.c:924`) log `phase` in song-position space and let the renderer derive the source index through the logged head. Pick one and state it; add a test asserting zero 323 facts over a 2-lap ½× run and an 8× run.

**E3 (renderer anchor). Log the exact index at every head change.** Fact 327's payload `{numer, denom, song_frame}` gives the renderer the rate but not the origin after a continuity re-origin. Mirror Reverse's `read_index`: payload `{int32 numer, int32 denom, uint64 index_q32}` (Q32.32 of `le_head_index` at the change; the frame is already in the record header). Same for 328 (source swaps re-origin nothing, but the renderer needs the swap frame's index to place the turn). Without this the "sample-exact" criterion rests on both sides integrating identically from capture start across holds and relaunches.

**E4 (memory safety, blocking). The turn window outlives the graveyard rule.** F = `sr/100` = 960 frames = 15 periods at 64 frames; `engine_cache.c` frees a retracted entry after two processed-buffer boundaries. During a source swap (§3.2) `prev_head` reads the retracted kind-1 (or dry-pool) buffer for 15 periods. Edit §2.3/§3.2: the audio thread publishes a per-track `a_turn_source` pointer while `turn_left > 0`; the collector defers freeing any graveyard entry still referenced; a control-side pool free (undo slot reuse) that would hit the turn source snaps the window (`turn_left = 0`) first. Add an ASAN test: step, retract, and free inside the window.

**E5 (crossfade law). Name the law per cause.** Equal-gain is right for rate and direction turns (same material, continuous at the turn). A dry→transposed swap is between uncorrelated signals and dips -6 dB at mid-fade. State: equal-gain for rate/direction, equal-power for source-kind swaps, both over `seam_xfade_frames`; one helper with a flag. Also define `le_head_sample_decimated` for non-integer `rate >= 2` (window `ceil(rate)` with fractional end weights, or box of `floor(rate)`) and state that the box is first-order (-13 dB first sidelobe) and that the Part 2 listening check at 4×/8× is its gate, with the fallback named: worker-rendered half-band decimated sources (`restore_halfband.c` already exists) as a kind-2 entry, measured by the Part 1 harness. Box is acceptable for a pitch-coupled performance effect; it is not acceptable to leave 8× without a named fallback. Note "no libm on the audio thread" (floor via int64 cast, no `fmod`).

**E6. "Repeated 2× stays 2×."** The handler must treat a request equal to the current factor as receipt-only: no re-origin, no turn window, no 327 fact. State it in §2.6 and test it (no fact, no mix change).

Precision is fine: `pos < 2^31 * k`, `rate*pos < 2^37`, double mantissa 53 bits; the index is derived, not integrated.

### 2. Pre-render path

**E7 (rule 3, blocking). Eviction may silently un-transpose a playing track.** The cache's LRU under a shared cap can evict an engaged kind-1 entry to make room for a Pre print; the verdict then plays dry (a silent pitch change). Edit §3.1: kind-1 entries that match a PLAYING track's current key are never evicted; Pre prints (optional, the live chain computes the same function) are evicted first; a kind-1 job that cannot fit after that is refused with the reason (as written).

**E8 (staleness key). Kind-1 entries must not key on `chain_fp`/`vol_bits`.** A source render is pre-chain, pre-volume; keying on them re-renders 1.5–12 s of work at every volume move. State: kind-1 key is `{audio_rev, kind, semitones, out_len}` with `chain_fp = 0`, `vol_bits = 0` fixed, inside the one predicate. Add sample rate and preset to the determinism statement (both change only through configure/cache_init).

**E9. Worker priority.** Set the worker to `SCHED_OTHER` nice +10 (Linux) so the 12 s eight-lane render yields to the Flutter UI thread; the audio thread is already protected by SCHED_FIFO 80. The `render` scenario should then measure with the nice applied.

Memory: 384 MiB on 8 GiB is fine; note that a fully populated 8×8-lane 30 s rig at 96 kHz is 737 MiB of kind-1 and will be refused per track, so the Transpose face must expect "pending/refused" on dense rigs. Pending policy (dry, reported) and Session recall (install before commit, STOPPED, render ordinarily ready before Play) are correct. State the latency fact on the face: a step lands after debounce + render (1.6 s single lane, ~12 s eight lanes).

### 3. Hardware gate (Part 1)

The Pi cannot be driven unattended, so a Part 1 whose only gate is a Pi number can never close. Edits:

- **E10.** Add a `native-bench-arm64` job on `ubuntu-24.04-arm` (already used by `build-linux-arm64`, `.github/workflows/main.yaml:148`) running `bench_pitch_time.sh --budget-us 667 --assert --proxy` and uploading the arm64 harness binary as an artifact for the owner to scp. `--proxy` asserts only **p50** and throughput (a shared Neoverse VM without SCHED_FIFO has no meaningful p99): `head` added p50 ≤ 5 % at 8 lanes and ≤ 17 % at 64 lanes (half the Pi thresholds: Neoverse N2/V2 is roughly 1.5–2.5× an A76 single-thread, so this leaves a 2× margin); `render` ≥ 40× real time (2× the Pi threshold); `memory` as written. The harness prints the CPU part from `/proc/cpuinfo` and refuses `--assert` without `--proxy` unless it is a Cortex-A76.
- **E11.** Move the Pi measurement to a HARDWARE criterion that gates **Part 3's merge** (the `render` number is what D2 rests on) and Part 2's listening check; Part 1 and Part 2 close on the proxy. Record the proxy/Pi ratio in the findings doc the first time both exist, and use it as the scaling note thereafter.

### 4. Composition

- **E12.** Reverse Part 1 is being built now: commit to rebasing onto `engine_direction.h` and generalising it in place (rename to `engine_read_head.h`, `le_direction_index` → `le_head_index` at rate 1 bit-exact; Reverse's `turn_left/turn_reversed/turn_offset` → `prev_head`), rather than "whichever lands first".
- **E13.** `LE_CMD_SET_SPEED = 84` collides with Multiply/Divide's `LE_CMD_SET_LENGTH = 84` (its plan `:227`). Replace numeric assignments with "next free at rebase; the audited table row and `le_log_extract` exclusion are the check". Fact codes 324/325/326/327/328, events.log version "next at landing" and schema "next after Multiply's" are consistent; keep.
- Name `LE_CMD_RESET_TRANSFORMS` (Reverse's rename of 82) as the import-time reset and respect the stem plan's E8: a non-EMPTY caller must not reset provenance.
- #1161 (`le_record_impl` guard) and #1158 (material table) are handled correctly.

### 5. Parts

- **E14.** Part 2 (550) and Part 3 (650) each carry a native core plus the full Dart seam (bindings, four fakes, repository, projection); Reverse's Part 1 is 500 for a smaller native scope. Split each into `a` native + renderer and `b` Dart seam + repository, or raise to 700 with a stop rule.
- **E15 (rule 1).** Part 4a ships `a_follow_tempo` default On with no page to turn it off until 4b: a tempo tap on an existing rig suddenly retimes every loop. Ship 4a with default Off (today's behaviour) and flip the default in 4b with the page.
- Tests: Part 2/3/4a oracles (ramp PCM, spectral peak, zero-323, renderer parity) fail without the change. Part 1's header tests test new code only; fine as a spec. "Existing suite byte-identical" is a regression guard, not a failing test; keep it but do not count it.

### 6. Accepted-behaviour conformance

Speed absolute `{numer,denom}`, Normal restores only the factor (tempo term kept), live inputs/backing/click untouched by construction (head applies to loop lanes only; clock untouched): conforms, with E6 making "repeated 2× stays 2×" explicit. Transpose ±12 clamped in the receipt, global bypass keeps `transpose_st`: conforms. §2.6 independence holds (`rate = speed × ratio`). §2.8 Sync capture independence holds (record head never reads the head). Owner questions 1–4 are correctly flagged, not decided silently.
