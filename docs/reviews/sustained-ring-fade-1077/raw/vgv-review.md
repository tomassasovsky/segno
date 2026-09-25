## VGV Code Review

### Summary

No actionable findings in the sustained ring firmware delta. The implementation matches the approved sustained-fade preview while preserving old-board pins, protocol 7, indicator behavior, ambient ring output, and the previous aggregate ring-current ceiling. This is a bounded C++/Arduino firmware review, not a review of the existing uncommitted Song queue or pill work. Firmware tests and physical acceptance are separate gates; neither a visual preview nor this static review establishes the appearance through the real diffuser.

Reviewed `firmware/console_board/console_board.ino` against the saved firmware 1.10 sketch. Reviewed firmware SHA-256: `765594ca92e2ff0484517a381153a86f8d207f5ffe045bfc0d90588acf40edd8`.

### Critical — Must Fix Before Merge

None.

### Important — Should Fix

None.

### Suggestions — Nice to Have

None.

### Evidence

- Stack detected from repository instructions, manifest, lint configuration, firmware source, and test runner: Flutter/Bloc application with a C++/Arduino Pico 2 thin-client firmware. This delta changes only that firmware; Flutter architecture and analyzer gates are not relevant to this bounded change.
- Firmware version advances from 1.10 to 1.11; `PEDAL_LINK_PROTOCOL_VERSION` remains 7. GP12 ring, GP18 indicators, GP13/14/15 encoder, and 40-pixel GRB ordering remain unchanged.
- The 30 nonzero `COMET_DUTY` values exactly match the approved `sustained-ring-comet.html` profile. Ten trailing positions are dark. Circular interpolation uses the same neighboring indices and rounding as the preview, including the 39-to-0 boundary. The cadence changes to the approved 1100 ms.
- The profile describes physical PWM duty, so gamma is applied to hue once rather than to the profile again. This preserves the sustained tail instead of shortening it through a second nonlinear brightness conversion. No gamma transformation occurs during refresh.
- Inspected the installed Adafruit NeoPixel implementation. `setBrightness(255)` uses unscaled pixel storage and `getPixelColor()` returns raw channels. `ambientRingColor()` exactly replicates the previous brightness-96 transfer, channel times 97 shifted right by 8. Startup, volume arc, and standby breathe use it; their output scale is preserved.
- All production ring transfers now go through `showRing()`. The sum is bounded by 11520 channels. Multiplications fit uint32; floor division guarantees the limited sum is no greater than the ceiling. Repeated cached transfers cannot dim further after the first reduction, since the resulting sum is already within budget.
- Independently swept 40,000 subpixel phases. The pure-channel sum ranged from 2999 to 3019. Even a hypothetical white comet reaches at most 9057 channel units, below 11520; normal comet frames are not reduced by the limiter.
- Active movement continues to repaint fractional phases. Stop preserves the saved comet color and phase. Volume overlay restoration repaints the appropriate view. Goodbye and link loss still clear the ring. Existing cache keys and ownership remain unchanged.
- No dependency, protocol, pill renderer, allocation, timer, or resource-lifecycle additions were introduced.

### Simplicity Assessment

- Lines that could be removed: 0 required.
- Unnecessary abstractions: none. Ambient scaling and the shared transfer limit each express a distinct necessary operation.
- YAGNI violations: none.
- Complexity verdict: already minimal for reproducing the approved physical-duty profile while preserving ambient output and total current.

### Testing Assessment

- New code with tests: test changes and execution were being finalized independently during this review; not claimed as verified here.
- Test quality: deferred to the focused test review; independent arithmetic/profile checks above passed.
- State-management test coverage: no new state-management unit.
- UI component test coverage: not applicable to this firmware-only delta.
- Physical validation: still requires observing the flashed 40-LED ring and accepting its appearance.
