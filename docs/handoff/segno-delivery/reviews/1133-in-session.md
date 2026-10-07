# PR 1133 — Claude review (in-session retry)

Model: claude-opus-5-5 (Opus 5.5), interactive Claude Code session, 2026-10-05.
Replaces nothing: the original headless run in `../1133/` ended with HTTP 429
(weekly limit) and has no verdict. Same immutable packet: base 6bf1ef00 → head
ff73b979, diff SHA ee68acd2…d0f1. Read-only over packet `source/`, `before/`,
`change.diff` and the Fade parent/Part 1 plans. No build, test or project code
executed. The author's review document was not read before this verdict.

## Verdict: no actionable findings

## Traced

- **Admission vs outcome.** `le_fade_admit` (engine_commands.c) reserves a
  receipt slot, pushes, then records `commands_posted`; `le_engine_read_fade_result`
  only reports after `a_commands_published` covers that command (release store
  at the end of `le_engine_process`, after the relaxed result store). Slot is
  freed on push failure or on consumption. Request ids are monotonic per engine
  and never reset by configure, so a pre-configure id reads INVALID.
- **Target resolution.** Toggle flips the callback's current `fade.target`
  (`apply_command_image` LE_CMD_FADE); two toggles queued before a poll resolve
  in FIFO order (native test lines 74-77; repository test 1).
- **Material identity.** Toggle binds the published `a_fade_generation`;
  `le_fade_reset` bumps generation on Clear, undo-to-empty, void-take finalize,
  record start on EMPTY (both branches; overdub does not reset), and on import
  lane 0 / finalize_layers via LE_CMD_RESET_FADE. A Clear or record start queued
  ahead of a toggle refuses it through the generation mismatch.
- **Import room.** `le_import_fade_room` uses the same `tail - head < capacity - 1`
  criterion as `le_ring_push` on the SPSC ring, checked before any material
  mutation, so the trailing RESET push cannot fail on room.
- **Coherent readback.** `le_fade_publish` is a standard odd/even sequence
  around the four stores; `le_fade_read` takes the tuple only on equal even
  revisions, else returns the last coherent cache. The cache is written only
  by the control-thread snapshot path (same convention as the record-timing
  cache).
- **Gain boundary.** Both track-gain sites in `mix_tracks_frame` (no-chain and
  track-bus `fx_apply_chain_with_gain`) multiply `fade_sample`; lane Post
  precedes it, track Post follows it, matching the accepted topology and the
  tails test. `le_engine_process` has no early return between drain and
  publication; the per-frame tick runs before input processing, so stopped
  transport still advances.
- **Perf replay.** LE_PLOG_FADE (16-byte payload, aliases `arg_i`) is logged
  on accepted commands, resets and at PERF_ARM for every track; renderer
  applies it before the frame's tick, and same-frame order is now stable
  through `ordinal`. Live seeds origin from a double, replay from the logged
  float; the drift is ≤1 float ulp and inside the test's 1e-6 bound.
- **Repository.** `_requestFade` drains before admission; expire and engine
  retirement complete with notReady and keep a null key so the native slot is
  later consumed. `_ReceiptObservation.complete` is not idempotent, but every
  path removes or nulls the key before completing, and timers are cancelled,
  so no double completion was found. Updating existing keys during the
  retirement loop is not a structural map modification.
- **RT safety.** No allocation, lock or I/O added to the callback; one double
  division per fading track per frame.

## Notes (not defects)

1. Toggle maps any target other than 0 to 0. A stationary non-binary image
   (e.g. a Session-recalled 0.25) therefore always fades out on the next tap.
   That is a product reading the Part 2/3 plans should state explicitly; Part 1
   behaves consistently with its own comment.
2. A toggle is accepted while a first take is RECORDING if `lanes[0].a_len > 0`.
   Capture is unaffected; whether that track is "available" is a Part 3 choice.
3. A 500 ms notReady is uncertainty, not cancellation (the test says so); a
   later apply is visible only through the snapshot. Part 3 must treat
   notReady as unknown, not as refusal.

## Limits

No execution. FFI struct layout was checked by reading the C header and the
generated binding diff, not by a compiled offset probe. Hardware/listening not
covered.
