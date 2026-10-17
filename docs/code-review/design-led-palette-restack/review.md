# M3.6 palette source review

Complete independent source review: no unresolved actionable findings. Critical: 0. Important: 0. Suggestions: 0. All observed local gates pass.

## Exact scope and independence

Base: `27b13351a7ad43828a4bd83d14305ed5978572b4`. Original PR 1032 head: `1e1dbc6088ccd438f5c3d93086c6cd6eef2d3310`. Reviewed freeze-v2 contains 31 paths with fingerprint `263eb7002dcaf03c6b1f23a24c406a81541e1e5cdb3aea95b7d4d85bcc630582`. Every path was rehashed at finalization; no mismatch. Source and verification bindings record exact per-file/evidence hashes. Publication documentation added afterward is outside this product-source fingerprint and needs normal reconciliation.

One reviewer independent of the palette implementation completed the bug-focused review and all five VGV roles sequentially. Those roles are five perspectives, not five independent agents. The adversarial oracle was prepared before implementation by a different reviewer. Runtime/widget probes were executed by a replacement reviewer who authored only unchanged M3.5 native/protocol work, not this M3.6 palette/app delta. That reassignment and its bounded execution coverage are disclosed in the adversarial report. This source reviewer made no product edits and ran no tests, builds, native reruns or Git mutations.

## Completed review angles

- Full changed-hunk and enclosing-function review: palette, setup decode/encode/equality, projection, Cubit save/completion, map/editor/dialog, localization, tests, nine goldens and saved design notes.
- Removed invariants: unconditional save invalidation and full-setup async completion equality were narrowed only for palette differences. True assignment changes, unavailable recovery, admission result, current mode, session and latest press token still govern ownership.
- Cross-file tracing: editor draft through durable SettingsRepository checkpoint/write/readback/rollback; confirmed setup through ControlCubit projection and PedalRepository/PedalCubit to UI and wire; corrupt raw setup through unavailable state; Clear/Restore and captured dialog destination through latest draft.
- Reuse and simplicity: existing focus/slider/dialog controls, Equatable, settings serialization and v8 frame avoid new packages, storage owners, compatibility or native work. Shared editor frame has two immediate callers. No justified unnecessary abstraction or removable code identified.
- Efficiency and lifetime: projection adds bounded ten-color lookup; no new realtime callback, native allocation/lock or I/O path. No new subscription/controller leak. Dialog result checks mounted, captured identity and live setup replacement. Hue-only saves preserve accepted contacts, last-fired Hold, pending timers and FX restoration duties.
- Conventions and visuals: presentation consumes Cubit/repository abstractions; palette model has no Flutter import; map data is detached/immutable and encoding canonical. All ten physical switches use real activation, local hue preview and separate selection. Nine setup goldens were visually inspected without clipping or rear-cap overlap. Saved Pen qaI7U and ZwFzy content matches scope and preserves the later M7 design reconciliation limit.

The implementation preserves fresh white RGB FFFFFF, explicit black, stable shared custom IDs and strict rejection of malformed explicit palettes. Confirmed hue follows durable Save; local preview never publishes to the board or invents activity. Restore recovers only Custom assignments, retaining subsequent palette and Track Hold edits. No obsolete protocol, renderer, SysEx or fallback path is restored.

## Observed verification

| Gate | Observed result |
| --- | --- |
| Full application v2 | 2,371 pass; six existing skips; exit zero; no input drift |
| Application coverage | 20,397 / 22,652 = 90.045%; required 90% |
| Full static v1 | Format, fatal-info analyzer, real Bloc scan and whitespace pass; 672 intended files; no input drift |
| Test-only v2 delta | Format, analyzer, actual Bloc scan of one file and whitespace pass; unchanged full static evidence reused |
| Independent behavioral review | Nine real native-pump/model cases plus four widget cases pass on the exact freeze |
| Author UI evidence | 36 focused page cases, nine goldens, and native desktop Save/restart/reuse journey pass |
| Final source binding | All 31 paths match freeze-v2 |

Independent probes confirm real fired-Hold identity and pending thresholds across hue Save, genuine assignment invalidation, active and delayed Solo, captured FX momentary restoration, FX return, delayed durable publication, exact write-then-throw rollback, persistent uncertainty repaired by confirmed same-value Save, all-ten local preview, stale-dialog rejection and Clear/Restore preserving later edits. The report clearly limits unexecuted permutations; no parent sensitivity run or new firmware/device execution is implied.

Full app v1 initially failed only the theme-color source scanner, which classified saved hardware RGB constants as ordinary UI styling. The sole v2 change adds a narrow documented palette-file exception; UI surfaces/focus still require theme tokens. Production inputs remain identical to v1. The failure is retained. The adversarial initial Solo/FX-return failures were fixture assumptions: settings writes serialize behind a gate, and the default Mode Press is Mute. Corrected fixtures preserve the intended pending-ack and Custom-return assertions; no product change or weakened expectation was used.

## Readiness and limits

The local source/five-role review is clean. Native/protocol/FFI production inputs are unchanged; UART v8/STATE51 and prior renderer evidence are preserved, not claimed as newly executed here. No physical flash, optical calibration, brightness/current, appliance or deployment verification was performed. Author-only screenshots and desktop journey are distinct from CI and physical validation.

Root owns publication, final commit/PR-head reconciliation and remote CI. This report does not itself establish green remote CI or authorize merge. The existing `autonomy:merge-gate` decision remains in force.
