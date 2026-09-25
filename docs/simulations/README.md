# Approved LED animation references

Open either HTML file directly in a browser; no installation or network access
is required. The original approved animation fragments are preserved intact,
with a standalone page and local styles replacing the conversation display.
Optional conversation-state hooks do nothing in an ordinary browser.

- [Song queue completion](song-pill-completion.html): two eight-pixel pills,
  left-to-right completion over the remainder of an example loop, cancellation,
  requeue and automatic handoff. The real engine owns the physical transition;
  this preview uses a browser clock to illustrate the interaction.
- [Sustained ring comet](sustained-ring-comet.html): compares the rejected fast
  fade with the approved sustained profile for 40 pixels. The right-hand profile
  matches the firmware 1.11 output shape; both show a 1100 ms revolution and can
  display individual pixels instead of estimated diffusion.

Both support pause and reduced-motion preferences. Diffusion, colour and screen
brightness are illustrations, not optical measurements or electrical simulation.
Firmware output, safety limits, stale-link handling and true sample-boundary
switching are verified by the native and firmware tests, not these previews.

Earlier exploratory animation variants remain local historical artifacts and
are not additional implementation targets. See the
[publication record](../reviews/pedal-publication-1076-1077/verification.md).
