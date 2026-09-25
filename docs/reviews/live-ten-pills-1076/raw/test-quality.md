<!-- cspell:words smoothstep -->
# Test Quality Review

Reviewed firmware 1.8 against the previously deployed 1.7 behavior and the
owner-confirmed ten-pill harness. Review scope is the normal controller's
80-pixel renderer, current budget, protocol integration and host tests.

## Coverage Summary

- Test run: pass. `bash firmware/test/run_tests.sh` completed all four suites:
  45 protocol fixtures, console CTRL, console pills and standalone pill test.
- Coverage percentage: not configured by this firmware test runner; no
  numerical coverage claim is made.
- Changed production behavior is covered by `firmware/test/test_console_pill.cpp`.
  The existing protocol and CTRL suites continue to exercise their real code.
- No missing test files were identified for this change.

## Controller Test Quality

The tests compile the production sketch and codec. Encoded protocol-5 STATE
frames enter its simulated UART and are consumed by the real loop and parser.
Assertions inspect frames submitted to the LED driver, rather than a duplicate
renderer. The nonlinear gamma fake makes accidental extra dimming observable.

The suite verifies:

- All 80 pixels start dark; original REC/PLAY breathing preserves its peak of
  191, smoothstep shape, phase across host updates and eight-pixel centre curve.
- Recording, playback, overdubbing, ready and loaded-but-inactive behavior
  preserve the established REC/PLAY semantics below the current limit.
- All ten physical groups use their specified functions. Each track in both
  banks is exercised separately while the inactive bank has contrasting data.
- MODE, CLEAR and BANK states reach the correct pills. STOP and UNDO provide
  press feedback without inventing an unavailable transport/undo state.
- Real physical input changes produce debounced protocol BUTTON press and
  release events; REC/PLAY continues to await the application state.
- Asymmetric pixel tags distinguish reversed front-row addressing from the
  forward CLEAR/BANK row, which a symmetric diffuser curve cannot prove.
- Crowded valid states stay within the 6000 RGB-channel-sum budget, preserve
  equal-color scaling and mixed-color symmetry, remain stable on repeated
  renders and recover full calibrated brightness after the load decreases.
- Goodbye and host expiry clear every pixel even with buttons held. Corrupt
  input cannot restore expired output, and valid reconnection restores it.

The NeoPixelBus fake models the edit buffer, dirty flag and submitted frame;
it does not claim to emulate PIO timing or hardware current.

## Independent Mutation Checks

Four isolated changes to temporary source copies were all rejected by the
existing output assertions:

- Disabling the current-budget branch.
- Removing front-row pixel reversal.
- Ignoring the active-bank offset.
- Applying an unconditional extra brightness reduction.

No production or test source was changed by this review.

## State Management and UI

No Dart state management or UI behavior changed in this review scope. The
existing plain C/C++ host-test conventions are appropriate for this firmware.

## Anti-Patterns Found

None. Fixed expected pixel levels express calibrated output requirements;
the tests do not recreate the rendering algorithm as their oracle.

## Recommendations

No required test changes. Actual current, physical LED output and DMA/UART
timing remain device observations and are not inferred from host assertions.

## Reviewed Source Identity

- Console sketch SHA-256:
  `a09c54e38bf3a1c965c0f3d47d293d443ce74c932fdbc9f72b15d03127885485`
- Console pill test SHA-256:
  `e00e2fa58e2b490ca35a21acaae584618f645acbf62a940feaeb2905277f8436`
- NeoPixelBus test fake SHA-256:
  `35e850e83db98cdfad53345eb87a45ac98aabdf8c46690b38f176ffe2231beef`

## Verdict

All tests pass the quality bar for the reviewed change. No Critical,
Important or Suggestion findings.

## Firmware 1.9 BANK Brightness Follow-up

Focused re-review covers the owner-requested BANK blue increase from 80 to
255, version 1.9 and the corresponding expected-output change. BANK B now
uses the same eight-pixel blue curve as MODE in FX, including an explicit
equality assertion. BANK A remains dark. This removes the previous intentional
dim BANK palette without adding another brightness stage.

The unchanged 6000 channel-sum limiter still covers every pill. The crowded
test includes BANK B with its increased blue output and verifies the total
remains at most 6000, repeated frames do not progressively dim, and uncrowded
frames recover their calibrated peak. All four firmware suites passed again,
including the 45 protocol fixtures. No new findings.

Follow-up source identity:

- Console sketch SHA-256:
  `c6ca66016b1e32922fd1b8df98a1554ad1ce593e8c28ddcca7f90881186f31ba`
- Console pill test SHA-256:
  `41c067e4f29e657bcfd751427485e10e88506d6f220a229b8cf4efbd722f8a28`
- NeoPixelBus test fake remains unchanged from the initial review.
