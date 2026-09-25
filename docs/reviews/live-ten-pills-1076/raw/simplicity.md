# Code simplicity review — live ten-pill firmware #1076

Reviewed 2026-09-24 against the deployed firmware 1.7 snapshot. This review is limited to the requested 80-pixel normal-operation update for the existing v2 console, including its new library dependency and tests. It does not treat the inherited one-pill diagnostic or the separate v3 PCB work as additions to this task.

## Core purpose

Render the ten installed eight-pixel pills in their verified physical order, retain approved REC/PLAY activity behaviour, use existing protocol-5 state for the other indicators, acknowledge STOP/UNDO switch holds without inventing looper state, and keep output within the existing rail budget while preserving input responsiveness.

## Unnecessary complexity

None identified in the incremental implementation.

The physical-group lookup is a direct description of the installed harness. `pillPixelIndex()` gives the different front/back orientation a single clear definition; it is not a generic mapping framework. The colour switch expresses the limited state already supplied by the application. The two rendering passes have a concrete purpose: first determine the complete desired output and total channel load, then proportionally limit it before editing the driver buffer. Replacing the small temporary array with repeated colour calculation would make this harder to follow.

NeoPixelBus supplies the needed PIO/DMA transfer rather than adding a custom peripheral driver. Retaining Adafruit for the existing ring and colour correction keeps the requested change bounded and avoids changing a working ring. No adapter hierarchy, runtime configuration, compatibility mode, new protocol, or firmware-side looper state machine is introduced.

The three channel scaling statements are straightforward and do not benefit from an extra one-use abstraction. The finite colour switches and fail-dark return are clearer than a generic colour conversion table whose index conventions would need additional explanation.

## Code to remove

No removal recommended. Estimated meaningful line reduction: 0.

## Testing and maintenance

Tests extend the existing actual-sketch host harness and observe transmitted protocol events and submitted pixels. They reuse the established fake clock and UART seam. The DMA stub models the library boundary rather than reimplementing the renderer. Tests cover the current limiter's repeated-render stability and recovery to the normal peak, so the extra budget logic has evidence proportionate to its purpose.

All four firmware host suites passed during the preceding VGV pass, and the source checksum is unchanged: `a09c54e38bf3a1c965c0f3d47d293d443ce74c932fdbc9f72b15d03127885485`. No redundant rerun was needed for this read-only simplicity pass.

## Final assessment

- Critical: 0
- Important: 0
- Suggestion: 0
- Potential useful line reduction: 0%.
- Complexity: low for the required output mapping and current limit.
- Recommendation: already minimal for the authorized scope.
