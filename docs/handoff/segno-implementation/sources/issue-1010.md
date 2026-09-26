# #1010 feat(console): slice 1 — accepted Tracks view, selected-track display and first-take crown [open]

Part of #1009 (slice 1 of the accepted Segno design; design under #919).

## Scope

- Main display: four tall track columns for the active bank with the accepted
  info block (name, number, bars, layers, FX marker), one whole-track level
  meter with shared dBFS scales and a clip cap, a centred queued-action cue,
  a thin bottom progress bar, state colours and the selection outline.
- Top bar with Library, session name, bank, view menu (Track / Wave) and
  Settings icons; footer with BPM + signature, elapsed transport time, output
  level and loop mode. The mode pill and bank pair move off the main bar.
- Second (7") display follows the selected track: number, crown, name, state
  word, bars, its own waveform with bar ruler and playhead; footer with tempo
  and the current function · bank. The volume overlay and MIX pill are retired.
- Crown: the engine crowns the first completed take when none is crowned and
  clears the crown when the session empties; explicit re-crown remains the
  timing handoff. The crown is a readout on every view, not a tap target.
- Engine snapshot gains the output peak and a per-track play position so the
  footer and per-track progress read real owners.

## Out of scope (later slices)

Mixer view (pan/solo/stereo metering), touch lock, load-audio, MIDI sync pill,
first-take tempo review, Sync/Band successor rule on clearing a primary.

## Acceptance

Record Track 3 then Track 1: the crown stays on 3; selection and bank never
move it or change playback; queued actions stay on their track; Mute stays on
the columns; a cleared session shows no crown; the 7" follows the cursor while
settings or FX are open.
