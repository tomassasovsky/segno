# FX placement reconstruction review

Status: local implementation, coverage, static checks and independent source review complete. Publication and current-head CI remain separate gates.

This reconstruction starts from verified Mixer commit
`a0a54e57ed371c316b9eabcc64379c2c431150cc` and incorporates original placement
commit `be987759def149f986e4ec176daeff88bc42d0ee`. The reconstructed source is reviewed independently. September review results do
not certify it.

## Scope

Pre/Post placement and per-instance channel handling use complete prepared
recipes. Whole-track Pre combines original parts before processing; its Mixer
gain remains separate from those part levels. Output and recorded-mix stages,
plugin lifetime, capture inheritance and session persistence share the same
application boundary. Original recordings and their edit history remain intact.

The processing contract is in
[Whole-track Pre](../../design/2026-09-10-whole-track-pre-render.md). FX screens
follow in slice 3f. Playback transforms, complete offline rendering and exact
effect-definition/DSP parity remain later implementation slices.

## Independent findings

| ID | Finding | Verification status |
| --- | --- | --- |
| FX-N1 | A queued recording writer could overlap the cache's source copy. | Native ownership and sample probes pass. |
| FX-N2 | Mixer track gain overwrote part levels and could move ahead of nonlinear track Pre. | Independent unequal-part and nonlinear sample checks pass; independent app persistence checks pass. |
| FX-N3 | Recorded-mix processing could write to a disabled physical output. | Independent output-mask checks pass. |
| FX-N4 | Structural edits could partially publish or retire hosted resources too early. | Native prepared-recipe and lifetime checks pass; independent history/caller checks pass. |
| FX-N5 | Cache status omitted the part-Post obstruction or kept an obsolete reason. | Independent obstruction/removal checks pass. |
| FX-N6 | Saved/exported mixdown omitted the separate track gain. | Unchanged independent saved-WAV check passes; live export has author regression coverage. |
| FX-N7 | Capture changes inside a callback retained old effect snapshots for its remaining frames. | Four unchanged independent callback-partition probes pass, including cached playback. |
| FX-N8 | Invalid channel tuples could return refusal after changing part of the state. | Independent rejection check passes; invalid tuples preserve previous sound. |
| FX-D1 | A late acknowledgment or an older parameter-save timer could save the wrong recipe or lose a save. | Independent delayed-ack and restart checks pass; full app suite passes. |
| FX-D2 | Bus plugins exceeded the supported hosting boundary instead of staying explicit placeholders. | Architecture review confirms explicit placeholders; full domain suite passes. |
| FX-D3 | Input Pre metadata was incorrectly sent as a native monitor processing split. | Real-engine capture regression and architecture review pass. |
| FX-D4 | Loading a smaller session retained cached effects for absent tracks and parts. | Original failing case and neighboring part case pass; independent review is clean. |
| FX-D5 | A completed empty plugin scan returned unavailable effects to Loading during unrelated edits. | Original recovery case and four neighbors pass; independent review is clean. |

Clear, Undo and explicit input-effect copying are reviewed as callers of FX-N4
and FX-D1. The repair must preserve refused operations, prevent early playback
with the wrong recipe, and let the latest Clear/Undo intent replace an older
pending reset. Relink retains placement and channel choices while removing
state that belongs to a different plugin identity.

Independent real-engine history checks now pass for immediate Clear/Undo,
original sound and chain-power restoration, fresh dry recording, and refusal.
Separate stop/start and direct reconnect checks preserve the latest accepted
history recipe. Two separately prepared real Bloc/Settings probes pass with callbacks delayed
for 650 ms, including a previously scheduled parameter save. They preserve the
old durable envelope until the corresponding recipe is applied.

## Native evidence

The final native revision passes 744 named tests in each of the normal,
AddressSanitizer and telemetry-disabled configurations. ThreadSanitizer covers
the telemetry races and prepared-plugin lifetime. The C++ header compatibility
check passes, and all 186 generated FFI symbols resolve in the built library.
Source hashes remained unchanged during those runs. The platform plugin-host
suite runs on macOS but is not itself instrumented by the core ASAN runner.

