Model: Claude Opus (subagent), in-session

# Review of PR #1223: feat(engine): the shared decoder, band-limited conversion, probe and memory floor (#1200 Part 2)

## Scope

- **Branch:** `origin/claude/backing-1200-p2` at `d81d14170`, stacked on P1 `75b7e84c7`. Its commits are `6a44ce254`, `8764588d7` and `d81d14170`. Merges cleanly into trunk `097e1ef68`.
- **Code reviewed:**
  - `src/core/engine_decode.c` (new): the decoder, probe, memory floor and polyphase converter;
  - `miniaudio_impl.c`: `MA_NO_DECODING` replaced by `MA_NO_FLAC`;
  - the header additions;
  - `fuzz_backing_decode.c`;
  - the fixtures;
  - the P2 half of `test_engine_backing.h`;
  - the vendored dr_wav, dr_mp3 and `ma_decoder` paths that the decoder reaches (miniaudio 0.11.21).
- **Reviewed against:**
  - the plan at `c05ba9f45` (D2, D2a, D3, D11 and Part 2);
  - AGENTS.md;
  - the owner rules.
- **Identity:** P2 contains no identity code. `le_digest_file` is on trunk (`engine_digest.h`), and the plan uses it in Part 4.

## Runs

**Native suite**
- Plain, ASan, telemetry-off and the TSAN races job, each in its own `TMPDIR`.
- The first pass ran eight jobs at once; under that load the plain and telemetry-off runs failed one load-sensitive fade check (`test_engine_fade.h:898`, a 5 s wait).
- Rerun serially: every configuration reports ALL PASSED.
- The in-repo fuzz driver prints `2000 inputs, 0 violations` in every configuration.

**Dart and symbols**
- `segno_engine` Dart suite: 376 tests, all passed.
- `dart analyze --fatal-infos packages/segno_engine`: clean.
- `dart run ffigen` plus `dart format`: no diff in the generated bindings.
- Symbol parity: checked by hand, because `check_ffi_symbols.sh` needs GNU `nm -D`. 217 names, all exported apart from MIDI, which the test library does not link.

**Resampler check:** an independent harness, `repro/rs_probe.c`, calls the internal `le_resample_offline` directly.
- It fits amplitude and phase by least squares and measures the residual.
- It also measures aliases, images and impulse alignment, at 12 rate pairs.

**Decoder probes:** `repro/dec_probe.c` runs every corpus file through `le_backing_probe_file` and `le_backing_decode_file`, in release and ASan builds.
- The corpus is generated with ffmpeg 8.0.1. It covers WAV s16, s24, s32, f32, f64 and u8, μ-law, A-law, IMA-ADPCM, MS-ADPCM, extensible, RF64, W64, AIFF, AIFC float, a 6-channel WAV and MP2.
- MP3s: CBR and VBR, 8 kb/s, ID3v1 and ID3v2 tags, embedded JPEG and PNG cover art, a stream cut mid-reservoir, and two files joined.

**Peak memory:** `/usr/bin/time -l` on 60 s stereo float WAVs.

**Fuzzing beyond the in-repo driver:** `repro/myfuzz.c` wraps the PR's own `LLVMFuzzerTestOneInput`.
- It is seeded with the whole corpus above and mutates anywhere in the file, including chunk-size edits and splices.
- It runs under ASan and UBSan with a 10 s per-input watchdog.
- Three campaigns of four or five processes each. Every campaign stopped on a finding within minutes (below).
- libFuzzer from Homebrew LLVM hung at start-up on this machine, so it was not used.

**In-repo driver at volume:** `SEGNO_FUZZ_ITERATIONS=50000` under ASan: `50000 inputs, 0 violations`. Its narrow mutations never reach the inputs behind H1, H2 and M1, which the wider driver hit within minutes.

**Mutations:** a backing-only ASan driver, one mutation at a time.
- Removing the output term from the memory-floor estimate is **not caught** (L3).
- The probe's `fabsf` removal is caught.

## Verified correct (traced)

### The converter meets every accuracy claim, measured independently

**DC**
- Error at most 6e-8 away from the edges (−138 dB) for 44.1↔48, 96→48, 44.1→96, 48→96, 88.2→48, 32→48, 22.05→48 and 176.4→96.
- Low source rates show edge effects only, inside the 32-input-sample kernel reach.

