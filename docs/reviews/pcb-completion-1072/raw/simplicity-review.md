# Completion simplicity review

Reviewed the current working changes on `codex/screen-power-board-1072`, based
on `a2a6a1f4c2c404effc74af3a2268e596e724ca81`, on 2026-09-22. This review covers
the firmware, Pi screen-power lifecycle, PD repository support, and their
verification and CI changes. Generated CAD, historical design documents, and
manufacturing qualification are outside this code review.

## Simplification Analysis

### Core Purpose

Support the console v3 hardware and its separate ring controller, retain the
established ring animations, report available PD information without changing
the inlet configuration, and lower screen enable before orderly HDMI teardown.
Communication failure must invalidate stale state and take the affected output
to its defined inactive state.

### Unnecessary Complexity Found

No actionable unnecessary abstraction, obsolete compatibility path, or
speculative feature was found in the reviewed implementation.

- The shared Arduino library holds the wire codec, pixel adapter, and rendering
  support used by the two targets. The old console-local protocol copies are
  removed. The small pixel adapter preserves the existing color behavior while
  moving output to PIO/DMA; removing it would duplicate conversion and output
  details across the sketches.
- Ring snapshots, session identity, CRC framing, bounded delta recovery, and
  expiry serve concrete failure cases. Cumulative edge counts preserve a short
  press/release across missed snapshots. They do not introduce an unrequested
  action for the encoder button.
- The PD helper separates read-only status observation from the main sketch.
  Attachment settling, snapshot rechecking, and explicit unavailable states
  prevent old or partial controller contents being presented as current power
  information. The Dart watchdog has a separate purpose from the existing
  HELLO watchdog: HELLO messages can continue while PD reports stop.
- GPIO ownership persists in one small process. The local socket is the
  mechanism by which Weston waits for the output transition and discharge
  delay. The bounded reclaim path handles a killed owner and concurrent cleanup
  hooks; replacing this with a one-shot GPIO write would lose these guarantees.
- Weston owns when power is enabled. No separate boot enable path, automatic
  GPIO-service restart, configurable protocol framework, or PD-triggered
  power-cut policy was added.
- CI compiles both actual microcontroller targets using explicit dependency
  versions and adds the relevant host suites. It reuses the existing build and
  release jobs rather than creating a parallel deployment mechanism.

### Code to Remove

None identified. Estimated justified LOC reduction: 0.

### Simplification Recommendations

No code changes recommended. Retain the failure handling and freshness checks;
their removal would reduce the documented behavior rather than merely simplify
its implementation.

### YAGNI Violations

None requiring action in this scope. No historical document removal is proposed.

### Validation

Independently ran these current-checkout checks:

- `bash firmware/test/run_tests.sh`: all seven suites passed, including 54
  cross-language protocol fixtures, console input/presence/PD, ring framing and
  recovery, console host-to-ring forwarding, and ring rendering/timeout/input.
- `python3 deploy/yocto/meta-segno/recipes-segno/segno-bundle/test/test_screen_power.py`:
  all 11 lifecycle tests passed.

Reviewed the two CI workflows, the bundle recipe, GPIO helper and systemd units,
both sketches and shared library, presence and PD helpers, Dart model/codec and
repository freshness changes, and the focused firmware/lifecycle tests. The
review does not claim that host tests establish real GPIO timing, screen
discharge duration, electrical margins, cable pinout, or assembled-board behavior.

### Final Assessment

Total potential justified LOC reduction: 0%. Complexity score: low to medium,
appropriate to the separate hardware controllers and failure cases. Recommended
action: already minimal for the required behavior. Physical acceptance remains
open independently of this clean simplicity review.
