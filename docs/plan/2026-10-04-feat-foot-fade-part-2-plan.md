# Durable Fade state and lifetime composition

Tracking: #1026, human merge gate. Implementation already authorized; no merge or
deployment authority. Parent: [Foot Fade](2026-10-04-feat-foot-fade-plan.md).
Dependencies: Part 1. Read the parent's accepted behavior and exact ownership first.

## Work

Add one duration default/override model in an existing appropriate package and
one small application settings writer. Own storage and next-gesture intent only;
no current coefficient, interpolation, native-setting receipt or reconnect owner.
Use existing failure/retry, mapping precedence and Session exclusion.

Capture stationary Fade amounts from the same detached engine image used by
SessionRepository. Strictly preflight and install the complete saved tuple before
audibility; preserve stopped load and boot-settings recovery. Reconnect retains
only coherent observed amount/target/rate, excludes pending unapplied commands,
resumes in seconds without wall-clock catch-up and cannot overwrite new Sessions.

Extend existing ordinary/frozen Clear metadata at the actual native Clear boundary.
Preserve grouped history and later independent edits; Fade gestures add no history.
New Loop/removal retire obsolete runtime, retaining durations. No schema fallback.

Files: repository Track/SessionRig and lifecycle, existing native Clear/history
paths, settings/session codecs and SessionSettingsCoordinator capture/apply;
small fade_settings application owner and AppRuntime composition.

## Observable verification

Test strict ranges/inheritance/default reset, write failure/retry, same-snapshot
capture while moving, stationary recall, loss after enqueue before application,
reopen/sample-rate change, failed boot persistence and new Session precedence.
Literal delayed ordinary/frozen Clear cases prove captured amount at application,
stale-generation rejection and undo-to-empty/redo without stale running fades.

```success-criteria
GOAL: Complete durable fade state and lifetime composition without changing unrelated accepted behavior.
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