**1 kHz at amplitude 0.5**
- Gain error is 0.0000 dB.
- The residual after removing the fitted tone is −117 to −156 dB.
- Phase error is below 1e-12 rad: no delay.

**Passband**
- At 0.5, 0.85 and 0.9 of the lower Nyquist the gain is within 0.0001 dB.

**Aliases and images**

| Case | Measured |
|---|---|
| 30 kHz → 18 kHz alias, 96 to 48 | −113 dB |
| 27 kHz → 21 kHz alias | −110 dB |
| 40 kHz → 8 kHz alias, 88.2 to 48 | −117 dB |
| 10 kHz → 34.1 kHz image, 44.1 to 96 | −114 dB |
| 25 kHz → 23 kHz, inside the declared transition | −20.8 dB |
| 23 kHz at 48 → 44.1, folding to 21.1 kHz | −21.7 dB |

The last two sit in the declared 0.45–0.55 r transition, exactly as D3 says ("aliases fold only above 0.45 · out_rate").

**Alignment**
- An impulse lands on exactly the expected output index, with the energy centroid exact to 1e-4, for 44.1→48, 48→96, 96→48, 44.1→96 and 48→44.1.
- The half-band stage is centred (`restore_halfband.h`), so the 192 kHz path is aligned too.

**Phase arithmetic**
- The phase index `(t·in mod out)/g` is always a multiple of the gcd and below `out/g`.
- The window argument stays inside (−1, 1).
- Each phase row is normalised to unity DC.
- Strided output goes straight into the interleaved buffer.

### Allocation and length checks

- The whole-file cap is checked from the stated length before allocating (`:386`), and again on the decoded length (`:415`).
- The stated length is bounded by file bytes × 512 (`:233`).
- The length match (`:420`) refuses truncated files.
- A bounded read with `max_frames == 0 && start_frame > 0` is still capped at `cap + 1` frames, because `size = min(want, stated − start)` with `want = cap + 1`.

### MP3 behaviour

- Real-world MP3s decode: ID3v1 and v2 tags, large ID3v2 cover art (75 KB JPEG, 1.1 MB PNG), CBR and VBR, and a stream cut mid-reservoir.
- On a cut stream, the scan count and the decoded count agree, because dr_mp3 drops the same frame in both. No false "damaged".

### Odds and ends

- **Struct layout:** `MA_NO_FLAC` does not change any header struct layout. `ma_decoder` is unconditional, so `engine_decode.c`, which includes `miniaudio.h` without the impl defines, sees the same layout.
- **WAV metadata:** `ma_wav_init_file` calls `ma_dr_wav_init_file` (no metadata flag), as D2a says.
- **The probe:** it holds one 32 KB chunk and no PCM, as claimed.

## Findings

### High

**H1. A 2 KB WAV with 255 or 256 channels aborts the whole process. The check comes after the code that crashes.**
- **Where:** `engine_decode.c:219` (`ma_decoder_init_file`), before the channel check at `:230`; the crash is in vendored `miniaudio.h:65206`.
- **Mechanism:**
  1. dr_wav accepts the header.
  2. `ma_decoder__postinit` fails, because `MA_MAX_CHANNELS` is 254.
  3. The failure path calls `onUninit(pUserData, &pDecoder->pBackend, …)`. That passes the address of the field, not the backend pointer.
  4. `ma_decoding_backend_uninit__wav` then calls `ma_free` on an address inside the caller's stack `le_decode_src`.
- **Reproduced:**
  - In the release build, `repro/ch256_s16.wav` (canonical PCM-16, 256 channels, 4 frames, 2,092 bytes) makes `le_backing_probe_file` and `le_backing_decode_file` exit with SIGABRT (134). 255 channels does the same; 254 and 1000 are refused cleanly.
  - ASan reports `bad-free … ma_decoder_init_file miniaudio.h:65206`, with the address inside the stack variable `s` of `le_backing_probe_file`.
  - The fuzzer reached it from float and A-law seeds (format tags 3 and 6, channels 0xFFFF).
