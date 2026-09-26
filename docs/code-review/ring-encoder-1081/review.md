<!-- cspell:words SameSky ACZ CCITT detents -->
# Ring encoder direction and transition decoder review

**Scoped clean: no actionable finding in the three-file working change.**
Reviewed September 26, 2026 using the code-review skill. No implementation,
Git state or PR labels were changed by this reviewer.

## Exact target

- Existing PR: #1082, draft and review-pending.
- PR base: `355bf319b776fb8a4fec8e7915e2ebeb87657431`
  (`codex/screen-power-board-1072`).
- Working-tree/PR head: `92af127d9a2d58c4ea9b810b38d06ca3ddc3c73d`
  (`codex/console-v3-runtime-publication`).
- Reviewed delta: the decoder, focused tests and README listed below, compared
  with that head. This is not a review of the entire base-to-head PR.
- The unrelated `packages/looper_repository/analysis_options.yaml` modification
  was excluded and left untouched.

| Reviewed working file | SHA-256 |
| --- | --- |
| `firmware/ring_board/ring_board.ino` | `1618a0e2b65d9ad0f21ee10a36a85572f66e901791f42fa215094a48da20e591` |
| `firmware/test/test_ring_board.cpp` | `fd6128ff310d7667bd7703ab72d6d8561fa64d727fef9fbc39f84e0f3b386e1c` |
| `firmware/ring_board/README.md` | `e4d24d0ec5e887d667016af660223b139ac306953560bd2548a59b3309a728b1` |

## Manufacturer and end-to-end direction

The selected part is Same Sky **ACZ11BR1E-20FD1-20C**. The primary
[ACZ11 datasheet](https://www.sameskydevices.com/product/resource/acz11.pdf),
revision 1.08 dated May 7, 2026, identifies 20C as 20 pulses / 20 detents on
page 1. Page 3's waveform and detent diagram were independently inspected
visually: for clockwise rotation, A closes before B and both contacts are open
at the detent. The exact inspected PDF has SHA-256
`a1d5e9764abdf31c5da469bc044ad1ea916185cd0b6459b692f1e1aa52396996`.
A direct web fetch returned 403; the already downloaded primary PDF was read
locally, including its revision history, rather than treating a search snippet
as waveform evidence.

With common C grounded, pull-ups invert the diagram's contact-closure levels.
A as the high bit and B as the low bit therefore give clockwise
`11 → 01 → 00 → 10 → 11`. The corresponding reverse sequence gives −1.
The hardware source connects encoder A/B to XIAO D1/D2; the selected core
maps these to GP27/28, agreeing with the production sketch.

The complete direction path was traced: `g_encDetents` → ring `sendInput()`
cumulative 32-bit snapshot → `ring_link::InputTracker::accept()` signed modular
difference → console `pollRing()` signed int8 chunks → pedal-link encoder
packet → Dart `toSigned(8)` → `PedalRepository`'s unchanged `EncoderDelta` →
`ControlCubit.encoderTurned()`. The consumer adds `delta / 64` to master gain
and clamps to 0–1. Thus a clockwise click increases gain unless already at its
upper limit. No later sign inversion was found.

## Decoder, failure paths and ISR review

The old last-intermediate-state marker assigned the opposite sign to this
selected part and could credit an incomplete excursion. The replacement
accumulates signed quarter-steps, cancels each observed reverse transition,
resets on a two-bit diagonal and emits only a full ±4 cycle upon reaching the
open detent. A partial turn followed by reversal yields zero. A skipped phase
is discarded conservatively, and the next complete cycle recovers. Booting
between detents discards that first incomplete movement; subsequent full
clicks work normally. Repeated observations from loop and IRQ are idempotent.

The state graph between detents is a line, so valid backtracking cannot grow
the signed accumulator without bound. At most four quarter-steps accumulate
before a detent reset; no signed-byte overflow path was found. The cumulative
counter deliberately uses unsigned arithmetic; increment/decrement wrap is
preserved by the unchanged snapshot receiver.

`encoderSample()` performs two bounded GPIO reads, table lookup and integer
updates. Its static table has constant initialization. There is no allocation,
blocking I/O, locking, waiting or packet transmission inside the ISR. The
installed Arduino-Pico 6.0.0 GPIO and interrupt implementation was inspected:
`digitalRead()` is a GPIO level read; A/B callbacks share the GPIO IRQ dispatcher.
The existing main-loop sample and cumulative-counter snapshot remain protected
by matching `noInterrupts()` / `interrupts()` calls; the core restores saved
interrupt state. No second-core writer exists in this sketch. The host stubs
cannot prove interrupt timing, so this conclusion also uses the actual core
implementation and call graph, not host test success alone.

## Executed verification

- Independently ran `bash firmware/test/run_tests.sh`: all eight suites pass,
  including all 58 pedal-link fixtures, ring framing/recovery, the production
  ring sketch and console forwarding behavior.
- Independently compiled and ran a temporary harness including the production
  ring sketch under AddressSanitizer and UndefinedBehaviorSanitizer. It exercised
  **530 scenarios**: both directions with independently zero through three
  bounces on each edge, repeated observations, reversal at each intermediate
  phase, each single missed intermediate phase followed by recovery, and each
  between-detent startup phase. All passed without sanitizer diagnostics.
- The same harness drove production ring packet encoding/parsing and console
  `InputTracker` across unsigned wrap, verifying +1 clockwise and −1 reverse
  deltas from actual snapshots.
- Inspected the coordinating agent's real XIAO RP2350 build log: successful
  compile, 64,072 bytes program storage and 10,812 bytes global RAM. This was
  observed shared build evidence, not a separately rerun target build.
- `git diff --check` passes for all three reviewed files. Their hashes above
  were captured after the checks.

The focused tests cover the changed direction and full-cycle acceptance rather
than only checking a table literal. Unchanged parser tests also exercise dropped
and duplicate snapshots, reconnection/reboot baselines, impossible motion and
counter/time wrap. All changed hunks and enclosing functions were read; removed
behavior, caller/callee contracts, boundedness, simplicity and ISR safety were
considered. No missing independent reviewer was required for this small scope.

## Proof limits

This review approves only the narrow uncommitted decoder correction at the
recorded hashes. It does **not** mark all of PR #1082 clean or ready to merge.
The primary waveform and host/core inspection establish the selected direction
and software behavior, not assembled-board bounce timing, GPIO capture under
arbitrary interrupt load, UART noise immunity or final mechanical mating. The
existing hardware qualification limits remain; this review introduces no new
pre-PCB prototype or owner-measurement campaign.
