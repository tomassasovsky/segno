# M3.16 architecture review — model/UI and root composition

No actionable findings in the reviewed scope.

## Cross-file traces

1. `ClickModeValueTarget` parses exactly the canonical key and maps normalized endpoints to named choices. Resolver/catalogue receive a nullable owner snapshot; saved structurally valid rows remain repairable while new selection/admission is unavailable. Capture disables editing without redefining target identity.
2. Button, expression, and MIDI endpoint editors update only their parent drafts. New button endpoints use the accepted current value; expression and MIDI preserve their existing full ranges. Repair preserves authored endpoints. Save does not route an audio command through the widget.
3. Loop Tempo reads `confirmedClickMode` for selection and the nullable snapshot for availability. The presentation layer does not manufacture an Off value during initialization or reinterpret recovery as readiness.
4. Startup stages the strict mode checkpoint before opening the device, uses First recording only for absence, and awaits confirmed replay after either audio-start route. A bad scalar or failed replay prevents successful startup without overwriting the stored value.
5. App owns the shared Tempo instance, failure subscription, and disposal. Session Save/Save As obtains the durable mode inside the shared Click gate in the existing Mixer → Click → Playback → Length → Timing order; it does not serialize the audible Held mode. Performance audio capture remains outside this preference projection.
6. Shutdown first retires controller ingress and awaits cleanup. Initial owed-cleanup failure blocks halt; explicit Retry recovers owners and must pass a second controller flush before final owner flushes and halt. Keep Playing restores actionable recovery presentation. Controller shutdown debt is not inferred from an ordinary edit's last outcome.

## Boundaries

The pure port and runtime implementation were read only as caller contracts; their correctness is covered by the separate reviewer and adversary. Native callback receipt/publication, reservation width, and DSP audibility are outside this author's independent certification. The public plan explicitly records the absent frozen-capture-journal producer as a later dependency, rather than adding a fabricated UI flag.

## Review binding and independence

Base: `3025840dd212a86ee1b23c21b6980f0ac4866e20`. Reviewed source-set fingerprint: `9a4c7b6a794a71d7cf33e244e6e6834a32294d4add98a7f7ef07f43b1dda58b1`. The exact 70-file SHA-256 table is in [the VGV report](vgv-model-ui.md#source-binding).

One reviewer applied the four role definitions sequentially. This reviewer authored the runtime/native partition and does **not** certify that partition here. This is an independent review of the other authors' model, presentation, composition, and associated tests, including the final confirmed-selection and endpoint-editor changes. No tests, product edits, or delegation were performed for this review.

The governing behavior is [the approved Hear click plan](../../../plan/2026-10-03-shared-hear-click.md). Whole-candidate bug review, independent execution, final aggregate/static checks, CI, and commit binding remain the coordinator's gates. This report does not assert merge readiness. Pen and golden rendering are separate author visual evidence; screenshot-generator source was reviewed, pixels were not independently revalidated here.
