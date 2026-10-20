# Approved LED animation references

Open the HTML file directly in a browser; no installation or network access
is required. The approved animation fragment is kept intact, with a
standalone page and local styles replacing the conversation display. Optional
conversation-state hooks do nothing in an ordinary browser.

- [Song queue completion](song-pill-completion.html): two eight-pixel pills,
  left-to-right completion over the remainder of an example loop, cancellation,
  requeue and automatic handoff. The real engine owns the handoff; this
  preview uses a browser clock to illustrate the interaction.

It supports pause and reduced-motion preferences. Diffusion, colour and screen
brightness are illustrations, not optical measurements or electrical simulation.
Firmware output, safety limits, stale-link handling and sample-accurate
switching are verified by the native and firmware tests, not this preview.
