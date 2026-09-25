<!-- cspell:words nonblocking -->
# VGV review — live ten-pill firmware #1076

Reviewed 2026-09-24 in the live-ten-pills checkout, comparing the console implementation against the deployed firmware 1.7 source snapshot. Git HEAD was not used as the functional baseline because its earlier uncommitted pill changes predate this incremental task. Documentation is being updated separately by the parent; this report covers the final source and test implementation read for this pass.

## Summary

No actionable source, convention or test-quality findings. The change is focused on normal operation of the user's existing v2 board: ten eight-pixel indicator groups, the verified physical order, state-derived colours, held-button feedback for STOP and UNDO, a bounded total channel output, and nonblocking indicator transmission. The existing protocol 5, REC/PLAY semantics, ring rendering and inputs are preserved. Software review is clean for this scope; host tests do not establish the final visible result or measured rail current on the assembled unit.

## Regression and convention review

- The explicit physical-group lookup avoids conflating harness order with protocol button order. Pixel indices remain within the 80-element strip, and the existing decoder bounds-checks bank, mode and track colour values before rendering.
- Indicator rendering remains a thin interpretation of state. STOP and UNDO acknowledge the debounced physical switch without inventing looper state unavailable in protocol 5. The app's Mute label correctly uses the existing `PEDAL_MODE_PLAY` wire enum.
- The channel limiter sums desired gamma-corrected output, applies one proportional integer scale only when needed, and recomputes from desired colours on every frame. It cannot progressively dim an already limited buffer. The 6000-channel budget bounds colour output; it is a documented current estimate rather than a measurement.
- NeoPixelBus is an established library with a pinned version in the firmware workflows. Its installed RP2040 method uses DMA and a separate editing/sending buffer, so the production renderer's writes do not alter an in-flight transfer. The unchanged short Adafruit ring path retains its prior behaviour.
- The existing procedural Arduino style is appropriate to the firmware. New abstractions are limited to a colour selector and the physical pixel-index mapping; no speculative configuration or compatibility layer is introduced.
- No Dart/application data-flow changes, new bloc/state-management units or unowned asynchronous resources are introduced.

## Test assessment

Independently ran `bash firmware/test/run_tests.sh` after the test agent's update: all four suites pass, including 45 C/Dart fixtures, existing CTRL behaviour, the full ten-pill console test and the bench pill test. `git diff --check` passes.

The console test retains the earlier REC/PLAY activity and breathing assertions at its new physical group, feeds valid/corrupt protocol frames into the actual console loop, and verifies visible submitted pixel buffers. It adds all ten group mappings, both banks, modes, CLEAR/BANK, STOP/UNDO press and release with unchanged outbound events, current limiting, stable repeated rendering, restoration of uncrowded peak brightness, all-pixel darkness on shutdown/link loss, and valid reconnection. The asymmetric index tags are justified because the visible centre gradient is symmetric and could not by itself detect reversed physical addressing.

The NeoPixelBus stub models edited versus submitted pixels and dirty state without duplicating rendering logic. Hardware timing is deliberately outside that stub's claims. No existing behaviour assertion was removed without being replaced by an equivalent ten-pill assertion.

## Findings

- Critical: 0
- Important: 0
- Suggestion: 0

## Simplicity assessment

The incremental design is appropriately small. No unnecessary abstraction, obsolete compatibility path or meaningful removable implementation was identified. A larger renderer extraction would add structure without a current need for this bounded v2 update.

Reviewed SHA256 values:

- `console_board.ino`: `a09c54e38bf3a1c965c0f3d47d293d443ce74c932fdbc9f72b15d03127885485`
- `test_console_pill.cpp`: `e00e2fa58e2b490ca35a21acaae584618f645acbf62a940feaeb2905277f8436`
- `stubs/NeoPixelBus.h`: `35e850e83db98cdfad53345eb87a45ac98aabdf8c46690b38f176ffe2231beef`
