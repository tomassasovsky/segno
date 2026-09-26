# Closing the Looper X comparison

Status: closure programme authorized for the next design pass, September 8, 2026. This reconciles the
183-row audit after the first prototype correction pass and the owner's
duplicate-enable refinement. It extends the existing appliance roadmap under
[the console redesign issue](https://github.com/tomassasovsky/segno/issues/919).
Its verified labels remain `stage:plan` and `autonomy:plan-gate`. Existing
authorization covers the prototype and design work; this document does not
claim production implementation, a new merge gate or physical verification.

The next local pass is recorded in [the design closure report](../design/2026-09-08-audit-closure-pass.md). The table below records the starting inventory; current dispositions and counts live in the closure table and summary. Production and unresolved behavior choices retain their own gates.

## What another pass can close

We should do another pass, with two separate completion goals:

1. **Design completion:** every adopted capability has a coherent entry,
   interaction, state, exit, failure and recovery path. The main prototype and
   Pen agree. Controls describe real intended behavior; a normalized placeholder
   does not count as a finished musical control.
2. **Product completion:** the approved behavior runs in the Linux application,
   processes real audio, survives persistence and recovery, and passes the
   applicable appliance tests. The old implementation is removed in the same
   delivery slice. macOS remains a development launch target only.

The previous correction pass completed specific prototype fixes. It did not
finish every UX gap or certify the entire instrument. In particular, complete
MIDI action dispositions do not cover every function-menu shortcut, exposing
all FX keys does not resolve their physical scales, and session backup is not
complete appliance backup.

## One record per audit item

The [closure table](../research/segno-looper-x-comparison/2026-09-08-recheck/closure-items.csv)
contains all 183 original IDs, their current design disposition, next gate,
work package, remaining work, evidence and an observable closing test. The
[JSON version](../research/segno-looper-x-comparison/2026-09-08-recheck/closure-items.json)
contains the same records. The original feature ledger remains unchanged.

| Next gate | Audit rows | Meaning |
|---|---:|---|
| Prototype work | 10 | A concrete user-facing gap remains and can be developed locally. |
| Behavior decision | 21 | Several rows share one unsettled contract; these are not 21 separate questions. |
| Reference or measured evidence | 7 | Exact FX semantics, algorithm quality or factory audio is not established. |
| Optional scope decision | 4 | Inclusion is not established by the accepted Segno direction. |
| Hardware capability/verification | 14 | Menus cannot establish these capabilities. |
| Production implementation/verification | 127 | The next step is the actual product path or its proof; this does not mean 127 features are wholly absent. |

These counts describe the **next** gate, not independent effort estimates.
Once a decision or prototype gate closes, its row still needs production proof.
Existing positive browser evidence is retained, not silently promoted to audio
or hardware evidence. This planning pass ran no new native or browser suites.

An item may finish as verified Segno behavior or an explicitly accepted
difference. A feature excluded by the owner has a recorded scope decision, not
a claim of implementation. Deferred work and unavailable hardware stay open.
There is no requirement to undo accepted improvements just to duplicate the
reference: eight tracks, ten pedals, recoverable Peel, selected-track Divide,
direct editing, two displays and the agreed monitoring semantics remain.

## Next design pass

Keep the accepted visual language and work in the following small journeys.
Each ends with a demo in the main prototype, matching Pen references and a
focused regression check. These packages are a view of the existing issue's
scope, not new parallel issue trackers.

| Package | Work | Files and closing demonstration |
|---|---|---|
| D1 — Track and mix context | Track rename from the heading; click/backing access in the visual Mixer; Solo while editing track FX. | `docs/design/stage-display-study.js`, `fx-ux-prototype.html`, existing bottom keyboard and shared mix targets. Rename an off-bank track; change backing/click mix; Solo a track from its effect editor and return. All views share values and focus. |
| D2 — Complete foot controls | Transpose bypass without reset; clear custom assignments; all five loop-mode shortcuts; explicit Solo LED priority. | `pedal-action-catalogue.js`, `mapping-action-dispatch.js`, `pedal-performance-study.js`, `transpose-performance-study.js`, `pedal-ux-study.js`. Complete each action and confirmation by foot, preserving bank, target and recoverable values. Mode shortcuts depend on D3's rules. |
| D3 — Recording and clock contract | Primary-track selection/feedback; fine BPM; first-take inference; count-in scope; legal Sync/Band closures; partial Redo and active Clear All. | `loop-ux-study.js`, `stage-transport-study.js`, `midi-sync-study.js` and main host adapters. Demonstrate the approved matrix across all modes, with early/late presses, click on/off, external clock and interrupted capture. |
| D4 — Sound contract | Meaningful FX descriptors; preset audition/cancel; track Mono/Stereo; one routing/render contract; collection versus active DSP limits. | `fx-parameter-descriptors.js`, `fx-parameter-controls.js`, `fx-preset-library.js`, `audio-routing-study.js`, Bounce and capture studies. Use left/right and delay/reverb examples to make what is recorded versus heard explicit; verify musical choice labels against source evidence. |
| D5 — Complete Library and recovery | Internal/USB preset interchange; full appliance backup; remaining recording time; session/global ownership; one repair-and-return journey. | `session-library-study.js`, `audio-library-study.js`, `fx-preset-library.js`, `storage-study.js`, source-owned controls and main navigation. Restore contrasting sessions and a whole-appliance bundle, repair a missing target, and preserve state on cancel/failure. |
| D6 — Scope and supporting evidence | Factory audio collection; optional double-press Solo, expanded MIDI protocols, direct removable recording and screen lock. | Reference inventory and existing accepted design records. Exhaust available source evidence first, then present only actual scope choices or missing evidence to the owner. |

The ten immediate prototype rows are LX-003, 028, 038, 063, 075, 084, 089, 095,
168 and 181. They are not the whole remaining design scope: the decision and
reference groups supply the rest. Prior correction suites should be extended
at the relevant seams, not replaced with tests that only count controls.

## Decisions to resolve through concrete proposals

These recommendations are proposals, not new accepted behavior. Present them
in the affected journey rather than asking the owner to design an audio engine.

- **Recording:** show a primary marker and an intentional change action; derive
  new capture boundaries from one approved mode/clock matrix. Preserve the
  accepted immediate partial-take Redo intent. The owner settled the distinction:
  partial audio occupies its recorded region inside the established Multi cycle,
  with silence elsewhere. This now has [prototype evidence](../design/2026-09-08-capture-recovery-ux.md), without changing mode or interrupting other tracks. The active Clear All proposal demonstrates how it freezes
  partial audio and how Undo restores it without accidentally recording again.
- **Processing:** settle the tap/order table for live input, input/track Pre,
  recorded parts, track Post, all-tracks mix, backing/click, output FX, audition,
  Bounce, file export and performance capture. Include the distinction between
  a stopped loop and a live input still feeding a reverb. Adopt one result across
  the UI, render worker and engine.
- **Presets and capacity:** audition should have an exact Cancel restoration
  point. Logical rack count remains independent of the eight FX assignments;
  finite simultaneous DSP and file-package limits require measured, documented
  budgets. The current 128-effect/256-preset package caps are not an approved
  substitute for the owner's unlimited collection requirement.
- **Ownership and backup:** musical values and session target associations
  should recall together; physical identity/calibration should not be replaced
  by another appliance's values without an explicit restore choice. Preserve
  accepted session pedal setup. Resolve the broad prototype snapshot versus
  device-global plan disagreement before introducing production schema fields.
- **Optional features:** retain direct assignable Solo and managed internal
  recording while deciding whether double-press Solo, extended MIDI protocols,
  direct USB/SD recording or touch lock earn a place. Deferring one must be an
  explicit scope decision, not a hidden disabled option.

## Source and equipment needed

For exact FX parity, finish the local metadata/runtime investigation before
requiring owner input. Factory values alone cannot reveal legal ranges, enum
labels, parameter curves or equivalent DSP. If the extraction cannot supply
them, use access to a Looper X or reliable captured parameter sweeps, defaults,
screen choices and audio measurements. Record which facts come from the guide,
QML, presets and actual runtime, including their version differences.

The advertised 300-plus factory loops also need actual usable files and an
agreed content inventory. The current demo recordings are not that collection.
The choice of an alternative Segno collection would be a documented product
difference, not source parity.

Hardware proof needs the assembled Linux appliance, both displays, current
RP2350 console, chosen audio interface, external pedals, MIDI equipment and
USB storage. Establish actual Phones routing, preamp/phantom controls and
simultaneous input capacity. For computer USB audio/Transfer, first prove an
accessible device-mode controller in the final power/data topology; an attached
USB host interface does not provide it. If these capabilities are desired but
the current hardware lacks them, hardware changes or a scope decision are needed.

## Production sequence

Use the existing [audio/state implementation plan](2026-09-08-audio-state-parity-plan.md)
and correction documents as the detailed specifications. Resolve their noted
ownership and timing questions before building the dependent slices.

| Package | Depends on | Smallest complete delivery and proof |
|---|---|---|
| P1 — Canonical session and history | D3/D5 field and recovery rules | Extend existing session/rig mapping and staged engine commit. A failed load never clears the live rig. All five modes, audio revisions, per-pass/grouped Undo/Redo, musical settings and approved bindings round-trip. |
| P2 — Musical transport and transforms | P1, D3 | Implement agreed mode clocks, inference, quantization, per-track Once/decay, reverse, length edits, speed, transpose and fade. Test actual frames, phase and history, not only enum/state values. |
| P3 — Processing and mix | P1, D4; P2 where retiming is used | Implement typed FX and canonical graph, stereo/pan/Solo, printed Pre, continuing Post/output tails, tuner audition and common render taps. Demonstrate real signal isolation and the agreed reference-quality limits. |
| P4 — Managed media and durability | P1, P2/P3 for adapted/wet media | Real decode, waveforms, tempo analysis, independent backing player, Bounce/export/capture and complete backup. Power loss produces a valid previous or committed new state, never a success screen over incomplete data. |
| P5 — Shared physical controls and MIDI | P1–P3 command contracts, D2, H1 capability | Touch/encoder/feet/expression/MIDI invoke one command owner. Verify device identity, target ranges, direct versus mode actions, release/rebind, clock send/receive/Thru and measured timing. |
| P6 — New application UI and appliance services | Each corresponding working domain | Connect each approved design to Bloc/repository/engine. Remove its old routes/widgets/schema paths immediately. Reuse current network/update/display/storage services and keep macOS development launch. |
| H1 — Capability and release verification | Begin feasibility now; prove integrated slices as they land | Confirm interface/console topology and capacities, then test real contacts, two-screen ergonomics, MIDI jitter, latency, CPU/memory/storage, updates, hotplug and power loss. Unsupported hardware never reports success. |

P6 runs alongside each working domain; do not wait until all engine work is done
to create one giant UI rewrite. Likewise, hardware feasibility starts early so
we do not design around impossible ports. Every slice keeps a playable product
and removes its predecessor. Reuse existing owners from the
[reconciliation register](../research/segno-looper-x-comparison/reconciliation.md),
checking their current state before starting; do not duplicate the controller,
factory-FX, session or capture programmes.

## Closure evidence and review

Each delivery links its audit IDs and records: accepted behavior, final
implementation revision, focused user journey, failure/recovery results, native
and Flutter checks where applicable, real-device evidence where required, and
removed predecessors. Independent review must apply to that final revision.
A screenshot, a named menu action or an old passing suite alone is insufficient.

This plan is locally reconciled, not independently technically approved. The
attempt to dispatch a native closure-review agent could not run because the
current task's agent-thread capacity was exhausted; the coordinator completed
the row inventory directly. No delegated review result is claimed.

## Success Criteria

```success-criteria
GOAL: Every Looper X audit item has a traceable, tested Segno outcome or an explicit owner-approved difference or exclusion, with unfinished work visible.

SUCCESS CRITERIA:
- The closure inventory contains every original audit ID exactly once, preserves the baseline and links concrete work and evidence. | verify: python3 docs/research/segno-looper-x-comparison/2026-09-08-recheck/verify_closure.py
- Every adopted design journey is usable through its required touch, encoder and foot paths, including cancel, failure and return; Pen agrees. | verify: manual Review each row against the main prototype and saved Pen reference; record approval and exact browser checks for that revision.
- Each production slice retains a working instrument and removes the replaced implementation. | verify: manual Review the slice's removal list and applicable AGENTS.md/CI commands; run the Linux product path and macOS development launch where affected.
- Audio, timing, storage and hardware claims have repeatable appliance evidence at declared capacities. | verify: manual Run the row's closing test on the assembled appliance and record measured results, version and failures; compare Looper X only where exact reference equivalence is claimed.
- No item is marked verified merely because its scope is decided or its prototype exists. | verify: manual Check all proposed closures against their required evidence and preserve incomplete or hardware-blocked items as open.

NON-GOALS:
- Reversing already accepted Segno differences to imitate the reference.
- Desktop product support or a blanket engine rewrite.
- Treating this planning pass as native, audio, CI or hardware verification.

VERIFICATION COMMAND: python3 docs/research/segno-looper-x-comparison/2026-09-08-recheck/verify_closure.py
```
