# Non-production completion pass

September 9, 2026 · Issue 919 · Demonstrated prototype accepted by the owner.

The owner authorized every remaining list item except production and requested
an actual recording of the working flows. The seven-chapter
[walkthrough](completion-previews/walkthrough.html) records browser interactions,
including the exact illustrative sound buffers played in the processing chapter.
[Interactive starting points](completion-previews/index.html) remain available.
This pass extends the accepted six recovery flows; their approval is preserved.
The owner accepted the walkthrough with a primary-track crown refinement and
then accepted that refinement. Reference gaps and production claims are separate.

## Implemented

| Area | Result |
| --- | --- |
| Performance recording | Internal or direct USB destination; output level and mute are excluded by default, with explicit Follow output volume. The choice is frozen into each take and its saved metadata. |
| USB recovery | Same-drive checkpoints, safe stop on low space or slow writes, cancellation on unplug, exact-part recovery, and separate internal/USB capacity. Copies take the identity of their actual destination. |
| Selected-track rendering | Bounce and Save audio use one common-cycle rule, with an optional chosen length. Selected stopped or muted tracks are included deliberately. Track levels and runnable Post FX are included; current Pre FX are not reapplied to recorded audio. Rack channel handling is frozen with the recipe. All tracks FX are optional; output FX, live inputs, backing and click are excluded. Once plays once, then leaves silence. Track Mono averages the recorded stereo signal before downstream Post processing; its source channels remain recoverable. |
| Sound behavior | Stop and Clear let downstream delay/reverb finish. Mute gates the track while previously fed shared/output tails finish. Bypass sends new audio dry and drains the old tail. Cut sound stops all audible sources and tails immediately; failed capture publication still preserves the measured take for retry. Printed Pre stops with its recording. Wrap/Cut determines the finite rendered loop boundary. |
| Timing | Stable musical capture cycles with reversed, sped-up, Once or independent playback; explicit timing-source replacement before Clear; optional first-take timing correction; external clock loss and Song Position handling. Measured audio duration and unwritten silence remain intact. |
| Touch and pedals | Optional touch lock, accessible unlock, and optional double-press Solo. Physical controls continue while locked; hold gestures stay exclusive. |
| MIDI | Explicit Standard, 14-bit CC, NRPN, Bank + Program and relative CC Learn, with shared identity/collision rules, reconnect handling and saved mappings. Cut sound is an explicit assignable action. |

Frozen unsaved loop takes have a persistent **Save held take** cue. New Loop,
recall, restart and destructive replacement cannot silently discard that
material. Stop retries publication; explicit Undo retains its recovery path.
The failed write is not described as power-loss durability: closing the browser
can still lose material that never reached persistent storage.

## Original-source blockers

Exact rack/effect/parameter parity remains mandatory. This does **not** resolve:

- Exact units, ranges, choices and reset defaults for 239 rack control keys,
  plus the unverified Single FX schemas. Preset values and raw constructor
  arguments do not establish a correct user-facing control contract.

The supplied image contains historical references to 302 factory audio names,
but not their usable audio. The owner subsequently accepted independent sounds,
so acquiring that original collection is no longer a product prerequisite.

The [evidence inspector](fx-reference-inspector.html) exposes verified records
and a precise missing-source list. An authorized content export/runtime schema
would supply the missing reference evidence. Independent sounds are allowed;
guessed control contracts are not a substitute for the required parameter parity.
See the
[reference findings](2026-09-09-fx-reference-completion.md).

## Verification and design source

Chrome and Firefox author checks cover the integrated recording/recovery,
selected rendering, timing, touch/Solo, expanded MIDI and drive-identity flows.
Focused tests exercise exact frame/part accounting, rational common cycles,
Once behavior, processing examples and recovery failures. Five independent
review roles cover conventions, architecture, test quality, simplicity and
readiness; the [consolidated report](../reviews/2026-09-09-non-production-completion/review.md) records the checked files and resolved findings.

Pen sections 48–53 contain 19 aligned editable screens. The final handoff pass
corrected their text geometry, refreshed the clock-loss display and primary crown,
checked the current Track/Wave/Mixer and selected-track views, and saved the file.
See the [final Pen evidence](../handoff/segno-app/pen-verification.json) and
[screen identities](completion-previews/pen-import-resume.json). The earlier editor
stall is resolved; historical screenshots/video retain their original provenance.

The recording is a browser walkthrough, not a montage of still screenshots. Runtime
USB, MIDI and audio-engine behavior remains simulated, except the explicitly
illustrative audible processing examples. Native Linux implementation, hardware
measurements and power-loss proof are excluded from this request.

## Superseded executable proposals

The shared SelectedRender policy replaces the old separate selectedRecipe
function. The historical processing page now consumes the shared policy; its
older text requiring a chosen duration for every Once or independent track is
superseded. Earlier “recover in Free” proposals remain rejected: partial takes
retain their established loop span and unwritten silence in Multi.

Related details: [recording/render plan](../plan/2026-09-09-non-production-completion-plan.md),
[timing completion](2026-09-09-timing-completion.md),
[optional controls](2026-09-09-optional-controls.md).

The [delivery verification](completion-previews/delivery-verification.json) binds
the final prototype, video, browser checks and remaining limitations.

Owner follow-up: the [primary-track crown](2026-09-09-primary-crown.md) now marks
the first recording beside its track name in all performance views. The video
above predates this small visual refinement; the live prototype includes it.
