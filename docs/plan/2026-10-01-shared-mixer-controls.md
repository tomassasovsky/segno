# Shared Mixer control targets

Issue #1026. Follow-on to the reviewed MIDI setup and dispatch slice.
This is implementation scope within the accepted shared-control catalogue,
not a new settings page or a second controller interpreter.

## Behavior

MIDI and External buttons/expression use the same stable targets for track,
lane and live-monitor gain; track and input pan; linked-input pair balance;
and output level/balance. The existing FX and master targets remain available.
The editors show actual dB, left/center/right or output-percent values. Missing
coordinates stay unavailable and repairable without binding by label.

Stored endpoints and controller proposals remain normalized to 0–1. One shared
conversion maps that coordinate to the actual target domain. Track, lane and
live-monitor gain use the established Mixer fader law: zero is silence, and
positive travel spans −60 dB to 20 log10(2), with gain capped at 2. Unity is
approximately 0.90880725226 travel; half travel is approximately 0.04472135955
linear gain. The existing Mixer fader consumes the same pure conversion.
Pan/balance map 0–1 to −1–1; output level retains its existing linear 0–1 law.
Relative steps follow the existing control's travel/step, not an assumed
percentage of physical gain.

This corrects the still-unmerged TrackVolume target's incomplete range in the
current model. It does not introduce an obsolete-range alias, migration or
parallel target. Existing audible-value regression scenarios retain their
physical expectations by expressing fixture endpoints through the new scale;
separate literal vectors verify the scale independently.

## Ownership and admission

ControlCubit remains the shared source/action/holder owner. The existing
MixSettingsCoordinator accepts a typed batch, applies one native/durable mix
transaction, and returns confirmed acceptance. Failed or superseded writes do
not advance pickup, toggle, holder priority or saved state. Source identity,
session revision and device topology are checked again when queued work runs.

The coordinator projects authored Released values into all affected durable
mix fields while controls are held. Unrelated edits and session saves preserve
that projection. Ordinary Mixer edits, including explicit equal-valued edits,
notify the shared control owner only after acceptance. Mixer Reset covers its
existing track-level and pan scope. Pair unlinking or topology replacement
invalidates the affected old hold; a later coordinate with the same index must
not receive its stale release.

Live monitor gain changes what is heard; capture trim and existing recorded
samples remain independent. Current-rig availability must be checked, not only
maximum engine capacities.

## Verification and boundaries

- Prove silence, half travel, unity, upper limits and reversed endpoint ranges
  from literal scale expectations, across both MIDI and External paths.
- Verify drafts, Save/Cancel, unavailable-target repair, units, keyboard/encoder
  endpoint editing and no jump when a mapping is created or reconnected.
- Challenge overlapping held sources, ordinary edits, equal-value intent,
  refused writes/restores, pair replacement and queued session changes.
- Save/reload and shutdown must preserve Released intent across all mix fields;
  failed storage must remain visible and recoverable.
- Run focused domain tests, the full application and affected package gates,
  static checks, independent source/adversarial review and published-head CI.
  Native render/Pen checks remain separate from physical controller proof.

Loop/click targets follow as a separate end-to-end slice. Transform, backing
and instrument targets remain with their real owning implementations. This
slice does not add placeholders for them or declare the full catalogue done.
