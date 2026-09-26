# Recovery and remaining performance workflows

Local prototype delivery and owner acceptance completed September 9, 2026.
All six journeys and fifteen editable Pen references are accepted, including
the simplified connection review and recorded walkthrough. See the
[delivery record](../design/2026-09-09-recovery-expansion-delivery.md) and
[verification](../reviews/2026-09-08-recovery-expansion/review.md).

Issue: #919. The owner authorized all six prototype slices on September 8,
2026. This is local UX implementation authority, not production deployment or
merge approval. Existing accepted track, pedal, Library and settings layouts
remain the starting point.

## Scope and order

1. Recorded-loop audio recovery: identify the affected track/layer, find an
   intact original or backup, validate it, then open the session. A pending
   candidate must never mutate the live or archived session. Captured regions
   keep their position and silence within the loop timeline.
2. Physical audio connection repair: explicitly replace missing interface
   ports, preserving channel roles and stereo pairs. Show affected routes;
   apply only after the current interface and ports are revalidated.
3. Complete appliance backup: package all sessions, audio, presets and settings
   together. Validate the complete package and review restoration before
   replacing the current setup. Cancel and failed writes preserve it.
4. Primary-track timing: make the timing source explicit and permit a guarded
   handoff without silently resizing or stretching recordings.
5. Live preset audition: try a sound, then Keep or restore the exact prior
   sound. Navigation away cancels an uncommitted preview.
6. Long recordings and low storage: estimate remaining recording time from
   capacity and format; represent split files as one ordered take and finish
   safely when storage approaches exhaustion.

## Implementation

Reuse the existing `session-recovery-model.js`, `session-recovery-study.js`,
`session-library-study.js`, recording, routing and loop studies. Add isolated
models/studies where state has a distinct owner. The main
`fx-ux-prototype.html` supplies shared state, persistence and navigation hooks.
No parallel agent edits the main integration file. All changes remain silent
simulations; native manifests, audio bytes, device discovery and crash-safe
storage are later implementation requirements.

The existing Looper X comparison supplies reference boundaries (LX-009,
LX-080, LX-116, LX-171, LX-181); behaviors beyond that evidence are marked
Segno proposals. This work does not settle the still-open tail or recording-tap
policies by implication.

## Verification

Use focused pure-model tests and Chrome/Firefox journeys for each slice,
including cancel, stale choices, failed writes and reload. Run a combined
journey through shared session/transport state. Inspect real screenshots at
the established 1920 × 1080 canvas; import editable references into labeled
Pen sections, check geometry/text/focus, save and verify the on-disk file.
Run the five independent build review roles over their non-authored scope;
resolve findings before claiming completion. Preserve evidence under
`docs/reviews/2026-09-08-recovery-expansion/`.

```success-criteria
- Each of the six workflows is reachable from the accepted main prototype.
- Repairs identify what is affected and never silently substitute a port or recording.
- Cancel, unavailable media/device and failed persistence preserve the current setup.
- Recovered short takes retain their established loop length and silent regions.
- Preset preview can restore every prior FX parameter and assignment exactly.
- Primary timing changes never resize or stretch saved audio implicitly.
- Long takes remain a single ordered recording across file parts and safe stops.
- Browser verification, editable Pen references and proposal records agree.
```