Independent probes were prepared separately from the implementation tests.
The earlier failing binaries, fixed expectations and failed cases were kept;
repair verification reran those same probes. The second native revision's
broad suites were deliberately withheld after a new cached-playback failure,
then run once on the repaired third revision.

Primitive channel setters validate before individually publishing fields;
they do not promise an atomic tuple snapshot. Compound edits belong to the
complete-recipe API. Refusal validation does not prove compound atomicity.

## Completed package checks

The complete Settings, Session, DAW export, engine and performance-recording
package suites pass. Their relevant source and dependency hashes remain bound
to the recorded results; app-only edits do not require repeating those suites.
Coverage meets the configured Session, DAW export and performance floors.
The complete app and LooperRepository suites now also pass:

| Scope | Passing tests | Coverage | Required |
| --- | ---: | ---: | ---: |
| App | 2,401 | 92.98% | 90% |
| LooperRepository | 596 | 95.55% | 95% |
| Engine Dart | 346 | 70.12% | No configured floor |
| Session | 104 | 95.68% | 89% |
| Settings | 141 | 91.06% | No configured floor |
| Performance recording | 128 | 99.31% | 99% |
| DAW export | 100 | 100% | 100% |

The app retains six existing skips. Reused package results are tied to unchanged
relevant sources and dependencies. A later constant-only engine test correction
has its own focused pass. The final Bloc test-helper correction also passes
its complete 128-test file. Neither is presented as a new complete aggregate
run, and neither changes production code or coverage source lines.

Three obsolete test fixtures were corrected without changing production
behavior: part-volume assertions now distinguish the separate track gain,
the recording fake explicitly refuses unsupported recipe operations, and the
queued-recording test waits for actual queue admission instead of a fixed
filesystem delay. Independent review confirmed that their original behavioral
assertions remain intact. Earlier failed runs are retained with the corrections.

## Aggregate repairs and desktop check

The first aggregate run exposed stale structural-FX assertions and mocks
missing the replay-confirmation stream. Their failures remain recorded; the
repairs keep the existing visual, timing, count, order and power assertions.
An interrupted Flutter run returned exit zero despite incomplete tests, so
the aggregate gate also requires successful JSON completion with no errors.

The same run caught a real session-reset defect: loading a smaller rig
retained effects for absent tracks and parts. The repair removes those cached
entries without submitting invalid native targets. A completed empty plugin
scan now also leaves missing plugins unavailable during unrelated bus edits,
rather than returning them to a permanent loading state. Both corrections
received independent source review and preserve their original failing cases.

The macOS development app built and started its audio engine. Tracks, Mixer
and the existing input/track effect navigation were exercised in the actual
app; a Dart hot restart picked up the final missing-plugin repair. All 186
bindings resolve in its linked native framework. A startup multi-window
warning remains recorded; main-window interaction succeeded. This was a
read-only navigation check, not an appliance or listening test. Generated
launch-file changes were restored after the run.

## Final local gate and publication

Formatting passes on 640 explicit Dart files with no changes. Strict analysis
reports no issues, and the actual 640-file Bloc scan passes with no exclusions
added. The earlier helper lint findings were corrected using the established
Bloc test API; the complete affected file passes. Whitespace and changed
public-document spelling checks also pass.

Five role reviews are complete across two independent reviewers. Architecture
excludes its reviewer's earlier native/engine/export and initial gain wiring;
the other reviewer covers those paths. The bug-focused review covers the full
intended diff and repair deltas with no unresolved actionable findings. Five
role passes are not five separately staffed reviewers.

Source and committed-blob reconciliation bind these results to the published
candidate. Remote CI must pass on that same head before it is ready to merge.
Appliance timing and listening remain device validation. Already-started
platform storage writes across session replacement remain an explicit M7
integration obligation; this slice does not claim to cancel those writes.
The existing human merge gate remains.
