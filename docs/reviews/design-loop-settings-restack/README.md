# Loop settings reconstruction: validation

October 1, 2026. Issue #1012, PR #1015, epic #1009. This reconstructs the
accepted Loop settings pages on the verified timing and recovery stack.
The human merge gate remains in force; nothing is deployed by this work.

Comparison base: `82803eff15ab7f8b053431a4bbcfbc84d58b6ba3`.
Reviewed source, tests and golden fingerprint:
`00aa71e57b0ca0824c8474e0882f9cf0c9b3cfbdb790f860c67cdaa52d7632d5`.
The merge preserves the original slice parent `839cb330b` and the reconstructed
timing parent. Documentation is separate from the tested source fingerprint.

## Accepted behavior and evidence

| Journey | Required result | Evidence |
| --- | --- | --- |
| Defaults and individual tracks | Inherit differs from explicit Auto, Loop or a value equal to the default; empty tracks keep overrides | Repository, settings and session round trips |
| Shared Multi length | All tracks use the shared default; independent overrides remain stored for other modes | Length page and repository assertions |
| Live mode/length change | One full vector is accepted or nothing changes; compatible mode changes stop only after validation | Native queue, capacity, capture and mode tests |
| Callback confirmation | No unconfirmed choice reaches preferences or session save | Deferred acknowledgement, late refusal and save tests |
| Startup and reconnect | Replay confirmed settings; cancel obsolete requests without disabling reconnect | Two regressions reproduced before repair, then passing |
| Cancel and navigation | Drafts cancel on Back, scope change or capture; Stage closes the original tray | Touch/focus widget journeys |
| Numeric controls | A double tap resets once; scopes retain their own last bar counts | Gesture and scope tests |
| Failed choice | Explain immediate or late refusal; keep confirmed settings and avoid duplicate notices | Repository failure stream, scoped Cubit and route tests |
| Session replacement | A pending save cannot capture a newly recalled rig under the old request | Deferred save with changed session revision |

Sources: the accepted behavior handoff, Loop setup and mode-transition design
records, and the saved Loop settings section in `segno-ui.pen`. The prototype
is a behavior reference; it does not establish native correctness.

## Final local checks

Visible test counts exclude hidden suite loading and setup events.

| Suite | Passed | Coverage |
| --- | ---: | ---: |
| App | 2,260; 6 existing skips | 93.76% after the CI exclusions; floor 90% |
| Looper repository | 495 | 97.71%; floor 95% |
| Session repository | 95 | 98.50%; floor 89% |
| Performance repository | 111 | 100%; floor 99% |
| Engine Dart interface | 295 | 69.17%, including native wrapper glue; no separate CI floor |
| Settings repository | 135 | 92.27% |
| MIDI client | 43 | 95.35% |
| MIDI device repository | 22 | 95.24% |

- Explicit-path formatter: 612 files, zero changes. Analyzer: 42 source/test
  directories, zero issues. Bloc lint: 613 files, zero issues; a visible path
  was used to prevent the ignored-worktree false no-op. The final seven-file
  repair separately passes formatter, analyzer and Bloc lint with actual scan
  counts. Diff whitespace and changed-document spelling checks pass.
- Native normal, AddressSanitizer and telemetry-disabled runs each pass five
  suites containing 685 named cases. Dedicated race tests pass 3/3 under
  ThreadSanitizer. The non-Clang C++ shim compile passes. Five Linux-specific
  cases are skipped on macOS; plugin C++ tests are not ASAN-instrumented.
- Bindings were regenerated and formatted. All 157 declared entry points
  resolve in the full native library. Real-FFI vector tests use the rebuilt
  test library, whose SHA-256 is
  `ef259b401e3f8813cf7f87ce28e392f50df21f37d5c06c58b1b8932c390032cb`.
- The app and package runs record unchanged inputs before and after execution.
  Passing unrelated checks were reused only while their inputs stayed fixed.
  The first broad app run exposed three fixture regressions; explicit callback
  simulation and the missing mock transport projection were repaired, then
  the full affected app and looper suites passed.
- The last live-app repair adds ten passing app cases. An independent review
  checked repeated capacity refusals, child edit cancellation and identical
  offline session replacement; the full affected app suite then passed with
  unchanged inputs. Native and domain inputs did not change.
