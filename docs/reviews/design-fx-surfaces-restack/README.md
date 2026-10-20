# FX surfaces reconstruction review

<!-- cspell:words FXUI FXD FXN -->

Status: local implementation and behavioral verification are complete.
Remote CI remains a separate gate on the published head.

Base: verified placement commit `a52fe34d42a719624762f7756518a7e54cf7fd0c`.
Original FX surfaces parent: `95dcea0d81f000c87a51c7a67cc931cc2da4df67`.
The integration retains both histories. Historical September checks do not
certify this reconstruction.

## Scope

The accepted Effects destination, factory library, individual and rack
editors, options, reorder and saved-sound pages replace the Signal tray.
Input, recorded-part, whole-track, recorded-mix and individual output chains
share the existing native recipe admission and confirmation boundary.
Stage returns to Tracks; Back preserves the expected navigation context.

Rack and effect identities survive structural edits. Reorder stays inside
the selected stage and preserves rack input/output boundaries. New sounds
start bypassed; saved presets create independent instances and preserve
whether a one-effect sound was saved as a rack. Outputs and All tracks keep
their fixed placement. There is no duplicate per-module power row.

## Repaired findings

| ID | Defect and correction | Evidence |
| --- | --- | --- |
| FXUI-1 | Structural success and durable state could precede native application. Existing receipt paths now wait for the exact application, reject stale generations and complete on cancellation. | Six independent real-engine lifecycle probes pass. |
| FXUI-2 | Preset loading raced edits, and failed storage could appear successful. Load ordering and durable publication now share one owner, with visible failure. | Focused tests and independent UI review. |
| FXUI-3 | My presets lacked the accepted artwork. | Approved asset copied unchanged; rendered view inspected. |
| FXUI-4 | Image captures relied on an arbitrary delay, and reorder controls overlapped cards. | Actual image decoding awaited; eleven renders pass, five changed views independently inspected. |
| FXUI-5 | Modal edits could overwrite intervening controller changes or resurrect removed entries. | Current-chain resolution and stable identity checks; focused behavioral tests. |
| FXUI-6 | Adding a rack module left the output envelope on the previous last module. | Boundary transfer and independent domain checks. |
| FXUI-7 | Stage left the underlying Settings tray open. | Shared navigation callback and focused navigation tests. |
| FXUI-8 | A vanished editor could render blank or pop an unrelated route. | Navigable missing-scope state and current-route checks. |
| FXUI-9 | Editor strips could show enabled effects while their chain was bypassed. | Whole-chain power projection and focused tests. |
| FXUI-10 | Adding a sound returned to the overview instead of opening its editor. | Exact admission, fresh identity and navigation tests pass; the running app opens both new singles and racks directly. |
| FXUI-11 | A lagging page could add to a full chain, receive success after truncation and wait forever for the missing identity. | Admission checks the actual destination length and refuses the entire append. The original independent failure now passes unchanged. |
| FXD-1 | Singleton channel edits could overwrite one side of the compound change. | Independent exact-value probe passes. |
| FXD-2 | Rack reorder/removal moved boundary settings with modules. | Independent identity/order and boundary-value probes pass. |
| FXD-3 | Stripping instance metadata lost one-module rack identity; one malformed preset could hide valid neighbors. | Required persisted kind, narrow invalid-row handling and unchanged independent probes. |
| FXN-1 | The expanded chain ceiling required coherent recipe, snapshot and lifetime handling. | Capacity, refusal, PCM, capture-partition and resource-lifetime checks pass. |

## Native and package validation

The frozen native candidate passes the normal, AddressSanitizer and
telemetry-disabled suites, dedicated race tests, C++ header compatibility and
all 186 generated symbol lookups. Five independently prepared sample and
ownership probes pass unchanged, including callback partitioning during
capture. A separate hosted-plugin test covers the expanded recipe lifetime.
No new callback allocation, blocking I/O or locks were found in the review.

