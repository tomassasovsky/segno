# Shared Record length

Touch, MIDI and External buttons/expression share confirmed Record length for
Loop defaults and fixed Tracks 1–8, including empty tracks. Auto and 1–64 bars
use musical labels. Explicit Auto remains Custom; Use default removes only the
override. Multi uses the shared default while retaining other modes' overrides.

Held values stay live; Save and restart preserve authored Released choices.
Capture blocks length changes without stopping the take. A release refused
during capture remains owed and retries when safe. Uncertain receipt or storage
failure requires explicit recovery; shutdown stays on until resolved.

The [plan](../../plan/2026-10-01-shared-record-length.md),
[verification](verification.md), [source binding](source.json),
[design binding](design.json) and [review](review.md) define this slice.
Published-head CI and human merge approval remain separate. Other shared loop
controls, hardware proof and full live-controller Session Load remain open.
