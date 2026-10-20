# Native Fade capability and engine seam

Tracking: #1131 (parent #1026), human merge gate. Implementation already authorized; no merge or
deployment authority. Parent: [Foot Fade](2026-10-04-feat-foot-fade-plan.md).
Dependencies: none. Read the parent's accepted behavior and exact ownership first.

## Work

Implement the parent plan's native Toggle and complete-image installation,
coherent applied/refused readback and AudioEngine/repository command seam together.
Resolve target on the callback, preserve independent-track command identity, and
multiply one coefficient at the existing gain boundary. Include initialization,
material reset, matching FFI declarations/bindings/snapshot decode and test fake.
Keep the new behavior internal/unadvertised and all existing playback at unity.

Implement performance initial-image capture, applied-event log/drain and offline
rendering in this same slice; no unconsumed Fade event. Preserve original PCM and
live monitoring. Keep native lifetime metadata interfaces concrete and immediately
used by the actual repository seam; complete persisted recovery is Part 2.

Files: core engine/private/commands/process/snapshot/API and existing perf files;
Dart AudioEngine/native/mock/snapshot/generated bindings; repository action seam.
Do not introduce a generic receipt/ramp/automation service.

## Observable verification

Literal samples prove linear timing at two rates/block sizes, continuous retrigger,
two toggles before polling, two independent tracks, saved Mixer/capture isolation,
refused commands/images, coherent tuple and first audible installed sample.
One actual-native repository case and logged-render parity complement native
oracles without copying their entire DSP matrix.

```success-criteria
GOAL: Complete native fade capability and engine seam without changing unrelated accepted behavior.
SUCCESS CRITERIA:
- The concrete behavior and failure cases above pass through the real owning layer. | verify: manual inspect bound automated result summary and independent review for this part.
- Changed code passes the repository's applicable formatter, analyzer, Bloc lint, native/FFI and coverage gates. | verify: manual run the parent plan and PROGRESS commands on frozen source for affected packages.
- Existing public app remains working; no incomplete destination is exposed. | verify: manual run the actual affected app/ingress regressions.
NON-GOALS:
- Other playback transforms, generic frameworks, unrelated owners or repeated unchanged verification.
VERIFICATION COMMAND: /Users/Tomas/development/flutter/bin/dart analyze --fatal-infos lib test packages
```

Resolve dependencies before explicit-file formatting. Use the working Flutter SDK
from PROGRESS. Native edits require native suite, ASAN, telemetry-disabled, C++
shim and matched FFI bindings/symbol proof. Freeze source before aggregate checks;
independent bug/VGV/test/simplicity reviews and current-head CI remain required.
Author screenshots and test seams are not appliance/listening validation.

## Implementation status — 2026-10-05

The internal native capability and repository seam are implemented and locally
verified. The [review](../code-review/foot-fade-native/review.md) records the exact
source freeze, independent review coverage, observed checks and remaining gates.
Parts 2 and 3 remain separate. In particular, Session recall must install and
confirm the stationary Fade image before any audible sample; the current Session
commit starts playback, so Part 2 must address stopped recall at that boundary.
