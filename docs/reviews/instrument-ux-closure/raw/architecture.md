## Architecture Review

### Scope and stack

Reviewed the instrument closure plan and its eight-finding UX review against the current working files. This is a plain JavaScript/HTML design prototype; the surrounding product is a Dart/Flutter layered monorepo. The prototype does not call Dart repositories, native clients, or FFI directly. Applying Bloc package conventions to these browser studies would be inappropriate.

Read the project instructions, build/test guidance, tracking contract, dependency manifest, and analysis configuration. Limited implementation review to instrument-runtime.js, instrument-catalogue.js, virtual-instruments.js/.css, instrument host integration in fx-ux-prototype.html, and the instrument changes in the shared action, pedal, external-switch, expression, and MIDI studies. Unrelated dirty and untracked files were excluded.

### Layer Separation

- Violations found: 0.
- The catalogue defines sounds, defaults, and parameter descriptors. The runtime owns voice, sustain, controller, expression, and audition lifecycles independently of the inspected instrument.
- The instrument study renders controls and uses injected host callbacks for shared routes, persistence, destinations, and assignment editors.
- The main HTML host composes shared studies and owns rig/session persistence. The shared dispatcher resolves a stable action identity and delegates execution to the instrument host.
- Clean files: all scoped files checked.

### State Management Assessment

- Instrument runtime: Correct. Instrument IDs and source tokens own notes; selection does not redirect existing voices. Configuration changes retire the affected controller, and disconnect removes only the relevant device's ownership. Pending audio starts check ownership again after asynchronous unlock.
- Instrument editing: Correct after review fixes. Encoder previews now overlay the current saved model for rendering and synthesis without publishing the draft. Incoming MIDI rendering preserves the preview, and selection/modal actions discard the edit before changing the active surface.
- Shared assignments: Correct after review fixes. Dynamic catalogues preserve instrument IDs through rename and remove deleted targets from new-assignment choices. Release callbacks and source cancellation remain owned by the shared gesture systems.
- Audition: Correct. Temporary patch selection and voices are runtime state; persistent instrument definitions remain unchanged. Ending audition releases its voices and restores normal patch updates.
- Session and parameter targets: Correct in the checked integration. Parameter identity includes instrument ID and parameter key. Snapshot target enumeration uses snapshot definitions, and parameter persistence addresses that instrument in the target rig.

Resolved during review:

1. A held instrument Press paired with a separate Hold action dispatched only after short-press release, immediately releasing the note before asynchronous synthesis could begin. Built-in and external editors now prevent incompatible pairings and explain the required correction; existing invalid drafts cannot be saved. Held actions remain available as Hold assignments.
2. Encoder sound edits changed only the local UI clone. Incoming MIDI caused a host render that restored the saved value, and synthesis never received the draft. A runtime-visible draft overlay now preserves the preview across rendering without changing saved parameters. Chrome reproduction changed Brightness from 52 to 62: after incoming MIDI, the display and synthesized voice both remained 62 while the saved model remained 52.
3. Selecting drums while editing Brightness left an encoder edit referring to a missing control, causing a null-value exception on the next turn. Selection now cancels the draft; the same interaction completes without an exception and leaves the original saved Brightness unchanged.
4. Note latch state included voices sustained after their gate was released. With sustain enabled, the third latch press attempted to release again instead of retriggering. The corrected path distinguishes unheld gates from sustained voices; the third press starts a new unsustained voice while the earlier sustained voice remains.
5. MIDI allowed held instrument actions on Released or Program Change, which dispatched and released in one event and produced no voice. Saving now requires a momentary Note/CC source with a Press trigger and gives a specific explanation. A browser check confirmed that changing Released to Press makes the draft saveable.

### Dependency Direction

- Direction violations: 0.
- Catalogue → runtime is the sole module-level sound dependency. The runtime receives instrument definitions, routes, ports, and audio hooks through its host interface.
- Shared studies depend on action/parameter descriptors and dispatch callbacks, rather than importing instrument presentation state.
- No circular module dependency or new package dependency was introduced in the reviewed scope.

### Package Structure

- Browser prototype: Complete for this scope. Sound definitions and runtime behavior have dedicated modules and focused verification scripts. No production package was added or changed by the instrument work.

### Verification

- Ran `node docs/design/verify_instrument_runtime.cjs`: passed.
- Ran `node docs/design/verify_instrument_shared_controls.cjs` after the pairing fixes: all 12 contracts passed.
- Independently exercised Chrome browser reproductions for encoder preview/render/runtime propagation, selection during editing, notes latch under sustain, and the invalid MIDI held-release assignment guard. All final targeted checks passed.
- The runtime preview check used an injected synthesis seam to inspect actual voice parameters; it does not claim physical audio or MIDI validation.
- Complete cross-browser journey checks and visual/Pen verification remain the caller's separate validation evidence.

### Verdict

Architecture is clean for the scoped working revision. No unresolved actionable findings remain from this review.
