# Segno appliance roadmap

**Implementation handoff — September 9:** the [context pack](../handoff/segno-app/README.md) consolidates the accepted product, current app seams, source gates and a Claude Fable 5.1 entry prompt. The older completion/crown Pen comparison is finished and saved; the clock-loss text layout is repaired. Begin production with the existing-app Tracks and selected-track display slice when the receiving implementation task starts. No production work or publication was started by this handoff. The dated entries below are history; use the pack and linked acceptance records for current decisions.

**Current decision — September 9:** the owner accepted the
[non-production completion walkthrough](../design/2026-09-09-non-production-completion.md)
and the [primary-track crown](../design/2026-09-09-primary-crown.md). Segno must
retain the same Looper X racks, effects and effect parameters; its sound may
differ. Original factory audio is no longer a prerequisite. Unknown parameter
definitions remain unresolved, not permission to remove or invent controls.
See the [reference requirement](../design/2026-09-09-fx-reference-completion.md)
and [remaining gates](../design/2026-09-09-remaining-design-gates.md) for the current
boundary. The final completion/crown Pen synchronization is saved and verified in the handoff evidence.
Earlier proposal and correction-order entries below record how this direction
developed and do not reopen accepted flows. Production is excluded from this pass.

**Accepted virtual-instrument UX:** the owner requested instruments
triggered through controls or MIDI, whose generated audio can be routed like a
normal input. The [instrument-source brainstorm](../brainstorm/2026-09-09-virtual-instruments-brainstorm-doc.md)
records the initial direction; the [accepted closure](../design/2026-09-09-instrument-ux-review.md) governs the final setup and performance journey. This extends the earlier
effects-only plug-in scope; it does not claim working instrument hosting.

**Six prototype slices accepted — September 9:** [recorded-audio recovery,
physical-port repair, complete appliance backup, primary-track timing, live
preset audition and long-recording storage feedback](../design/2026-09-09-recovery-expansion-delivery.md)
are accepted in the main prototype and Pen sections 42–47, including the
simplified connection review and recorded walkthrough. The
[review gallery](../design/recovery-expansion-previews/index.html) includes all
fifteen states. Combined models and Chrome/Firefox journeys pass, and five
independent review roles have no unresolved findings in their bounded scopes.
The demonstrated behavior is accepted; native audio, physical discovery and
durable appliance recovery remain implementation gates. The earlier saved-control
repair summary is accepted. The [remaining design gates](../design/2026-09-09-remaining-design-gates.md)
reconcile this approval with the older audit without reopening these six flows.

**Product:** a Linux looping appliance with 7-inch and 15.6-inch screens and pedal controls. The current reviewed direction places the banked four-track overview on the main display and the selected track waveform on the small display. Keep macOS launch support for small development tests. Desktop product support is out of scope.

**September 8 recheck and correction order:** the owner requested a complete
Looper X comparison and authorized fixing the gaps. The [new audit](../research/segno-looper-x-comparison/2026-09-08-recheck/README.md)
and [correction record](../research/segno-looper-x-comparison/2026-09-08-recheck/corrections.md)
supersede stale “next design” suggestions below: Mixer first, then typed FX/shared
mappings, media/import completion, musical-state integration and appliance gaps.
Keep accepted designs; distinguish present prototype, accepted UX and verified production audio.

**Closure pass:** the [audit closure plan](../plan/2026-09-08-audit-closure-plan.md)
assigns all 183 rows a next gate, closing test and existing work package. Ten
concrete UX items remain, alongside grouped behavior/scope decisions, reference
questions and production/hardware work. Use this reconciliation after the first
correction pass; a passing prototype is not full instrument parity.

**Design authority — owner confirmed, 2026-09-06:** the reviewed UI and interaction designs define the target product: features, behavior and UX. Use Looper X research and the owner's requirements to decide what Segno should do. Inspect current code to identify reusable work and implementation gaps, never as a ceiling on the design. Amend this roadmap when the reviewed target changes. A missing API or current engine restriction belongs in the implementation gap record; it does not justify removing or disabling a target feature. Restrictions require a product reason with defined behavior, independent of how the code works today. Design approval and working appliance verification remain separate facts.

