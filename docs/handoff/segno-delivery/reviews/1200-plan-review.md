Model: Claude Opus (subagent), in-session

# Review of PR #1207: docs(plan): backing player, prepared list, foot Backing and Mixer strip

## Scope

- Plan: `origin/claude/backing-player-plan-1200` at `94892da06`, `docs/plan/2026-10-06-feat-backing-player-plan.md` (issue #1200, 9 parts). The diff is that file plus `.github/cspell.json`.
- Checked against:
  - the code on the plan's base and on trunk `56033baf0`;
  - the Library plan and code (`origin/claude/library-1178-p3`);
  - the #1198 plan (`origin/claude/recording-recovery-plan-1198`);
  - the USB plan (`origin/claude/usb-storage-1177-p4`);
  - AB, AGENTS.md and the owner rules.
- Pen: `segno-ui.pen`, `01 CURRENT UX`, read through the pencil MCP and not saved:
  - bx7vK, B5q2Q, OIOV1, jsmae, EM37x, Vbg8o, xI2WT, wotfZ, g7wH7, Z3tJMK, bZDIR, IwBG4 and btTbs;
  - section 36 (b28GI1, w9WB8, sra8u, LaqVi), for the recall rows.

## Runs

- `git merge-tree` against trunk `56033baf0`: **conflict** in `.github/cspell.json`. GitHub reports PR #1207 `CONFLICTING`, and only GitGuardian ran; no CI ran on the PR.
- `npx cspell --config .github/cspell.json` on the plan: 0 issues.
- Documentation only, so no suite exercises it. I traced the native and Dart paths it cites, as listed below.

## Verified correct (traced)

- **Decoders.**
  - `MA_NO_DECODING` is at `miniaudio_impl.c:10`.
  - The vendored miniaudio is 0.11.21 (`miniaudio.h:3724-3726`) and carries dr_wav, dr_flac and dr_mp3, so dropping that one define enables all three.
- **Resampler (D3).**
  - `InterpolatorKaiserSincN(pass, stop)` exists (`third_party/signalsmith-stretch/dsp/delay.h:474-560`).
  - Its kernel is `sin(π(p+s)x)/(π(p+s)x)`, so its DC gain is 1/(p+s), and "scaled by pass + stop" restores unity, as the plan says.
  - The table holds 128 sub-steps with linear interpolation between them. That puts the interpolation error for a 1 kHz tone far under −90 dB, so the plan's spur bound is reachable.
  - `le_halfband_decimate` exists (`restore_halfband.h:37`).
- **Pan law.** `le_pan_gains(0.5)` gives `gl = cos(π/4) = 0.70710677`, `gr = 1` (`engine_private.h:393-411`), as `test_backing_level_pan_route` expects.
- **Mix point (D5).**
  - The click sums before the output-bus loop (`engine_process.c:6767-6775`). Each bus runs its chain, the capture tap, then level, Mono, balance and mute (`:4175-4215`), and all of that comes before master gain and the limiter.
  - A backing summed at the click's point is therefore processed by output FX, level and mute (AB 3.1), seen by meters and the limiter, and captured on the captured bus (AB 6.6).
  - It is never perf-logged, so `perf_render`'s stems and reconstructed master exclude it (AB 3.11).
  - This agrees with the Library's audition, which sums after the bus loop so captures never contain it.
- **Free-after-ack.** The free-after-ack and `a_running` free-at-once rule (`engine_private.h:1452`) mirrors the Library plan's reviewed E4 protocol.
- **Shared slot helper.** One `engine_voice.h` slot helper for the backing and audition voices is the right rule-4 call.
- **Buffer size.** 900 s × 96000 × 2 × 4 B = 691.2 MB; the plan's number is right.
- **Pen.** Every cited id resolves, and the copy matches:
  - 18/05: `WAV · 3:42`, `Level`/`Unity`, `Pan`/`Center`.
  - 18/08: `Hold: −10 seconds`, `Page 1 / 3`, `Hold: At end`, `Prepared audio · 9 recordings`.
  - 18/09: `Selected · press Play`, `Play selected`.
  - 18/11: `Nothing prepared yet`, `0 recordings`, `Add audio in Library before performing.`, `Page 1 / 1`.
  - 21/04: `Backing track | Click`, `Send to`.
  - 28: "Loops and backing audio will stop."
- **Mixer `Backing & click` tile.**
  - In `IwBG4` (x 1392, 469 × 60), `stage-aux` "Backing & click" sits first and "Reset mixer levels and pan" second. That matches Part 6's "beside Reset mixer, Mixer view only".
  - The bZDIR dialog holds `Backing · Prepared audio`, `Click · First recording` (the Hear click mode), and `Volume`, `Pan` and `Done` for each. That matches Part 6 and the declared subtitle deviation.

## Findings

### High

**H1. The automatic Next swap races the control thread's stage, load and clear: a use-after-free or double free reachable from the audio thread.**
- **Where:** §4.1 Mechanics ("An automatic Next swap is done by the callback: it moves the finished buffer into the callback-owned `ended` slot"), and `le_engine_backing_stage_next`, `le_engine_backing_load` and `le_engine_backing_clear`.
- **Scenario 1 (stage_next):**
  - The callback acquires `a_backing_next = B1` at block start and promotes it to current at the end-of-file frame.
  - In the same block, Dart calls `stage_next(B2)`.
  - If `stage_next` swaps `a_backing_next` and parks the old value for freeing after the ack, it parks B1, which is now the playing buffer.
  - The next block's ack satisfies the retire generation, and the control thread frees B1 while the callback reads it.
- **Scenario 2 (load):** `load(C)` racing the same promotion can park the old current while the callback also moves it into `ended`. The same pointer is then freed twice.
- **Scenario 3 (`ended` occupied):** two advances before the next `le_engine_backing_state` collect leave the callback nowhere to put the finished buffer. Short files can do this, and the repository polls at 20 Hz only while playing.
- **Coverage:** none of `test_backing_replace_while_playing`, `test_backing_end_modes` or the ASAN runs race these against each other.
- **Fix:**
  - Specify the handoff. Every change to the current buffer happens on the audio thread: `load` and `clear` post the new pointer through a slot the callback consumes, and the callback moves the old one to `retired`.
  - The callback takes the staged buffer with `atomic_compare_exchange(&a_backing_next, B, NULL)`.
  - `stage_next` and `clear` use `atomic_exchange` and park only what they removed.
  - When `ended` or `retired` is occupied, the callback refuses the advance: it stops with `EV_NEXT_MISSING` and never overwrites.
  - The ack is stored every block, playing or not; otherwise a stopped voice never acks and every replace returns `NOT_READY`.
  - Add a stress test that races `stage_next`/`load` against a buffer ending inside the block. Run it in CI's `native-tests-tsan` job (it already exists) as well as ASAN.

### Medium

**M1. Memory: "at most two full buffers" does not hold for the plan's own flows, and nothing bounds the appliance total.**
- **Where:** D1, D2, Part 2's RSS criterion, Part 4's import, Part 8's Preview.
- **Flows that exceed two buffers:**
  - (a) Part 4 imports by "decode-validate at the engine rate", so importing while a file is loaded and a Next is staged holds three full buffers.
  - (b) Part 8's Preview feeds the audition voice with "decodeBackingFile truncated to the audition cap", so it decodes the whole file first, up to 691 MB, to play 120 s.
  - (c) One decode reads "into a growable buffer", then resamples and interleaves into new buffers. Part 2's own criterion allows "2 x 691 MB RSS growth" for one decode, so loaded (691 MB) plus a decode (up to 1,382 MB) is 2.07 GB at 96 kHz.
  - (d) A configure re-decodes both the loaded and the staged file.
- **Appliance context:**
  - The appliance image configures no swap (nothing in `deploy/yocto`), and the app does not mlock.
  - The same process also holds loop layers (8 tracks × 8 lanes with undo history, allocated on demand), #1198's capture rings (up to 264 MiB at 96 kHz), the audition buffer (92 MB at 96 kHz), and instruments (#1197 states no budget).
  - If the OOM killer ends the app mid-performance, all of that sound stops (rule 2).
- **Fix:**
  - Preallocate from the reported length. MP3 has no reliable length, so decode it in two passes, or grow in large chunks and keep the 2× realloc copy out of the peak.
  - Resample straight into the final interleaved buffer.
  - Validate at import by streaming (duration and peaks, with no retained PCM).
  - Give the decoder a `max_frames` argument for Preview.
  - Check `MemAvailable` before each decode and refuse with a reason.
  - Add a memory-budget table for the appliance covering loops, rings, backing, audition and instruments.
  - Add a HARDWARE criterion: peak RSS while A plays, B is staged and C is imported, all at 96 kHz, with loops recorded.

**M2. Decode safety for untrusted files.**
- **Where:** D2, §4.1 "Decode", Part 2 refusals, Part 9 "header probe".
- **Gaps:**
  - The source sample rate is not range-checked.
  - The cap is "900 s at the source rate", so a header claiming a huge rate turns 900 s into an unbounded frame count (`int32_t` frames). A rate of 0, or one that overflows `int32_t`, breaks `t · in_rate / out_rate`.
  - The decoders run in the audio engine's process. A fault in dr_wav, dr_mp3 or dr_flac on a crafted file ends playback.
  - Part 9 parses the header of every audio file on a drive just to list durations.
  - The plan has no fuzz criterion, and miniaudio is pinned at 0.11.21.
- **Fix:**
  - Refuse rates outside 8-384 kHz and channel counts outside 1-2.
  - Cap in frames and in bytes.
  - Treat a mid-stream decoder error as a refusal.
  - Add an ASan libFuzzer target over `le_backing_decode_file`, with a seed corpus of truncated or oversized headers, ID3 garbage and FLAC with bogus total-sample counts, run for a fixed time in the ASan job.
  - Update miniaudio to the current 0.11.x and record the version.

**M3. Consolidate decoding and identity across the three plans (rule 4).**
- **(a) Decoders.** After this plan there are three:
  - the Library's Part 6b, which decodes WAV in Dart with `maxFrames` and refuses other rates;
  - #1198's Part 5 bounded 24-bit reader;
  - this plan's native miniaudio decoder.

  §8 says 6b "can adopt it". Make that the decision: one native bounded decoder, `(path, rate, offset, max_frames)`, used by audition, backing and recording parts. dr_wav reads #1198's 24-bit parts.
- **(b) Identity.**
  - #1198 D6 requires one SHA-256 implementation (C, `le_digest_*`) and a full `sha256:<64 hex>` identity.
  - This plan uses Dart `crypto` and a 16-hex (64-bit) id over the whole file, and never checks it when a file is loaded.
  - Fix: use #1198's digest functions, store the full digest in `info.json`, and verify it at recall. The directory name can stay short.

**M4. Pen coverage: deviations the plan does not declare.**
- **What the pen draws:**
  - 18/07 `EM37x` draws `Save audio` (top right, `audio:save`), `Export to USB` (`audio:export-usb`) and `Use in loop` (`audio:load-track`).
  - 18/01 `bx7vK` draws `Export to USB` and `Use in loop`.
- **What the plan does:** Part 8 leaves them out ("not drawn here"). That is right, since it adds no dead controls. But §2 claims no deviations beyond the Mixer subtitle.
- **Fix:**
  - List these as deviations and write them back into the pen (repo rule: a shipped deviation updates the pen).
  - Say how the 18/05 Backing track page is reached: the pen gives it no entry, and the sub-nav has no "Backing track".

**M5. Backing recovery rows fall between this plan and #1198.**
- **Pen:** section 36 (b28GI1 `2 audio files to find`, w9WB8, sra8u, LaqVi) draws `Evening lights.wav · Prepared audio · Backing track · Find audio` in Open recovery.
- **The gap:** D9 defers repair to "E7-16" (#1198), and #1198's D7 and Part 15 defer backing rows "with E7-8" (this plan). Neither builds the row.
- **Fix:** assign it, preferably to #1198 Part 14/15 matching this plan's asset ids, and record it in both plans.

### Low

- **L1. Merge conflict.** PR #1207 conflicts with trunk in `.github/cspell.json`, so no CI has run on it. Rebase, resolve as a union, and check the JSON is valid.
- **L2. Reopen notice.** D10 gives the notice only after a configure. A retained reopen during a performance also stops and rewinds the backing, and should say so (rule 3).
- **L3. Rate change during a decode.** A decode that finishes after a configure changed the rate gets `LE_ERR_INVALID` from `load`. Specify re-decoding at the new rate, and freeing the stale buffer.
- **L4. Play selected latency.** `Play selected` decodes on demand; a 15-minute MP3 at 96 kHz takes seconds. 18/09 shows no loading state, so the press appears to do nothing. Show a status (for example "Loading…" in the header) and add a HARDWARE check for xruns while a 96 kHz decode runs with loops playing.
- **L5. Schema number.** Part 5 and #1198's Parts 6 and 16 each claim "14 if Peel 12 and Reverse 13". Coordinate through the #1196 chain.
- **L6. Store location.** `Backing tracks/` sits under `exportsRoot`, beside capture bundles and #1198's `.takes/`. Boot salvage skips it (it has no `performance.json`), but the Library Part 7 `listCaptures` must skip it as well. A sibling root is cleaner.
- **L7. Native test oracle.** `test_backing_capture_and_stems` asserts `master.pcm` equals track plus backing. #1198 Part 2 replaces `master.pcm` with 24-bit parts, so whichever lands second must re-base the oracle. Exact equality no longer holds after quantization.
- **L8. DAW export.** The live master contains the routed backing, but the stems and `project.als` do not. Because the backing is never logged, `daw_export` cannot place the asset. That follows AB 3.11, but a performance exported to a DAW silently loses its backing. Either log backing transport events (item, start, seek, stop frames) as metadata outside the render, so the package can include the asset on its own track, or say so on the export (rule 3).

## Notes

- **Dependency order** is sound: P1 → P2 → P3 → P4 → P5 → {P6, P7, P8}, then P8 → P9. P8 waits for the Library's Part 7 and P9 for #1177's Part 4.
- **Lease registry.** The read hold (D8) reuses #1177's lease registry rather than adding a busy flag. That is the right rule-4 call.
- **E7-6 ownership.** D9's split (the session owns the prepared order, the loaded id, mix and End; the appliance owns the files) matches AB 6.9 and should be cited from #1206's audit.

Verdict: Request changes (H1 and M1-M5 need plan edits; L1 blocks CI).

## Delta review (c05ba9f45)

Model: Claude Opus (subagent), in-session

### Scope

- **The plan:** `origin/claude/backing-player-plan-1200` at `c05ba9f45`. It was rebased onto `097e1ef68`, where the plan diff is the plan file plus `.github/cspell.json`.
- **Checked against:**
  - section 14's review map, finding by finding;
  - the code built for Parts 1 and 2 (PR #1222 at `75b7e84c7`, PR #1223 at `d81d14170`; reviewed in `backing-p1-in-session/review.md` and `backing-p2-in-session/review.md`);
  - the #1198 plan (`origin/claude/recording-recovery-plan-1198` at `57a5324b8`);
  - the Library plan (trunk and `origin/claude/library-1178-p4` at `7f9f8b264`).
- **Pen:** not re-read. The new deviations 2-4 restate pen facts the first review verified (`EM37x` and `bx7vK` actions, no 18/05 entry, no loading state).

### Runs

- `git merge-tree` of `c05ba9f45`, `75b7e84c7` and `d81d14170` against trunk `097e1ef68`: all clean (L1 resolved).
- No suite exercises a plan document. The Part 1 and Part 2 runs that back its claims are recorded in the two PR reviews.

### Finding by finding

**H1. The auto-advance race: resolved.**
- Section 4.1's protocol is what the code does:
  - loads, stages and clears travel the ring;
  - the advance happens in the callback;
  - returns go through four CAS slots;
  - a guarded advance;
  - releases happen only with the callback stopped.
- I traced every interleaving (P1 review, "Verified correct").
- `test_backing_races.c` passes under TSAN (302 advances, 7,911 handoffs) and under ASan. It is the test that catches a fade-sharing UAF mutation.
- Residue: Part 1's own text was not updated (see D1 below).

**M1. Memory: largely resolved.**
- Resolved: the byte budget is enforced in the registry, import probes without PCM, decodes preallocate from the stated length, the floor check exists, and D11 has its table and hardware criterion.
- Not resolved:
  - D11's "one decode in flight: about 1.0 GB worst case" is wrong for sources above 96 kHz.
  - The floor check underestimates the half-band path's peak by about 2x (measured: 209 MB actual against 115 MB checked for a 60 s, 192 kHz stereo file). See P2 M2.
  - "Its own peak … is checked … before it allocates" (D1) does not hold on that path.

**M2. Untrusted files: not resolved.**
- D2a's statements have exceptions:
  - "every header value is checked before it sizes anything": the channel check runs after `ma_decoder_init_file`;
  - "20,000 inputs under ASan: no finding";
  - "the residual risk, recorded".
- Fuzzing the built decoder with a wider driver found, within minutes:
  - **A process abort** from a 2 KB WAV with 255 or 256 channels: miniaudio's post-init failure path frees `&pDecoder->pBackend`.
  - **Unbounded hangs** from a 252-byte RIFF WAV with a 0- or 1-byte `fact` chunk, and from a W64 file. Both come from a `ma_uint64` underflow fed to `ma_dr_wav__seek_forward`.
  - **An out-of-bounds table read** in MS-ADPCM.
  - **Non-finite float samples**, which pass the probe and permanently poison output-bus FX.
- The in-repo driver could not reach these. It mutates only the first 64 bytes, and its seeds are PCM and float WAV and MP3 only.
- D2 also claims the formats are "WAV (PCM …, float …) and MP3", but the decoder accepts ADPCM, μ-law and A-law, AIFF and AIFC, W64, RF64 and MPEG Layer II, whatever the extension.
- The plan should require:
  - a pre-miniaudio header validation and a format and container whitelist;
  - a non-finite-sample refusal;
  - a fuzz criterion with whole-file mutation, every container seeded, UBSan and a per-input timeout.
- Section 8's miniaudio-update note should list the three upstream defects (the uninit pointer, the MS-ADPCM bound and the `fact` underflow).

**M3. Consolidation: the plans still disagree.**
- (b) Identity: resolved. D7 uses trunk's `le_digest_file`, stores the full `sha256:` digest and verifies it before load.
- (a) Decoders: unresolved.
  - D2 (`:204-212`) and section 8 (`:1019-1022`) say the Library's Part 6b and #1198's part reader "read through `le_backing_decode_file` … the coordinator has told both plans".
  - Both other plans, at heads newer than `c05ba9f45`, say otherwise:
    - #1198 (`57a5324b8`, `:361-366`): "`wav_codec` is the one Dart reader … the Library's Part 6b … and this plan's recovery all use it. #1200's backing player decodes natively … a separate concern … not a second Dart reader."
    - The Library plan's Part 6b (`library-1178-p4`, `:931`): still `wav_codec.decodeFloat32(bytes, {maxFrames})`.
  - So the app will have two decoders (Dart `wav_codec` and native `le_backing_decode_file`), and the three plans describe it three ways (rule 4).
  - Pick one and make all three plans say the same thing. Given P2's H1-H3, the defensible option today is that `wav_codec` reads the app's own PCM and float captures, and `le_backing_decode_file` reads foreign files. State that split rather than claiming one decoder.

**M4. Pen deviations: resolved.** Section 2 lists deviations 2-4, and Part 8 follows them.

**M5. The recovery row: resolved.** D9 assigns it to #1198 Parts 14-15. The #1198 plan (`:536-541`, `:575-577`) records `missingBacking` matched by #1200's digest.

**L1-L8: resolved as mapped.**
- L1: rebased, clean merge.
- L2 and L3: D10. The stale-rate `load` returns `LE_ERR_INVALID` in the code.
- L4: deviation 4 and the D11 hardware row.
- L5: Part 5.
- L6: D7 and Part 4's test.
- L7: section 8.
- L8: `backing_in_master` is implemented and tested. The arm-time reset is untested (P1 L2).

### New findings in the delta

#### Medium

**D1. Parts 1 and 2 still describe the first design, contradicting section 4.1 and section 12.**
- **Part 1:**
  - Its file list names `engine_voice.h` and a "block-end ack" (`:571-575`, `:629`).
  - Its tests say "A is freed only after the ack … a second replace before the ack returns `LE_ERR_NOT_READY`" (`:609-611`).
  - Its success criterion reads "Buffers are freed only on the control thread after the block-end ack" (`:636`).
  - Section 4.1 item 4 says nothing needs an ack.
- **Part 2:**
  - Its file list names `src/core/backing_decode.c`, and `le_stretch.cpp`/`le_stretch.h` for the converter (`:648-652`). The built file is `engine_decode.c`.
  - Its tests still include `test_decode_mp3_flac` decoding the FLAC fixture (`:672`).
- **Why it matters:** these are the texts the Part 3+ builders and reviewers will verify against.
- **Fix:** rewrite both parts' Files, Tests and criteria to the as-built design, or replace them with a pointer to section 12.

#### Low

**D2. D3's "about 100 dB stop band" applies to the sinc stage only.** The 192 kHz path's half-band stage stops at −78 dB.

**D3. D2's guarantee is broken.**
- **The claim:** "a performance never meets a file that has not decoded cleanly once."
- **Why it does not hold:** the probe accepts source rates the converter refuses (44101, 11127, 47999 and 96001 Hz all probe OK and fail to decode). See P2 L1.

### Verdict

Request changes. Reasons:
- M2 is reopened by concrete crash and hang inputs.
- M3(a) is contradicted by the other two plans.
- Part 1's and Part 2's text contradicts the as-built protocol.

H1, M4, M5 and L1-L8 are resolved.

## Delta review (519107563)

Model: Claude Opus (subagent), in-session

### Scope

- **What changed:** four commits on `c05ba9f45` (`00053210e`, `db5013954`, `5430fbaae`, `519107563`), all in the plan file (+427/−188):
  - the Part 3, 4 and 5 build records;
  - the answers to the first delta review and to the #1222 and #1223 reviews;
  - a second table in section 14.
- **Checked against:**
  - the code at P1 `6cca20754`, P2 `e06bb06a2`, P3 `3f42d99d0`, P4 `8f9bcba92` and P5 `d92267d66`, all reviewed in their own files;
  - the #1198 plan (`origin/claude/recording-recovery-plan-1198` at `3223c726e`);
  - the Library plan (`origin/claude/library-1178-p5` at `55ee5a373` and `-p6a` at `22b841ecb`).
- **Pen:** not read.

### Runs

- `git merge-tree` of `519107563` against trunk `890f04936`: clean.
- The code heads it describes need a rebase onto that trunk (P3 L3).

### Finding by finding (first delta)

**D1, stale Part 1/2 text: resolved.** Parts 1 and 2 now describe the ring handoff, the return slots, `engine_decode.c` and the FLAC refusal. The one "block-end ack" left (`:113`) describes the Library audition before this change, which is correct.

**D2, stop band: resolved.** D3 states the half-band stage's −78 dB.

**D3, the D2 promise: resolved, and verified.** The probe refuses any source rate that cannot reach every engine rate: 44101, 96001, 47999 and 11127 Hz all return `UNSUPPORTED` at the probe.

**M1, D11 worst case: resolved, and verified.**
- The table's figures match the code. I measured the decoder's live-heap peak exactly equal to the floor estimate:
  - 115.2 MB for 60 s of 192 kHz stereo at 48 kHz, which is 1.73 GB per 15 minutes, as D11 says;
  - 138.2 MB at 96 kHz, which is 2.07 GB, matching D11's 2.1 GB.
- Sources are capped at 192 kHz.

**M2, untrusted files: resolved.**
- D2a describes what the code does. I verified it in the P2 delta:
  - every earlier crash, hang and out-of-bounds reproducer is now refused;
  - 600,000 more whole-file-mutation inputs under ASan and full UBSan came back clean.

**M3(a), one reader: half resolved.**
- D2 and section 8 now say `le_backing_decode_file` is the app's only sample reader, and `wav_codec` writes and models headers.
- The #1198 plan agrees (`:363-367`, `:947-950`, `:1060`).
- The Library plan does not yet. Its newest heads still give Part 6b `WavCodec.decodeFloat32(bytes, {maxFrames})` for the audition decode (`library-1178-p5` `:976`, `-p6a` `:887`, and `:377`/`:466` "gains a `maxFrames` bound").
- The plan says the coordinator routes the wording there, but until the Library text changes, two readers are planned (rule 4).

### First-review findings and the #1222 and #1223 reviews

- **The #1222 findings (P1) and the #1223 findings (P2):** resolved as mapped. Evidence is in the P1 delta (`6cca20754`) and the P2 delta (`e06bb06a2`).
- **The #1223 H3 row's "proposed output-bus guard" (section 8):** a sensible follow-up. P1 now also refuses non-finite PCM at `le_backing_buffer_from_pcm`.

### New findings in the delta

#### Medium

**D4. The Part 5 build record describes the migration correctly, but the Part 5 text contradicts it.**
- **The contradiction:**
  - Part 5's Files paragraph (`:811-814`) says the step defaults "an empty prepared list, nothing loaded, End Stop, level 1, pan 0, mask 0 and click pan 0".
  - The build record (`:1321-1328`) says the step keeps the live setup.
- **The judgement:** the build record is the right rule under rules 1 and 3 (P5 review, "The migration step"). A builder or reviewer reading Part 5's text would flag the code as wrong.
- **Fix:**
  - Rewrite the Part 5 text to the as-built rule, as was done for Parts 1 and 2.
  - Add this sentence: a converted session is written back, so the setup live at its first open becomes its own.

#### Low

**D5. D10's promise rests on a reload that the shipped owner does not deliver.**
- **The promise:** D10 says the repository "re-decodes the loaded item … stopped at 0" after a configure.
- **What happens:**
  - The reload happens only at the next refresh, which is the next user action while stopped.
  - The player then loses its `loaded` (P5 M1).
- **Fix:** add to D10 that the owner refreshes the repository on the engine's restart, and that the player follows the repository's loaded item.

**D6. D7's dedupe rule leaves no repair path.**
- **The rule:** D7 says "importing identical bytes again reuses the existing copy".
- **What happens:** the built store does so without checking the copy's own bytes. Re-importing, or #1198's "Find audio", therefore cannot repair a damaged managed copy (P4 M1).
- **Fix:** D7 should say the existing copy is reused only when its bytes still match, and replaced otherwise.

### Verdict

Request changes. Reasons:
- D4: Part 5's text contradicts its build.
- M3(a): the Library plan has not changed yet.

The decoder (M2), memory (M1) and the earlier stale-text items are resolved and verified.