- **Failure scenario:** a performer adds a file from a USB drive. The import probe runs in-process (D2), so the app aborts, the audio stops, and the loops are lost. This is exactly the residual risk D2a accepts as theoretical, and it is reachable in seconds.
- **Fix:**
  1. Read and validate the RIFF/`fmt ` header yourself (channels 1-2, rate in range, format tag PCM or IEEE float) before any miniaudio call. Better still, open WAV with `ma_dr_wav_init_file`, check `channels`, `sampleRate`, `container` and `translatedFormatTag` on the `ma_dr_wav` struct, and only then convert.
  2. Patch line 65206 to pass `pDecoder->pBackend`, as a recorded `SEGNO PATCH` until the miniaudio update.
  3. Add `ch256_s16.wav` as a refusal test.

**H2. A RIFF WAV whose `fact` chunk is shorter than 4 bytes (and a Wave64 file with a huge chunk size) hangs the probe and the decode for hours.**
- **Where:** vendored `miniaudio.h:79081-79100`, through `ma_dr_wav__seek_forward` (`:78028`).
- **Mechanism (`fact`):** for RIFF, the `fact` handler reads 4 bytes unconditionally and does `chunkSize -= 4`. With a declared size of 0 or 1, the `ma_uint64` wraps to about 1.8e19. `ma_dr_wav__seek_forward` then advances in `0x7FFFFFFF` steps, and `fseek` past EOF succeeds on a regular file. That is billions of calls before `lseek` overflows.
- **Mechanism (W64):** the same loop runs for a W64 chunk header with a 64-bit size.
- **Reproduced (release build):**
  - `repro/fact0_fmt1.wav`, 252 bytes: canonical PCM-16 mono, then `fact` with size 0, then `data`. It and its size-1 and float variants never return.
  - `repro/w64_huge_chunk.bin` (15.6 KB, W64) did not return within 30 s.
  - The fuzzer reached all of these within minutes.
- **Failure scenario:**
  - Import runs the probe in `Isolate.run`, which cannot be cancelled mid-FFI. The import never completes, a core spins in `lseek`, and the import UI stays in progress forever.
  - The only recovery is restarting the app, which stops the performance (rule 2: no recovery path). The same file in a session's prepared list would hang the decode at `Play selected`.
- **Fix:**
  - Validate chunk sizes before miniaudio sees the file. Refuse a `fact` chunk under 4 bytes, and refuse any chunk size larger than the remaining file bytes.
  - Refuse every container except RIFF (and RF64 only if wanted, with the same size check).
  - Add both files as refusal tests.
  - Give the decode an upper bound on wall time or on read calls, as defence in depth.

**H3. Non-finite float samples are accepted. One NaN permanently silences every source on an output bus that has a reverb or filter.**
- **Where:**
  - `engine_decode.c:280-330`: the probe's peak scan treats NaN as 0, because `fabsf(NaN) > peak` is false;
  - `:485-491`: the decode copies NaN and Inf through;
  - P1 `backing_frame` (`engine_process.c:4677`) sums them before the output buses.
- **Reproduced:** `repro/nan_probe.c` builds a 1 s float WAV with one NaN at frame 100.
  - The probe returns OK, and the peaks read 0.1, which hides the NaN.
  - A loop and the backing both play on bus 0. With the output-bus effect set to:
    - **Reverb (type 7):** after the backing is cleared, the loop's output is about 95,700 non-finite samples per second for every second measured (3 s), with no decay.
    - **Filter (type 2):** the same, entirely non-finite.
    - **Delay (type 3):** a few NaN samples recur each second.
    - **No FX:** only the two NaN frames themselves reach the device. What the driver makes of a NaN is backend-dependent; I did not measure it.
  - Inf: without FX the limiter's gain drops to 0, and Inf × 0 = NaN for that frame. It recovers by release.
- **Failure scenario:**
  - The performer imports a damaged 32-bit float WAV, which is easy to produce with a bad export or a disk error.
  - It passes import, and the first time it plays, every loop on Main goes silent or full-scale until the chain is reset.
  - Rule 2 is broken (not fail-safe, no notice), and so is rule 3.
- **Fix:**
  - The probe and the decode refuse any non-finite sample ("Damaged audio"). They already touch every sample, so the cost is one `isfinite` per sample.
  - Optionally, `le_backing_buffer_from_pcm` refuses them too.
  - Add a NaN-WAV refusal test, and a native test showing that an output chain survives an attempted NaN load.

### Medium

