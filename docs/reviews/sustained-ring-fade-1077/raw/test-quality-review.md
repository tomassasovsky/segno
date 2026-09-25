# Test quality review — sustained ring fade

## Scope and evidence

Reviewed the firmware 1.11 ring change against the supplied pre-change copies of
`firmware/console_board/console_board.ino` and
`firmware/test/test_console_pill.cpp` under
the saved firmware 1.10 baseline. Also read the console README, verification
record, native test runner and pixel-driver stub. Existing app, Song-queue,
protocol and pill work is outside this review's change scope.

Reviewed source SHA-256:

- Sketch: `765594ca92e2ff0484517a381153a86f8d207f5ffe045bfc0d90588acf40edd8`
- Console pixel test: `b5e1e2b825fef6cf64bfa57a1b962de999e039e33c95e6f17ea905167c3c6731`
- README: `60349ad224b7ea170b1d78ec66b86f83c4bfda5375ae487f7a193fb4a1664e8e`

## Coverage summary

- Independent test run: **Pass** — `bash firmware/test/run_tests.sh` exits 0.
- All four suites passed, including the 49 protocol fixtures, CTRL behavior,
  console pixels and the separate pill bench firmware.
- Coverage percentage: not measured. The firmware runner has no coverage mode
  or firmware coverage threshold; Flutter coverage is unrelated to this change.
- Changed production source files with corresponding behavior tests: **1/1**.
- Missing test files: none.

## Test quality

`firmware/test/test_console_pill.cpp`: **Pass**.

The suite compiles and invokes the actual production sketch, with deterministic
time, UART and pixel-output boundaries. Its new assertions inspect transmitted
pixel values, rather than merely matching the profile array or its source text.

The new coverage establishes:

- A two-pixel 192-duty head, monotonic trailing fade, at least half head duty for
  the first 17 positions, 30 illuminated positions, and a dark final quarter.
- Correct direction and fractional frame interpolation both within the ring
  and across the last-to-first pixel boundary. The interpolation oracle uses
  observed complete neighboring output frames, independently of the production
  circular-index calculation.
- Preservation of the weaker yellow channel through the tail, detecting a
  second gamma pass that would shorten the visible fade or alter the hue.
- No limiter-induced dimming of normal white comet frames across every
  quarter-pixel phase; the old total-channel ceiling remains respected.
- Limiting deliberately excessive white and mixed-color frames, with stable
  repeated refresh and bounded total transmitted output.
- Equivalence of the ambient conversion to the previous fixed-brightness
  driver across channel levels, followed by a complete breathing cycle through
  the real firmware loop.
- The 1100 ms revolution, subpixel movement, frozen position and color after
  stopping, volume-arc duration and restoration, gain extremes, goodbye,
  expired link and rejection of a corrupt replacement frame.

Assertions containing exact duty/count/timing values represent the accepted
visual behavior and retained current ceiling, and are explained beside the
checks. They do not copy the full lookup table. Helpers keep repeated checks
small and consistent with the existing native assertion-based test style.

## Anti-patterns found

None in the scoped change. No assertion-free tests, mocked production renderer,
tautological source checks or unrelated test expansion were found.

## Practical limits

The host driver intentionally uses a nonlinear gamma approximation and simulates
Arduino I/O. This suffices to expose extra gamma application and verify pure
channel duties; it does not prove physical color calibration, diffuser appearance,
actual current, electrical signal integrity or device responsiveness. The
verification record correctly reserves the visual result for the device trial
and labels current figures as estimates. No device was accessed or changed by
this reviewer.

## Verdict

**All tests pass the quality bar.** No actionable Critical, Important or
Suggestion findings for the reviewed ring change.
