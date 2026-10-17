# M3.16 test-quality review — model/UI and root composition

No actionable findings in the reviewed scope.

## Behavioral evidence reviewed

- Model tests assert the literal 0 / 2 / 1 / 3 native choices, normalized ordering and thresholds, strict target identity, availability, capture lock, and named readouts. They distinguish explicit Off from an unavailable owner.
- The shared endpoint widget test uses a stateful parent, changes the draft, sends Escape, and checks restoration of the exact original `.2`. Real button/expression/MIDI page cases then save and inspect persisted endpoints; repair preserves `.2/.8` instead of silently canonicalizing them.
- Loop Tempo tests cover confirmed Off, disabled capture state, no initial provisional selection, and recovery selection after navigating away and reopening. These exercise owner-visible state rather than a page-only remembered value.
- Bootstrap tests cover both startup routes and every stored native code, absence without materializing the scalar, invalid type/range preservation, pending-read no-open, native refusal, and unconfirmed replay. The fake has an explicit unpublished receipt path instead of treating every enqueue as acceptance.
- Actual App tests prove persistence waits, persistent startup Retry, malformed-value preservation, compensated-refusal shutdown, uncertain rollback refusal, Keep Playing, and actual MIDI Held cleanup both before and during shutdown. They assert no halt/stop on refusal, no new command after cutoff, and accepted Released mode before successful halt.
- Real-native Session tests inspect saved files and actual native mode while Held. Save As and Save both preserve Released; changing volume from `.4` to `.7` proves the second Save rewrites the file. Pending storage delays capture, and explicit Off recall does not rewrite the startup preference.
- Mechanical legacy changes add the required unavailable port or explicit durable mode/gate. Existing unrelated expected values remain intact. The common fake's receipt fields are propagated through snapshot wrappers, while real native behavior remains separately exercised.

## Removed-invariant audit and execution boundary

The prior Click-volume fault fixture rejected before mutation, so it could not prove unresolved compensation. The revised fixture mutates then throws and can refuse removal; existing recovery assertions now exercise a real owed recovery. Session recording setup pumps until an actual playing state and asserts it, replacing a zero-frame assumption. Neither change weakens the expected behavior.

Screenshot generators are author-only visual evidence. Their source assertions and coherent accepted-mode setup were reviewed; they do not substitute for CI behavior tests. The workflow adds native-backed Click Session coverage to the existing native job. The existing native fuzz route covers the separate runtime expression dispatch case, which this reviewer authored and does not independently certify here.

The coordinator reported the touched App/bootstrap/native Session run at 161 passing with six conditional skips, and the model author reported the confirmed-selection widget run at 40 passing. Those are producer execution results, not tests rerun by this reviewer. Earlier failed attempts remain in the private evidence. Final full-candidate execution and coverage must be bound by the coordinator before readiness is declared.

## Review binding and independence

Base: `3025840dd212a86ee1b23c21b6980f0ac4866e20`. Reviewed source-set fingerprint: `9a4c7b6a794a71d7cf33e244e6e6834a32294d4add98a7f7ef07f43b1dda58b1`. The exact 70-file SHA-256 table is in [the VGV report](vgv-model-ui.md#source-binding).

One reviewer applied the four role definitions sequentially. This reviewer authored the runtime/native partition and does **not** certify that partition here. This is an independent review of the other authors' model, presentation, composition, and associated tests, including the final confirmed-selection and endpoint-editor changes. No tests, product edits, or delegation were performed for this review.

The governing behavior is [the approved Hear click plan](../../../plan/2026-10-03-shared-hear-click.md). Whole-candidate bug review, independent execution, final aggregate/static checks, CI, and commit binding remain the coordinator's gates. This report does not assert merge readiness. Pen and golden rendering are separate author visual evidence; screenshot-generator source was reviewed, pixels were not independently revalidated here.
