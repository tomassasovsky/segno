# M3.16 simplicity review — model/UI and root composition

No actionable findings in the reviewed scope.

## Assessment

The implementation adds one typed target and one reusable four-choice endpoint widget. It retains the existing normalized mapping envelope, draft ownership, button conditions, and expression/MIDI behavior controls. It does not introduce a second mapping interpreter or a Hear click-specific persistence store.

The widget's small local focus/opening-value state is necessary to restore exact authored endpoints on Escape. Mapping semantics and audio admission remain with existing owners. A nullable confirmed readout solves selection during recovery across page lifetimes without a page-local historical cache.

Composition reuses the shared Click owner and serial gate for mode plus volume. The prior volume-only gate name is replaced at callers; no compatibility alias remains in this partition. Startup and Session use explicit mode values and durable projection rather than a fallback inferred from a provisional transport read.

Fixture changes are confined to supplying the required owner or coherent accepted state. No assertions were removed to make the new readiness contract pass. The fault-store changes deliberately distinguish a compensated ordinary refusal from a failed rollback that actually requires recovery.

No speculative abstraction or mandatory broad refactor is recommended. Existing production fakes, AudioEngine seams, and generated bindings remain project-authorized boundaries, not deletion candidates.

## Review binding and independence

Base: `3025840dd212a86ee1b23c21b6980f0ac4866e20`. Reviewed source-set fingerprint: `9a4c7b6a794a71d7cf33e244e6e6834a32294d4add98a7f7ef07f43b1dda58b1`. The exact 70-file SHA-256 table is in [the VGV report](vgv-model-ui.md#source-binding).

One reviewer applied the four role definitions sequentially. This reviewer authored the runtime/native partition and does **not** certify that partition here. This is an independent review of the other authors' model, presentation, composition, and associated tests, including the final confirmed-selection and endpoint-editor changes. No tests, product edits, or delegation were performed for this review.

The governing behavior is [the approved Hear click plan](../../../plan/2026-10-03-shared-hear-click.md). Whole-candidate bug review, independent execution, final aggregate/static checks, CI, and commit binding remain the coordinator's gates. This report does not assert merge readiness. Pen and golden rendering are separate author visual evidence; screenshot-generator source was reviewed, pixels were not independently revalidated here.
