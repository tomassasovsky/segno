# Repair a saved session's controller connections

September 8, 2026. The owner asked to continue after reviewing the shared
behavior proposals. The downstream-tail comparison stays open. This next local
prototype develops the remaining Library connection-repair gap under issue 919;
it does not approve new scope or change production audio.

## Flow

Opening a session with an unavailable pedal or MIDI controller shows its missing
connections. Choose a connection, select a compatible available replacement,
review the affected assignments, then Apply and open. Selection only edits a
pending copy. Cancel keeps the current and archived sessions unchanged. Failed
storage or a new disconnection keeps the pending repair available to retry.

Pedal replacements require the same configured type and switch hardware, and a
currently valid expression calibration. An incoming session's already-assigned
port cannot be overwritten. MIDI replacement preserves channel, message, ranges
and target IDs; a source collision is refused. The original saved source ID is
never replaced by a same-name heuristic. Physical calibration, types, aliases
and global MIDI/clock settings remain current. Unresolved effect/parameter
targets stay clearly blocked; this slice does not guess a replacement knob.

The same pending repair supports touch and encoder. Foot-triggered session
changes retain Cancel/Retry ownership and do not fall through to track controls
while repair is pending. The existing main Library and its waveform preview
remain the entry point; no second session browser is added.

## Success criteria

- Compatible CTRL and MIDI replacements preserve musical mappings and physical
  setup; incompatible/occupied/colliding choices cannot apply.
- Selection and Cancel never change the live or archived rig.
- Apply rechecks current source availability and the unchanged archived entry,
  then uses the existing atomic session publication boundary.
- Failed publication preserves the pending proposal and prior playable rig.
- Main-host Chrome and Firefox journeys cover touch/encoder, disconnection,
  failure/retry, foot ownership, reload and existing ownership/media recovery.
- Matching native Pen references are saved and visually/alignment verified.
- Independent build review roles report no unresolved actionable findings.

## Non-goals

Physical controller discovery, calibration routines, native audio, autonomous
remapping, partial-session publication and reopening the tail-policy decision.