**M1. The decoder admits far more than "WAV PCM/float and MP3", through paths nothing tests or fuzzes, and one has a memory-safety bug.**
- **Where:** D2 says WAV PCM/float and MP3. `le_decode_open` restricts only rate, channels and the output format.
- **Accepted as observed:**
  - MS-ADPCM, IMA-ADPCM, μ-law and A-law WAV;
  - WAVE_FORMAT_EXTENSIBLE;
  - RF64, W64 and RIFX;
  - AIFF and AIFC (float);
  - MPEG Layer II (`mp2.mp2` decodes) and, by the same minimp3 path, Layer I.
  - These are accepted whatever the file extension, because `ma_decoder` falls back to trying every backend.
- **Memory-safety bug:**
  - The MS-ADPCM block predictor is a file byte used to index `coeff1Table[7]` and `coeff2Table[7]` (`miniaudio.h:80688`, `:80741`) without a bounds check. UBSan reports `index 255 out of bounds for type 'ma_int32[7]'`.
  - In the release build, `repro/msadpcm_oob.wav` (two predictor bytes set to 250) decodes with 2,020 of 6,072 samples changed and pinned at full scale (±1.0). The coefficients come from memory past the table.
  - UBSan also flags signed overflow in the ADPCM delta update (`:80768`).
- **Fuzz coverage:** the in-repo driver seeds only PCM and float WAV, the MP3 fixture and the (refused) FLAC. It mutates 32-bit values only in the first 64 bytes, so it cannot reach these paths or H1 and H2.
- **Fix:**
  - Whitelist explicitly: RIFF with format tag 1 or 3 (and extensible with a PCM or float subformat), and MP3 Layer III only. dr_mp3 can be built Layer-III-only, the way minimp3's `MINIMP3_ONLY_MP3` works.
  - Seed the fuzz driver with every whitelisted and every refused variant.
  - Mutate the whole file, add a per-input timeout, and run UBSan in the ASan job.
  - Update D2 to say what is refused.

**M2. The memory floor underestimates the half-band path's peak by up to about 2x, and D11's "worst case" figure is wrong.**
- **Where:** `engine_decode.c:394-399` checks `(size + out_estimate) · 2 · 4` bytes. The halving path (`:434-466`) builds per-channel planes while `src` is still alive, so its peak is about `2 · size · channels · 4` bytes.
- **Measured** (60 s, 192 kHz, stereo float WAV, decoded at 48 kHz):

| | Bytes |
|---|---|
| Peak footprint | 209 MB |
| What the floor check budgets | 115 MB |
| 192 to 96 (no halving), measured | 140 MB |
| 192 to 96, estimated | 138 MB (accurate) |

- **Scaled to 15 minutes:**
  - a 192 kHz stereo source at 48 kHz peaks near 2.8 GB against 1.7 GB checked;
  - a 384 kHz source (D2a accepts up to 384 kHz) peaks near 5.5 GB against 3.1 GB checked.
- **Plan claim:** D11 lists "one decode in flight: about 1.0 GB worst case (15 min, 44.1 kHz stereo source to 96 kHz)". That is the worst case only for 44.1 kHz sources; a 192 kHz source to 96 kHz is about 2.1 GB.
- **Failure scenario:** on the 8 GB, swapless Pi, with loops recorded and A loaded and B staged, MemAvailable passes the check but the real peak does not fit. The OOM killer ends the app (rule 2).
- **Fix:**
  - Halve the interleaved source in place, or plane by plane while freeing `src` progressively. Alternatively, include the planes in the estimate.
  - Lower `LE_DECODE_MAX_RATE` to 192 kHz.
  - Correct the D11 row to the true maximum.
  - Add a test in which the memory hook allows `size + out` but not `2 · size`.

### Low

**L1. The probe accepts rates the converter refuses, so a file imports cleanly and fails only when played.**
- **Where:** `le_resample_offline` refuses more than 8192 phases (`:160-161`), and `le_backing_decode_file` refuses an odd rate above twice the engine rate (`:448-450`). The probe checks neither.
- **Reproduced:** `repro/r44101.wav` and WAVs at 11127 Hz (a classic Mac rate), 47999 Hz and 96001 Hz all give probe `LE_OK` and decode `LE_ERR_INVALID`, which reads as "damaged".
- **Why it matters:** this breaks D2's guarantee ("a performance never meets a file that has not decoded cleanly once"), and the reason given is wrong.
- **Fix:**
  - Either have the probe refuse what the converter cannot do, for the 44.1/48/88.2/96/176.4/192 kHz engine rates, with a "sample rate not supported" reason;
  - or make the converter handle any ratio, for example by falling back to more phases with linear interpolation between table rows.

