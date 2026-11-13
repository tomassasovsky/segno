---
{}
---

# A performance, rebuilt in Ableton Live

## What We're Building

A performance capture records everything the console did, and its Live set rebuilds the performance from the raw sources, non-destructively. Concretely:
- the raw audio stays untouched: clean inputs, and the loop layers as recorded;
- everything that shaped the sound is rebuilt on top in Live, as Live devices and automation:
  - our effects as plugins, with their settings;
  - effect and rack switching;
  - monitor and track volume, pan and mute;
  - when each loop played.

Opening the set and pressing play should sound like the performance. Changing any of it in Live should be an ordinary edit, not a re-render.

Today's set is mostly baked audio. It holds wet stems with effects and mutes rendered in, input recordings taken after the monitor effects and level (silent when monitoring was off), and the effect chains only as text.

## Why This Approach

The owner asked for it on 2026-11-12: "Everything, and replicate it on Live without destructively editing the raw source audio." It is also how DAWs model a mix: sources plus devices plus automation. Live already has every piece:
- VST3 devices with saved state;
- Audio Effect Racks;
- device on/off and mixer automation;
- arrangement clips.

Alternatives, rejected:
- **Baked stems only** (today's set): sounds right, but you can't change an effect or a fade without going back to the console.
- **Our own editor** (2026-11-12 discussion): months of work to reach what Live already does. Live plus our plugins gives the same effects.
- **Decompiling Live** to learn its format: slow, fragile, and against Ableton's licence. Sets that Live itself saves are the reference instead (#1793).

## Key Decisions

- **Record raw inputs.** Every captured input's clean mono sample is recorded every frame while armed, before effects, monitoring, volume and pan (#1805). The as-heard recording stays as a reference.
- **Record the controls, not just the audio.** Every change to the following is logged as a timed event:
  - an input monitor's on/off, mute, volume and pan;
  - a track's volume, pan, mute and solo;
  - an effect's or rack's on/off, A/B switch and parameter changes.
  The chains and names at arm are already recorded (#1803).
- **Our effects run in Live as VST3 plugins.** They are built and installed on the owner's Mac, so there is no signing or installer (#1804). Each plugin is checked against the engine's render with a null test.
- **Set layout:**
  - **Inputs:** each input's raw clip, with its monitor chain as plugins, and its monitor volume, pan and mute as mixer automation.
  - **Looper tracks:** their recorded layers as clips, placed where they played, with the track's chain as plugins, and its volume and mute as automation.
  - **Reference tracks:** the as-heard stems and the master stay, switched off, for comparison.
- **Grow it in layers:**
  1. raw inputs (#1805);
  2. plugins with their starting settings (#1804 layers 1 and 2);
  3. control events and their automation;
  4. loop playback as arrangement clips.
  Each layer ships on its own; until a layer lands, the set falls back to today's baked stems for that part.
- **Check every layer in Live.** Each one is verified by opening real exports, with screenshots, and by a null test of the rebuilt set against the as-heard master.

## Open Questions

- **Loop history.** What does a capture keep of each loop's history (overdub layers, undo, clear, replace)? Is it enough to place each layer as a clip at the times it played? If not, what must the engine add, and how big is it?
- **Engine processing outside the plugins.** Which of it must be reproduced in Live, and how? This covers time-stretch on tempo change, the master limiter, latency offset and sends. Some may stay baked.
- **Parameter automation.** Which effect parameters can be automated on the console, and do our plugins expose the same parameter IDs for Live automation?
- **Accuracy.** How close must the rebuilt set be to the as-heard master: bit-exact, or within a stated difference? Modulated effects and resampling may never be bit-exact.
- **Older captures.** They have none of this data. Keep today's layout for them.
