# #1009 feat(console): implement the accepted Segno design throughout the app (handoff 919) [open]

Implementation programme for the accepted Segno product design. The design and
prototype work lives under issue #919; this epic tracks turning it into the
production Flutter/native app, slice by slice, keeping the app working after
each one.

Handoff pack (untracked in the design checkout): `docs/handoff/segno-app/`.
Accepted behavior: `accepted-behavior.md`. Slice order: `implementation-map.md`.

## Slices

- [x] 1. Main Tracks journey and shared visual foundation: four-column active
      bank, whole-track meter, queue cues, FX markers, compact footer, icon
      navigation, selected-track second display, first-completed-take crown
      with empty-session clearing.
- [x] 2. Recording, timing and reversible audio edits (#1012).
- [x] 3. Inputs, outputs, Mixer and FX (#1016).
- [ ] 4. Shared assignments and foot performance (#1026).
- [ ] 5. Library, sessions, backing and durable recovery.
- [ ] 6. MIDI, external sync and instruments.
- [ ] 7. Device and appliance completion.

Each slice gets its own build issue and PR. UX taste on the result is the
owner's call, so slices are `autonomy:merge-gate`.



