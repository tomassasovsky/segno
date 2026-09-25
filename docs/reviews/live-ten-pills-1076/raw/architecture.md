# Architecture review — live ten-pill firmware

## Scope and evidence

Reviewed the console firmware change against the preserved firmware 1.7
baseline, rather than the older Git HEAD. Baseline sketch SHA-256:
`4ff7c20f009d20e2eca2977b7621d4c12bf195157545e9af72a715da18333d8a`.
Reviewed firmware 1.8 sketch SHA-256:
`a09c54e38bf3a1c965c0f3d47d293d443ce74c932fdbc9f72b15d03127885485`.
The final recheck includes the existing protocol's `PEDAL_MODE_PLAY` enum,
which the application labels Mute.

This is Arduino C++ firmware for the existing Pico 2 console, with a C protocol
codec and host behavioral tests. The repository also contains a Flutter/Bloc
application, but this change introduces no application-layer dependencies.
The review covers the 80-pixel renderer, DMA driver integration, unchanged ring
and controls, protocol boundaries, and the encoded current budget. It is a
source review, not physical current or thermal qualification. The reviewer
authored the new host stub and library-install lines; their behavior was checked
separately, but those edits are not claimed as independently reviewed here.

## Layer separation

- Violations found: 0.
- The console remains a thin client. Track colors, selected bank, mode, clear
  status and transport color come from accepted STATE frames.
- STOP and UNDO use existing debounced switch state solely for local press
  acknowledgement. They do not fabricate an undo-availability or stopped state
  that protocol 5 cannot express.
- The mapping and spatial gradient remain within the existing firmware
  renderer; no extra package or generic rendering framework was introduced.

## State management assessment

- Physical mapping is a complete permutation of all ten logical buttons.
  Eight pixels per group gives exactly 80 destinations. Reversing the first
  eight groups and retaining forward indexing for the last two produces every
  index from 0 through 79 once, so the local desired-color array is fully
  initialized before use.
- The codec rejects active banks outside 0–1 and invalid LED enums before
  installing a STATE frame. The active-bank track lookup therefore stays in
  the existing eight-element track array.
- REC/PLAY preserves the previously tested empty-state breath, recording,
  playback and layered-recording colors. Goodbyes and expired frames produce
  black across the entire chain, including local switch acknowledgements.
- Unchanged displayed values skip redundant transfers. The explicit Dirty
  call retains the periodic forced refresh with NeoPixelBus, whose Show method
  otherwise skips clean buffers.

## Dependency direction and driver resources

- Direction violations: 0. Firmware depends on the existing protocol codec
  and the LED libraries, with no dependency back to application behavior.
- NeoPixelBus 2.8.4's PIO/DMA method has separate editing and sending buffers.
  Default Show(true) preserves the editing contents, so GetPixelColor remains
  suitable for change detection while the previous frame transmits.
- The selected driver explicitly uses PIO1. The installed arduino-pico 6.0.0
  SDK's automatic allocator searches PIO instances in descending order; on
  RP2350 the existing Adafruit ring, initialized first, ordinarily claims
  PIO2. The sketch uses hardware Serial1 and no other PIO consumer.
- The 24-pixel ring, encoder sampling, button events, control-jack handling,
  UART transport and protocol 5 codec are unchanged from firmware 1.7. Its
  existing short interrupt-masked ring transfer remains; the new 80-pixel
  transfer uses DMA with interrupts available.
- The production firmware uses direct library APIs supported by the inspected
  installed sources. Firmware compilation and behavior tests are the separate
  validation gates; this review does not substitute for them.

## Current-budget assessment

The renderer sums the final color-channel levels and proportionally scales
all pills when the total exceeds 6000. Integer division rounds downward, so
the emitted total cannot exceed 6000. Using the stated conservative 20 mA per
full-scale channel model gives `6000 / 255 * 20 = 470.59 mA` for the pills.
The unchanged 128/255 ring cap bounds all 24 pixels at full white to
`24 * 3 * 128 / 255 * 20 = 722.82 mA` in the same model. Adding the stated
104 mA pixel-idle allowance and 140 mA logic allowance gives 1.438 A, below
the task's conservative 1.65 A old-board path budget. This is a calculated
ceiling under those assumptions, not a measured board-current guarantee.

## Package structure

- Existing firmware structure is sufficient. The new dependency is confined
  to console LED output and installed in both firmware build workflows.
- No protocol revision, compatibility layer or new runtime mode is required.
- The current worktree retains the separate one-pill bench sketch from the
  baseline; normal firmware does not invoke it.

## Verdict

Architecture is clean. No actionable architecture findings were identified
for the reviewed sketch revision. Device validation must still establish the
combined live pedal behavior; previous LED-chain inspection alone does not
establish that result.