- Eleven Loop page goldens were compared visually with the saved design.
  Five related Settings/routing images were intentionally updated and
  inspected. Golden success is author visual evidence, not an audio oracle.

## Consolidated review

Zero unresolved actionable findings after the final focused repair review.
Independent roles covered VGV conventions, architecture, test quality,
simplicity and PR readiness. A separate adversarial review traced native
validation, publication, startup, reconnect, session and persistence boundaries.
The coordinator independently reviewed native changes authored by another agent.
No reviewer certified their own implementation.

Resolved findings remain recorded for traceability:

| ID | Severity | Rule | Location | Resolution |
| --- | --- | --- | --- | --- |
| FINDING-01 | Critical | architecture/reconnect-pending-request | `looper_repository.dart` reconnect boundary | Cancel obsolete request before raw stop; preserve recovery and confirmed state |
| FINDING-02 | Important | vgv/tray-navigation | `segno_navigator.dart` | Stage closes the originating tray; Back retains it |
| FINDING-03 | Important | simplicity/obsolete-ui-command | `looper_event.dart` | Remove unused multiple and all-track Once commands, helper, getter and tests |
| FINDING-04 | Important | vgv/scope-memory | `loop_length_page.dart` | Store last Bars separately per scope; Multi does not overwrite it |
| FINDING-05 | Important | vgv/gesture-arbitration | `loop_settings_widgets.dart` | One double-tap reset, without a preceding single-tap commit |
| FINDING-06 | Important | vgv/duplicate-timing-control | `track_routing_dialog.dart` | Retire the coarse quantize choices and unused labels |
| FINDING-07 | Important | adversarial/refusal-feedback | Loop settings route and repository | Explain immediate and callback refusals through one scoped notification path |
| FINDING-08 | Important | tests/refusal-persistence | `record_timing_cubit_test.dart` | Assert rejected edits and startup restores preserve display and both saved keys |
| FINDING-09 | Important | tests/save-supersession | `session_cubit_test.dart` | Change session revision before settlement; assert failure and no save |
| FINDING-10 | Important | live-app/length-refusal-dead-end | `loop_length_page.dart` | Rejected counts remain editable; the confirmed setting and persistence stay unchanged |
| FINDING-11 | Important | adversarial/stale-numeric-draft | Length editor and feedback Cubit | Cancel parent and child edits across capture and session replacement; observe the explicit rig-replacement signal |
| FINDING-12 | Important | lifecycle/disposed-edit-callback | `loop_edit_scope.dart` | Release bound-method callbacks by equality when their control is disposed |

Additional confirmed-request persistence repair separates accepted length
revisions from unrelated or rejected edits. A second rejected tap must not
cancel persistence of an already accepted request. Focused regressions and
independent repair reviews pass. The suspected settings/audio save mismatch
was discarded after tracing the existing invocation-time capture contract;
it was not evidence of an introduced M1 defect.

The one-free-queue-slot regression failed before the atomic native command,
and both pending-request reconnect regressions failed before repair. Other
expectations derive from explicit samples, state and accepted behavior rather
than production helpers. Reports and raw execution logs are retained in local
delivery evidence; they are not machine-dependent repository artifacts.

The native desktop run reproduced the capacity dead-end before repair, then
confirmed that the rejected four-bar count stays visible beside the active Auto
choice and can be edited. Pen now includes that refusal state and an updated
implementation note; its saved file changed on disk. After the Mac was unlocked, choosing the shorter three-bar count applied
successfully, activated Bars and cleared the refusal hint. Returning to Auto
also succeeded, restoring the original setup. This completes the native
refusal-to-acceptance click-through alongside the automated journeys.

## Boundaries

Remote CI must pass on the published head before this PR is marked ready.
Local validation does not replace Linux x64/ARM64 builds or appliance proof.
The six existing app skips remain explicit; no test was disabled to pass M1.

Audio & tempo is still an explicitly disabled readout. Actual tempo following
and pitch processing belong to M4/M6 and must be completed before the broader
campaign is done. Focus/keyboard testing does not establish physical UART
encoder control, which belongs to M3. Both real displays, touch calibration,
audio latency and hardware controllers still require appliance validation.