**L2. A bounded read that resamples has a zero-padded left edge.**
- **Where:** `:377-385`. A preview starting mid-file has no source frames before `start_frame`.
- **Effect:** the first ~32 output frames of a resampled preview are an edge transient, and the output grid is offset by a fraction of a frame from the whole-file decode.
- **Fix:** read up to `half` extra source frames before `start_frame` and drop the matching output frames. Alternatively, document that bounded reads are exact only at the engine rate, which is the case the plan's recording parts use.

**L3. Test gaps found by mutation.**
- Removing the output term from the memory estimate (`:396`) passes every test. `test_backing_decode_memory_guard` uses MemAvailable = reserve + 1000, which refuses any size.
- There is no test for a non-finite sample, more than 254 channels, a short `fact` chunk, or an accepted non-whitelisted format.

**L4. Very short tagged MP3s are refused.**
- **Where:** `le_decode_open`. A 0.2 s LAME MP3 with ID3v2.3 and ID3v1 tags fails `ma_decoder_init_file`. The same file untagged opens, and so does the tagged 0.5 s version.
- **Effect:** irrelevant for backing tracks, but the refusal reason would be "damaged".

## Notes

- **The MP3 length shift is recorded, not hidden.** Tagged and untagged LAME files decode to lengths that differ by one MPEG frame (1,152); for example, 1 s decodes to 47,232 untagged and 46,080 tagged, because of how the Info frame is treated. The PR records the encoder delay and padding ("MP3 encoder delay and padding stay in"). It should add that gapless Next across MP3s therefore carries roughly 25-70 ms of silence at each join. The plan says this in section 12, and it should reach the Part 8 hardware note.
- **Rate-conversion speed.** The converter's inner loop is a double-precision 64- to 128-tap dot product per output sample per channel. The dev-machine figure (1.01 s for 5 min at 96 kHz) suggests several seconds on a Pi 5 for 15 minutes. The plan keeps this as a hardware criterion.
- **Half-band stopband.** The 192 kHz path's half-band stage has a −78 dB stopband (`restore_halfband.h`), so content folding through the first halving is attenuated by about 78 dB, not the 100 dB of the sinc stage. That is fine, but D3's "about 100 dB" applies only to the sinc stage.
- **Upstream.** The vendored miniaudio is 0.11.21. H1 (the `&pDecoder->pBackend` uninit), the MS-ADPCM predictor bound and the `fact` underflow are in dr_wav and `ma_decoder` code, not in the PR. The plan's follow-up to update miniaudio (#1235 is FLAC) should list all three and re-run the fuzzer after the update. I did not check which upstream release fixes each one.
- **Fuzz volume.** Every one of my three campaigns stopped on a defect within minutes: first the hang, then the MS-ADPCM bound and signed overflow, then the bad free and the `fact` hangs. So the decoder has not yet been fuzzed clean beyond these. After the whitelist (M1) and the header pre-validation (H1, H2), a fresh multi-hour run is needed before D2a's claim holds.

Verdict: Request changes (H1-H3; M1 and M2 before Part 3 wires the decoder to imports).

## Delta review (e06bb06a2)

Model: Claude Opus (subagent), in-session

### Scope

The branch was rebased onto P1 `6cca20754`. Since `d81d14170`, the decoder changes in:
- `eaa09a351`: whitelist before miniaudio, bounded I/O, non-finite refusal;
- `e06bb06a2`: refuse samples beyond 60 dB over full scale.

`engine_decode.c` grew from 505 to 933 lines. It now has:
- its own RIFF and MP3 header parse, run before miniaudio (the whitelist);
- `ma_decoder_init` through bounded read and seek callbacks, with a work budget;
- `cfg.encodingFormat` pinned to one backend;
- `MA_DR_MP3_ONLY_MP3`;
- the 192 kHz rate cap;
- a rate whitelist reachable from every engine rate;
- planes read straight from the stream;
- a peak estimate that counts every term;
- a bounded read computed on the whole file's grid;
- the `|x| <= 1024` sample check.

`miniaudio.h` carries three new `SEGNO PATCH` markers (the post-init double uninit), and the fuzz driver was rewritten.