Each reused package result is bound to its unchanged sources, dependencies
and test library. App-only changes do not cause those suites to be repeated.
One later model formatting correction only wraps a ternary expression. Its
original blob matches the tested input, and independent review confirms the
non-whitespace content is identical. This explicit amendment does not claim
that the original byte hash still matches.

| Package | Passing tests | Coverage | Required |
| --- | ---: | ---: | ---: |
| LooperRepository | 655 | 95.88% | 95% |
| Engine Dart | 346 | 69.82% | No configured floor |
| Session | 105 | 95.77% | 89% |
| Settings | 141 | 90.82% | No configured floor |
| Performance recording | 129 | 99.33% | 99% |
| DAW export | 100 | 100% | 100% |
| FX catalogue | 21 | 100% | 100% |

The full app suite passes 2,229 tests with six existing skips and 91.07%
coverage against the configured 90% floor. Its source remained unchanged
during the run. The first aggregate failure is preserved: an obsolete pedal
transport test fixture was replaced with the existing UART link fixture,
without changing assertions, and ten stale settings/control images were
visually reconciled. The corrected fixture's 43 tests also pass separately.

The final amendment adds a closed-owner guard to the existing synchronous
lifetime predicate, documents the three narrowly scoped lint exceptions, and
adds a stale-at-library-open regression case. Its 190 affected FX/Bloc tests
pass. Source comparison confirms only those two production files and one test
file differ from the full-app run; the receipt and append mechanisms are
unchanged. The aggregate result above is reused with this explicit amendment,
not presented as a fresh full-suite run on different source bytes.

Earlier failures remain recorded. The capacity fixture now actually exceeds
the new 64-entry ceiling while retaining its original partition assertions.
The catalogue tests distinguish display names from power aliases and verify
real artwork lookup. Neither correction weakens the accepted behavior.

## UI and review evidence

Eleven FX captures pass. Five intentional baseline changes cover approved
My presets artwork, input monitor fixtures, output layout, library artwork and
separated reorder controls. A second reviewer inspected those rendered views
and verified their recorded hashes. These are local visual checks, not
portable CI or physical-display proof.

The macOS development app built, started audio and exercised Tracks,
Settings, Effects, the factory rack library and adding a bypassed rack. That
journey exposed FXUI-10 rather than treating passing widget tests as enough.
After the repair, the running app opened the newly added Delay and Acoustic
Rhythm 2 editors directly. Back retained the Mic destination, and Stage closed
the underlying tray. No runtime error occurred during that final FX journey.

The later full-app comparison also passes all screenshots without updating
them. A second reviewer inspected the ten settings/control changes: Effects
replaces Signal, output destinations replace Master chain, obsolete Signal
cache controls are removed, and the Controllers tab retains its current name.
These are distinct from the five earlier FX artwork/layout updates.

Independent reviewers split package/native and app/UI ownership; neither
certifies code they authored. Five quality roles share these reviewers rather
than implying five separate people. The reconciled bug gate and role reports
bind the final implementation separately from remote CI.

The lifetime predicate intentionally reads the actual engine generation after
asynchronous work, while initial edits capture the displayed generation.
This prevents attaching stale UI data to a new session. One documented
method-level Bloc lint exception permits this read-only boolean check; two
documented Cubit exceptions permit exact asynchronous mutation receipts.
All mutations still pass through the established owners. The installed linter
has an override-state parser blind spot, so these exceptions were assessed
explicitly rather than treating its clean scan as proof of compliance.

## Explicit limits

The factory catalogue preserves extracted names and raw preset data. It does
not establish complete active parameter preservation or DSP parity: runtime
projection still has four native parameter slots, and 20 of 26 modules remain
pass-through. Exact effect/rack/parameter parity remains mandatory M6 work;
unverified scales and factory reset defaults must not be invented.

Mac interaction and native sample tests do not certify appliance touch,
pedals, listening or two-screen behavior. Previously identified platform
storage ordering across session replacement remains M7 work. Publication,
current-head CI and the human merge gate remain separate requirements.
An earlier development log reported a bottom layout overflow before the final
reload; its viewport was not captured and it did not recur in the FX journey.
The final responsive-layout audit must resolve that separate observation.