**Recommended direction:** rebuild the user experience in complete, working slices inside the existing application. Retain the native engine, repository boundaries, control dispatcher, audio history and capture infrastructure. Each replacement removes its predecessor before the slice is finished.

This is the entry point for the 2026-09-05 audit and proposed programme under [issue 919](https://github.com/tomassasovsky/segno/issues/919). It records direction and sequence. [GitHub issues remain the live status layer](../TRACKING.md); this page is not a second task board. The interactive prototype implements the reviewed design journeys. Production replacement of the Flutter UI and native behavior has not started under this proposal.

**Latest owner decision:** redesign settings substantially around Looper X-style destinations and submenus. The existing eight-section tray may be replaced. Musical recording behavior belongs in Loop; Audio covers hardware. A concrete FX prototype and screen study now make the proposed page map reviewable; production navigation has not been replaced. **Encoder control with visible focus is required alongside touch**, including submenu navigation, activation, editing and return paths.

**FX direction:** unlimited rack collection, input-specific FX and eight freely assignable FX-mode pedal positions across two banks. Rack count is independent of pedal count. Pedal assignments support both latched on/off and physical held/released states, with normal/inverse conditions such as `1`/`!1`; the UI distinguishes the state source.

**Foot performance — owner confirmed:** every function entered by foot must be
usable and escapable by foot. The screen provides pedal meanings and feedback;
touch and encoder remain optional for that journey. Exit returns to normal track
controls. [Pedal performance contracts](../design/2026-09-06-pedal-performance-contracts.md)
record the accepted Transpose, Mixer and Reverse journeys alongside FX behavior and undefined
catalogue behavior. A saved assignment is not a completed performance feature.

**Current design review:** [main prototype](../design/fx-ux-prototype.html), [FX journey and decisions](../design/2026-09-06-fx-ux-design.md), [current paired main/track preview](../design/stage-two-screen-preview.html), and [Looper X screen atlas](../research/sheeran-looper-x-1.0.2/rendered/atlas.html). The main display shows the four tracks of the selected bank, while the small display follows the selected track's waveform. Track, Wave and Mixer are alternative main views. The earlier FX paired preview predates that direction. The redundant FX footer and explanatory sidebars were removed after owner feedback. Original factory files and artwork are imported; working DSP is a separate milestone.

**UX acceptance priority:** interaction must be self-evident and self-describing.
The [FX simplicity review](../design/2026-09-06-fx-simplicity-review.md) recommends
consolidating rack entrances and editing parameters directly with appropriate
controls. These are assessed recommendations. The owner explicitly rejected the
subsequent signal-flow diagram layout; it must not become the appliance UI. The
replacement groups racks by the selected live input or recorded track/input;
All tracks opens shared processing of the combined loop audio. The owner found
this direction better and requested Auto monitoring and removal of tab underlines;
both are now reflected in the study. The owner accepted the revised UI direction
and requested artwork alignment fixes and a horizontal scrolling trial; populated
input and track previews now demonstrate ten racks each. Eighteen inputs use a
horizontal source strip, while eight tracks plus All tracks remain visible together.
The latest [larger pedal editor](../design/fx-ux-prototype.html?review=pedal-chain)
supports direct single effects alongside racks and connects grouped effects with plain lines and puts design-system filled
sliders beneath each. Double tap resets a parameter; standalone Default and
More/Less buttons are removed. Per-rack channel selection and mono/pan/balance
controls are an interaction proposal, without DSP implementation. Enabled states
are visible on the artwork, surfaces and power indicators. Author-side browser
checks pass; visual acceptance, native parameter descriptors and complete audibility
feedback remain open.
Looper X supplies clarity and interaction references while Segno’s additional
capabilities determine the product structure.

**External controls study:** [External pedals](../design/2026-09-06-external-pedals-ux.md) adds expression ranges, single/dual switches and fixed Track 1–8 assignments to the main prototype. The owner requested direct access to Tracks 5 and 6 while Bank A remains active. The accepted source-owned mapping flow now supports multiple FX activations and individual knob values per external button, using On/Off or Held/Released. External assignments are edited only under External pedals. Browser and Pen views use generic high-resolution artwork; physical dual-switch sensing and production track dispatch remain implementation gaps.

**Transpose study:** [Foot-operated pitch workflow](../design/fx-ux-prototype.html?review=performance-transpose) now covers track selection across banks, semitone steps, hold-to-reset and Exit. The owner accepted the layout, physical assignments, range of one octave in either direction, reset gesture and shared-limit rule. [Behavior and proof](../design/2026-09-06-pedal-performance-contracts.md#transpose) separate browser state from future audio implementation.

**Mixer — owner accepted:** [Tracks and Inputs by foot](../design/2026-09-07-mixer-performance-ux.md) uses one channel at a time. Inputs changes live-monitor volume only; Tracks changes recorded playback. Bank pages four channels and holding it switches source type, including eighteen inputs. Level, mute, reset and Auto-monitor feedback share the existing prototype control state. Production recording/monitor separation and gain processing remain implementation work.

**Reverse — owner accepted:** [Foot-operated direction](../design/2026-09-07-reverse-performance-ux.md) now provides per-track Forward/Reverse, direction LEDs, bank access and Exit. Immediate reversal at the current position and a small Reverse marker in normal Tracks are owner-approved behavior; Mixer remains unchanged. The owner accepted the native layouts and full interaction flow. Audio continuity, reversed overdub and physical timing remain implementation and listening-test work.

**Fade — owner accepted:** [Track fades by foot](../design/2026-09-07-fade-performance-ux.md) uses independent envelopes and preserves saved Mixer levels. The owner approved shared-default timing with per-track overrides, the layout, gestures, duration range and retrigger behavior. Browser checks cover inheritance, continuity, bank/Exit/Stop behavior and reload; production ramps and listening tests remain separate.

**Speed — owner accepted:** [Whole-loop tape speed](../design/2026-09-07-speed-performance-ux.md) provides accepted absolute half/double/four/eight choices, Normal reset and a retained Tracks readout. Pitch follows this explicit speed factor without changing automatic tempo-follow settings or Transpose. The owner accepted the layout and behavior, confirming its whole-loop scope and separation from Multiply/Divide length. Native audio composition and listening tests remain separate.
**Multiply and Divide — split ready for review:** [Recorded length by foot](../design/2026-09-07-length-performance-ux.md) now has separate assignable functions. Multiply doubles; Divide directly keeps First or Last half, with stable track controls and shared recovery. The owner requested this revision after accepting the combined flow. The intermediate chooser is removed. Native audio editing and mode relationships remain implementation work.

**Bounce — owner accepted:** [Bounce by foot](../design/2026-09-07-bounce-performance-ux.md) uses source selection, destination selection, explicit replacement, Keep/Clear sources, tail choice and whole-operation Undo/Redo. Chrome and Firefox checks pass; audio rendering and unified recovery remain implementation work.

**Audio loading and saving — proposal ready:** [Audio Library and Save audio](../design/2026-09-07-audio-library-ux.md) now provide Internal/USB browsing, explicit preview and loading, USB copy-on-import, named track exports, replacement and failure states in the main prototype. Prepared audio now connects that browser to a foot-operated Backing view, with independent pages of four, explicit Play, Pause, Stop and Exit. Native Pen screens are grouped as a proposal; Chrome and Firefox checks pass. Files and audio are simulated. Owner acceptance, real storage/audio work and hardware dispatch remain open.

**Prepared-list reorder — owner accepted:** Numbered rows and Move up/down beside Performance order replace the hard-to-find controls in the preview panel. The chosen order carries across performance pages. **Track import — next proposal:** [Audio files into loop tracks](../design/2026-09-07-track-import-ux.md) reuses the browser, selects an empty destination and explicitly loads at original duration/speed, stopped. Chrome and Firefox validate the silent descriptor flow; decoded audio and shared track/history integration remain implementation work.



**Pen organization:** [Canvas organization and verification](../design/2026-09-07-pen-canvas-organization.md) separates current UX, earlier application references, design-system components and superseded pedal options into labeled groups. All original screens are preserved, with no overlap or clipping caused by the new section containers. A separate redesign file is a recommendation, not a completed split.

## Read this in order

1. [Comparison and findings](../research/segno-looper-x-comparison/README.md): what exists, what is missing, and why work has been repeated.
2. [Implementation roadmap](../plan/2026-09-05-feat-appliance-ux-roadmap-plan.md): delivery slices, dependencies, owners, acceptance and hardware gates.
3. [First milestone plan](../plan/2026-09-05-feat-appliance-ux-roadmap-part-1-plan.md): session fidelity and the next submenu/focus design steps; navigation implementation is refined after the concrete design review.
4. [Complete Looper X reference](../research/sheeran-looper-x-1.0.2/README.md): all extracted feature families, 40 UX paths, 21 pages, 159 factory presets and source evidence.

## What happens next

[Remaining design work after the current prototype reviews](2026-09-07-remaining-design-work.md) separates the unfinished UX from production implementation. The Wave refinement is accepted. Safe existing-audio loop-mode changes are the next design slice.


| Order | Finished outcome | Existing home |
|---|---|---|
| 1 | One accepted programme; stale scopes reconciled; current appliance build and failure baseline recorded | 919; current reliability/board issues |
| 2 | A saved session recalls its actual musical state in all five modes; settings receives the agreed submenu-based redesign, with every repair entry routed correctly | Session fidelity under 263/682/854; navigation 494 |
| 3 | Stage → Library → return to playing is safe and understandable; Scratch autosaves; captures/recovered takes and appliance exports have a home | 682, 727, 926 |
| Then | Named sounds, complete mixing/performance tasks, media operations, tempo manipulation and external synchronization | Slice table in the plan |

Device reliability and the current console-board stack proceed alongside this sequence; they are release gates, not work postponed until the end. A blocked hardware test must not turn into a competing firmware implementation.

## Keep the project understandable

- **One owner per outcome.** Reuse the existing issue when it describes the same job. New slice IDs below are planning references, not extra issues or claims of work in progress.
- **One active UX slice.** Finish its behavior, failure states, design source, old-code deletion and proof before opening the next visual redesign. An independent engine/hardware task can proceed if it has a separate boundary.
- **Four distinct facts:** design approved, code present, journey reachable, appliance verified. A method or a merged PR does not prove the last two.
- **One current design.** `segno-ui.pen` owns accepted screens and rationale. Historical plans explain decisions; they do not compete as implementation queues.
- **Every slice ends with a demonstration and a removal list.** The issue links its current PR, exact tested revision, result and remaining device gate. Changes of direction record what they supersede and why.

Audit baseline: `aaf042655b5059d9aff7c647a02249c1d019de84`, with existing working-tree changes preserved. [Verification and limitations](../research/segno-looper-x-comparison/verification.md) distinguish static inspection, the macOS navigation check and work still requiring an appliance.

### Session Library UX accepted — 2026-09-07

The [New Loop and session recall flow](../design/2026-09-07-session-library-ux.md)
was accepted by the owner after testing in the main prototype. It preserves the previous session before
emptying tracks, carries the sound setup forward, and explicitly reopens a selected
session with playback stopped. Sessions and Audio share Library navigation. This
is browser-state evidence, not completion of faithful appliance recall or autosave.

**Record performance — proposal ready:** [Continuous Main-output capture](../design/2026-09-07-performance-recording-ux.md)
adds touch/encoder and assignable foot Start/Stop, a persistent recording indicator,
automatic take naming, Audio Library discovery and interrupted-take recovery.
Stopping capture preserves loop/backing playback. Chrome and Firefox validate the
silent lifecycle; real audio capture, durable recovery and appliance validation
remain implementation work.

**USB export — owner accepted:** [Export selected recordings](../design/2026-09-07-audio-usb-export-ux.md)
copies finished internal audio to USB, keeps the source, and handles matching
filenames, cancellation, absent/removed media and failed writes. The main prototype
and Chrome/Firefox checks cover the flow; actual USB I/O and durable completion
remain appliance work.

**Input setup — owner accepted:** [Input setup and routing](../design/2026-09-07-audio-routing-ux.md)
adds shared input aliases, adjacent stereo capture, mono Pan, stereo Balance and
recording trim. The routing proposal keeps capture choices separate from live,
track, backing and click output sends. Eighteen-input navigation, session recall,
encoder/touch editing and failed writes pass in Chrome and Firefox. Audio routing,
gain and metering remain simulated until engine and appliance implementation.

**Output setup — proposal:** [Named outputs and controls](../design/2026-09-07-output-setup-ux.md)
adds level, balance, mute and stereo/mono per destination, with shared FX/routing
names. The capture tap before final listening controls is explicitly proposed.
[Pedal mapping catalogue](../design/2026-09-07-pedal-mapping-catalogue.md) records
all current action choices, parameter targets and missing or undefined mappings.

**Tuner — owner accepted:** [Tuner performance](../design/2026-09-07-tuner-performance-ux.md)
adds input selection, temporary live mute, A4 reference changes/reset and Exit by
foot. The note/cents display is simulated. Both browsers verify input paging,
mono/stereo monitoring isolation, persistence, session recall and failed writes.

**External function access — proposal:** [External function assignments](../design/2026-09-07-external-function-assignments-ux.md)
offers 35 choices grouped as Functions, Tracks and FX pedals. Completed modes and
New loop/Record performance share built-in dispatch; unfinished general transport
and loop-mode conversions remain explicit gaps. The paired Pen galleries preserve
the accepted Tuner and distinguish the new assignment proposal.

**Performance gesture feedback — proposal:** [Hold progress and FX contacts](../design/2026-09-07-performance-feedback-ux.md) add feedback at the existing pedal positions, without extra focus stops or another overview. Chrome/Firefox and paired native Pen checks pass.

**Main Stage and two displays — revised proposal:** [Display roles and track views](../design/2026-09-07-stage-display-roles-ux.md) now uses four tall columns from the active bank, Segno’s state colors, a top-bar view menu, and a selected-track waveform on the small display. The earlier eight-card grid is rejected and archived. [Interactive recording](../design/2026-09-07-stage-recording-ux.md) now connects capture, per-pass Undo/Redo, queues and inline Mute in the silent study. Physical display validation and production transport remain open.

MIDI setup now has a [reviewed interactive design](../design/2026-09-07-midi-controls-ux.md) for Learn, multi-target control, ranges, button states and reconnect behavior. [Clock & sync](../design/2026-09-07-midi-sync-ux.md) now has an owner-approved UX reference. Hardware MIDI implementation remains separate. [Wave performance](../design/2026-09-07-wave-performance-ux.md) now has an interactive proposal with phrase landmarks, capture growth and direct pedal entry. Existing-audio mode changes are next.

**Wave — owner accepted:** [Continuous waveform view](../design/2026-09-07-wave-performance-ux.md) uses real reference-audio peaks on both displays, separated bar/layer readouts and an FX indicator at the edge. Browser and Pen verification pass. Live capture and production waveform projection remain implementation work.

**Wi-Fi setup — owner accepted:** [Network UX](../design/2026-09-07-network-ux.md) adds joining, saved networks and connection recovery under Settings → Network. The browser study simulates connectivity; Linux service integration and appliance validation remain. Empty channel names display Track N, Input N and Output N consistently.

**Displays — owner accepted:** [Display settings and touch calibration](../design/2026-09-07-display-settings-ux.md) follow the physical left-to-right arrangement. Independent brightness, idle dimming, calibration verification and recovery pass in both browsers. Physical backlight and touch-controller integration remain appliance work.

**Storage — owner accepted:** [Capacity and safe USB eject](../design/2026-09-07-storage-ux.md) share media availability with the Audio Library. Busy transfers, cancel, failure/retry and disconnect preserve internal audio; browser checks pass. Native disk operations and file cleanup remain open.

**Power — owner accepted:** [Safe shutdown and restart](../design/2026-09-07-safe-power-ux.md) finish recording and save before shutdown, with Stay on and Retry after failures. Actual OS power control remains separate.

**Updates — owner accepted:** [Software updates](../design/2026-09-07-software-updates-ux.md) separate availability checks, preparation and explicit safe restart. USB verification and prior-version recovery have tested simulated paths. Real package verification, installation and boot rollback remain appliance work.

**Session backup — owner accepted:** [Whole-session USB backup and restore](../design/2026-09-07-session-backup-ux.md) includes loops, effects, routing, pedals and backing audio. Restore adds an independent session to Library. The Library waveform preview is accepted; USB copying and audition remain simulated. Durable appliance recovery remains production work.

**Backing playback — proposal:** [Seek and end behavior](../design/2026-09-08-backing-playback-ux.md) adds a direct position control, foot-operated ten-second jumps and Stop/Repeat/Next. Audio remains simulated.
