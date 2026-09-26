# Segno implementation handoff

Implement the accepted Segno product design throughout the existing Flutter/Linux application. This is an implementation task, not another redesign exercise. Start with a working vertical slice and grow from it until the authorized work is complete. Preserve a usable app after every slice.

## Context and authority

The owner and design agent developed and reviewed the interactive prototype over many iterations. The accepted UX defines the target features and behavior; current production code identifies reusable foundations and gaps. Do not remove a feature because its API does not exist yet. Do not copy the browser simulator's architecture into Flutter or ship its fake telemetry, media, USB, MIDI or recovery as real behavior.

Read these first, relative to the repository root:

1. `AGENTS.md`, the build/test section of `docs/PROGRESS.md`, and `docs/TRACKING.md`.
2. `docs/handoff/segno-app/README.md` and `delivery-checklist.md` for the delivered state and transfer checks.
3. `accepted-behavior.md`, `implementation-map.md`, and `reference-gates.md` in that same handoff directory.

Then load only the design records and code needed for the active slice. The behavior contract links the full context. Exercise `docs/design/fx-ux-prototype.html` and inspect its shared modules, accepted current sections in `segno-ui.pen`, and the relevant walkthroughs. Normal startup is Tracks. Use the dated acceptance records to resolve conflicts: later owner corrections outrank older proposal prose, rejected Pen frames and implementation limitations. Do not reopen settled choices. If two current authoritative sources truly conflict, identify the exact conflict and ask one focused question while continuing independent work.

The working design contains untracked files. Verify the supplied manifest before assuming a clone or branch contains it. Preserve unrelated edits; stage explicit owned paths only when publication is authorized. Inspect `.pen` through Pen's supported tools. Do not treat it as JSON or reconstruct it from an approximate screenshot.

## Product invariants

- Main display: four tall track columns for the active bank, one full-width whole-track level representation, state-driven color, compact bars/layers/FX and bottom progress. No duplicate per-track BPM, dBFS or routine status labels. Queued/recovery cues belong within their track and must fit. Track/Wave/Mixer choices sit behind a top-bar icon. The left, smaller display follows the selected track's waveform. The first completed recording gets the primary crown; mere selection does not move it, and an empty session has none.
- Keep the accepted blue-gray controls on dark surfaces, shared typography, consistent padding and encoder focus. State colors carry musical meaning. Use existing custom artwork and the real ten-pedal faceplate layout. Bottom keyboards are fixed sheets with explicit completion/cancel controls, not scrolling or outside-tap-dismissable dialogs. FX parameters have a persistent separated scrollbar; double-tap restores a parameter default.
- Recording, overdub, playback, quantized queues and one-layer-per-pass history share one domain owner. Partial audio retains its loop span and unwritten silence in Multi; recovery does not switch to Free. Undo/Redo, Clear All, Peel, length edits and Bounce follow the accepted atomic and per-track contracts.
- Every performance function entered by foot is operable and escapable by foot. Configurable navigation/control Press/Hold pairs are exclusive; normal Record/Play, Stop and track selection retain their defined immediate-contact behavior. Mode defaults to Mute on Press and Custom on Hold. Track Mute stays in the main view. LED colors are editable; light follows latched or momentary state. Touch, encoder, built-in pedals, external controls and MIDI reach the same actions and values.
- Inputs, tracks, All tracks and selected outputs have distinct routing/FX roles. Input/track Pre prints into recording; Post processes downstream. Output FX has no placement selector. Stop, Clear, Mute, bypass, Cut sound and finite rendering have settled tail rules in the behavior contract. Mixer input level controls live monitoring, not the recorded take.
- Instruments are independent routable inputs, played through explicitly enabled controllers and shared mappings. MIDI note range is 0–127, not an on-screen octave. Mapping targets are stable across screen selection. Support chords, sustain, note release, source disconnect, audition/cancel and sound recovery. Record instruments through normal Tracks controls.
- Library, sessions, backing, capture, USB, backup, restore and recovery must preserve source identity and musical state. Staged repair, Cancel, publication failure and safe retry are real behavior, not success-shaped screens. Session state and physical appliance configuration have separate ownership as defined in the contract.
- Match Looper X racks, effects and exact parameter definitions; sound may differ. Do not infer reset defaults, range limits, enum domains or rack signal order from preset values or raw constructor arguments. Keep the evidence-gated portion explicit while implementing independent verified work.

## Execution

Use `implementation-map.md` to inspect existing seams. First implement the accepted Tracks view, bank/selection behavior, selected-track second display and crown against the existing transport and engine snapshots. Include recording, overdubbing, playback and meaningful error feedback in the working demo. Then follow the dependency-ordered slices for history/timing, routing/FX, controls, instruments, media and appliance integration. Reconcile dependencies against current code before editing; the sequence is a starting plan, not a reason to force a bad architecture.

Keep presentation → Bloc/Cubit → repository → data boundaries and use `AudioEngine` as the test seam. Protect the real-time callback from allocation, I/O and locking. Update native APIs and generated FFI bindings together. Reuse existing dependencies and domain infrastructure. Remove the obsolete path when a replacement slice is complete; avoid compatibility layers, parallel state owners or speculative abstractions.

Work autonomously within the established issue and approval scope. Do the concrete implementation and validation before requesting a genuinely required approval. Follow repository stage, review, CI and hardware gates. Do not infer deployment, flashing or merge permission from design acceptance.

Batch independent reads and checks; keep dependent changes sequential. Delegate bounded independent work only if the host and current task authorize it, and keep useful integration work moving locally. Make targeted edits and add tests for meaningful behavior and failures, not source-text mirrors or unrelated cleanup.

For each slice, demonstrate touch/encoder/foot/MIDI paths that apply, cancellation, release, persistence and failure recovery. Run the applicable repository format, analyze, Bloc lint, unit/widget/native/firmware and CI checks. Visually compare actual app screens at both display sizes with the accepted designs. Prototype Chrome/Firefox checks are reference evidence, not production proof. Report hardware-unverified behavior honestly.

Keep a durable implementation ledger containing decisions, changed files, observed checks, unresolved findings, true blockers and the exact next step. Preserve these through compaction. Give concise updates when a result or blocker changes, and finish with a self-contained report and a runnable demo or recording of the actual app slice. Do not stop at a plan or say work is complete because a UI draws successfully.

Begin by validating the handoff files, inspecting the first slice's existing code, recording its observable acceptance criteria and then implementing that slice.
