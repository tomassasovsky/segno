# Approved LED animation references

Open either HTML file directly in a browser; no installation or network access
is required. The approved animation fragments are kept intact, with a
standalone page and local styles replacing the conversation display. Optional
conversation-state hooks do nothing in an ordinary browser.

- [Song queue completion](song-pill-completion.html): two eight-pixel pills,
  left-to-right completion over the remainder of an example loop, cancellation,
  requeue and automatic handoff. The real engine owns the handoff; this
  preview uses a browser clock to illustrate the interaction.
- [Sustained ring comet](sustained-ring-comet.html): compares the rejected fast
  fade with the approved sustained profile on the console's 34-pixel strip
  ring (#1090). Both profiles were judged on 40 pixels; the page resamples
  each to the same angles on 34, exactly as the firmware's `COMET_DUTY` table
  is derived. Both show a 1100 ms revolution and can display individual
  pixels instead of estimated diffusion.

Both support pause and reduced-motion preferences. Diffusion, colour and screen
brightness are illustrations, not optical measurements or electrical simulation.
Firmware output, safety limits, stale-link handling and sample-accurate
switching are verified by the native and firmware tests, not these previews.