### Runs

**Native suite** on `e06bb06a2`, each configuration in its own `TMPDIR`:
- plain, ASan and telemetry-off: ALL PASSED;
- TSAN races: ALL PASSED, no report;
- the in-repo fuzz driver: "32 seeds, 3000 inputs, 0 violations" in every configuration. The ASan job now adds UBSan through `FUZZ_CFLAGS`.

**My earlier reproducers,** release build (`repro/` plus the crash and hang inputs my campaigns kept). Every one returns, none crashes, none hangs:

| Input | Result |
|---|---|
| `ch256_s16.wav`, `ch255`, `ch254` | `UNSUPPORTED` |
| `fact0_fmt1.wav`, `fact1_fmt1.wav` | `INVALID` |
| W64 huge-chunk file | `UNSUPPORTED` |
| The four fuzz crash and hang inputs | `UNSUPPORTED` |
| `msadpcm_oob.wav` | `UNSUPPORTED` |
| `r44101`, `r96001`, `r47999`, `r11127` | `UNSUPPORTED` at the probe |
| The 1 s float WAV holding one NaN | `INVALID` at the probe |
| AIFF, AIFC, A-law, μ-law, IMA and MS ADPCM, u8, f64, RF64, W64, MP2, FLAC, 6-channel WAV | `UNSUPPORTED` |
| The 0.2 s tagged MP3 (old L4) | Now decodes |

Real files still decode: s16, s24 and s32, f32, extensible 24-bit, every MP3 variant (ID3v1 and v2, 1.1 MB PNG cover art, CBR and VBR, 8 kb/s, cut mid-reservoir, joined), and a BWF-style WAV with `JUNK` and `bext` before `fmt ` and `LIST` after `data`.

**Extended fuzzing.** My whole-file mutation driver wraps the PR's `LLVMFuzzerTestOneInput`.
- **Seeds:** 37: every corpus file above, the new fixtures, the old crash inputs and the BWF file.
- **Sanitizers:** ASan plus full UBSan, signed overflow included, aborting on any report, with a 10 s per-input watchdog.
- **Volume:** 4 × 150,000 = 600,000 inputs.
- **Result:** 0 violations, no sanitizer report, no hang. The same driver stopped within minutes on each of the three first-round campaigns.

**Peak memory.** I counted live heap bytes for every allocation in `engine_decode.c` (by interposing `malloc`, `calloc` and `free` in that translation unit). The tracked peaks equal the new floor estimate to 0.1 MB:

| Decode (60 s, stereo float) | Estimate | Tracked peak |
|---|---|---|
| 192 kHz → 48 kHz | 115.2 MB | 115.2 MB |
| 192 kHz → 44.1 kHz | 115.2 MB | 115.2 MB |
| 192 kHz → 96 kHz | 138.2 MB | 138.2 MB |
| 44.1 kHz → 96 kHz | 67.2 MB | 67.3 MB |

macOS `peak memory footprint` reads 150 MB for 192 kHz → 44.1 kHz because the allocator keeps freed large blocks dirty. glibc returns blocks of this size (above the mmap threshold) at `free`.

**Bounded read against the whole-file decode.**
- **Method:** I decoded a whole file, then compared 40 bounded reads at fixed and random starts and lengths (`max_frames` 0 and 1-20,000) against the matching slice of the whole decode, bit for bit.
- **Pairs:** 192 → 48 and 44.1, 176.4 → 48, 96 → 48 and 44.1, 88.2 → 48, 44.1 → 48, 48 → 44.1, 44.1 → 96, 22.05 → 48, 8 → 48, 48 → 48, plus three MP3 cases.
- **Result:** every read is **bit-identical** and every `truncated` flag is right. The one exception is a start at the last source frame (L5).

**Mutations,** one at a time, backing-only ASan driver:
- **Caught:**
  - the `fact` size check (the bounded seek turns the old hang into a wrong code, which the refusal test catches);
  - the `|x| <= 1024` check, and NaN-only checking;
  - each peak-estimate term;
  - the bounded-read margin;
  - the ID3v1 strip;
  - the bit-depth whitelist;
  - the work budget.
- **Survived, because a later layer refuses the same inputs:**
  - the seek bound;
  - the chunk-inside-the-file check;
  - the whitelist's own rate check (the post-open check refuses it too).

