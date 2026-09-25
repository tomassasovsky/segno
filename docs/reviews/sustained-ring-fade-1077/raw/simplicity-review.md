# Sustained ring fade — simplicity review

## Simplification Analysis

### Core Purpose

Apply the approved sustained-fade preview to the old board's 40-pixel ring: a
192-duty leading head, a 30-pixel tail, fractional movement every 1.1 seconds,
unchanged ambient output, and the existing total current ceiling. Preserve the
working pill renderer, link protocol, frozen-comet behavior, and volume overlay.

### Scope and Evidence

Reviewed only the changes in `firmware/console_board/console_board.ino` and
`firmware/test/test_console_pill.cpp` relative to their supplied copies in
the saved firmware 1.10 baseline. Existing working-tree changes were outside
this review. Compared the profile and interpolation with the approved
`sustained-ring-comet.html` preview and read the surrounding ring state handling
and pixel-driver test seam. This was a read-only implementation review; no
device operations or test runs were performed by this reviewer.

### Unnecessary Complexity Found

None. The fixed duty table states the approved physical output directly and
avoids reconstructing it with a more complicated curve or adding configuration.
Circular interpolation is local to the renderer and matches the preview.

The ambient conversion helper is needed because the brighter localized head
requires removing the old driver-wide brightness reduction. Its three existing
ambient callers preserve the old byte output without introducing a parallel
rendering path. The shared transfer helper is the single enforcement point for
the retained total ring ceiling. Its two-pass limiter is bounded to 40 pixels,
does not allocate, and cannot repeatedly dim an already limited frame.

The new tests exercise transmitted output, motion direction and wrap,
fractional transitions, weak mixed-color channels, power limiting, ambient
parity, and existing state transitions. They do not introduce a new test
framework or generic simulation layer. Their size is justified by the distinct
visual and state behaviors affected by changing where brightness is applied.

### Code to Remove

None. Estimated LOC reduction: 0.

### Simplification Recommendations

No actionable simplification is needed. Keeping the profile, ambient scaling,
and transfer budget as separate small operations makes their different duties
clearer than merging them into a configurable brightness abstraction.

### YAGNI Violations

None. No compatibility path, alternate effect, configurable profile system,
protocol change, or unrelated board support was added.

### Final Assessment

Total potential LOC reduction: 0%. Complexity score: Low. Recommended action:
Already minimal. Critical: 0. Important: 0. Suggestion: 0.