### Verified correct (traced)

**The whitelist runs first, so nothing outside it reaches miniaudio.**
- `le_wav_check` walks every chunk up to `data`, refusing a chunk larger than the rest of the file and capping the walk at 1024 chunks.
- It accepts one `fmt ` chunk only: tag 1 at 16/24/32 bits, or tag 3 at 32 bits, plain or EXTENSIBLE with the KS GUID tail; 1-2 channels; a matching block align; a rate that converts to every engine rate.
- It refuses a `fact` chunk under 4 bytes, and a `data` chunk shorter than one frame.
- Anything not `RIFF` must be MPEG Layer III after at most four ID3v2 tags: a synced Layer III header followed by a consistent second one within 64 KiB. Free format, Layer I/II and ADTS (layer 0) are refused.
- miniaudio is then opened through `ma_decoder_init` on exactly that backend (`encodingFormat`), so there is no trial-and-error fallback across decoders.

**Bounded I/O.**
- `le_io_seek` refuses any position outside the stream. This removes the "fseek past EOF succeeds" loop at its root.
- Every read and seek is charged against `8 × size + 64 MiB` of work, so even a decoder bug cannot loop for ever.
- The open refuses anything that is not a regular file (`S_ISREG`), so a FIFO or device cannot block a read.

**The miniaudio patch.**
- The claim that `ma_decoder__postinit` already uninitialises on failure is true (`miniaudio.h:64248-64258`).
- Removing the second `onUninit(&pDecoder->pBackend)` at the three backend-file and memory paths is therefore correct, with no leak.
- The app no longer reaches those paths anyway (it uses `ma_decoder_init`), and the README records the cluster for the #1235 upgrade.

**Sample checks.** `le_decode_read` refuses on `!(|x| <= 1024)`, which catches NaN, ±Inf and absurd magnitudes, in both the probe and the decode. Legitimate float overs (+6 dBFS) pass.

**Rate refusals.**
- `le_decode_rate_pair_ok` mirrors the decode's own halving and phase limits exactly.
- `le_decode_rate_ok` requires every engine rate. So the probe and the decode now agree, and D2's guarantee holds for 44.1, 48, 88.2 and 96 kHz engines.

**The memory floor and the bounded-read grid.**
- **Floor estimate:** `size·ch + max(2·out, size/2)` is exact for both paths. Planes are read straight from 4096-frame chunks, so the interleaved source never sits beside them.
- **The grid:**
  - The first output is computed as `ceil(start·out/in)` on the whole-file grid.
  - `from` is aligned to `2^k`, so the half-band stages line up.
  - The margin is `256 << k`, which covers the converter's 64-tap reach and the half-band stages' 29 taps per stage.
  - A read cut short keeps only what it fully reaches.

### Findings

#### Low

**L5. A bounded read whose start is the last source frame of a downsampled file is refused instead of returning nothing.**
- **Where:** `engine_decode.c:895` (`count <= 0`). On a reduction, `ceil(start·out/in)` can equal the whole-file grid length, so no output frame starts at or after `start`.
- **Reproduced:** 192 kHz → 48 kHz at start 575,999; 96 kHz → 48 kHz at 287,999; MP3 48 kHz → 44.1 kHz at 12,671. Each returns `INVALID`.
- **Impact:** a preview or a recording-part read starting exactly there is told "damaged".
- **Fix:** return `LE_OK` with an empty buffer and `truncated = 0`, or document that `start_frame` must leave at least one output frame and return a distinct code.

**L6. Three defence-in-depth layers are untested on their own.**
- The seek bound, the chunk-inside-the-file check and the whitelist's rate check each survive deletion, because another layer refuses the same inputs.
- **Fix:** if the layering is meant to hold, give each layer a fixture that only it refuses. For example, open a crafted W64 or seek-heavy file through the internal callbacks with the whitelist bypassed in a test build.

#### Note: formats now refused

8-bit and 64-bit-float WAV, previously accepted, are now `UNSUPPORTED`. D2 says so. Library Part 8's listing must show these as unsupported rather than damaged; the `UNSUPPORTED`/`INVALID` split makes that possible.

### Verdict

Approve. H1-H3, M1, M2 and L1-L4 are resolved and verified with the original reproducers. 600,000 extra fuzz inputs are clean, and the memory floor and bounded-read equality are confirmed exactly.
