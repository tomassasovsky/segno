---
status: accepted-a
issue: 919
---

# Pedal setup: fewer competing controls

## What We're Building

A simpler way to configure physical pedal behavior. The owner accepted separate
Press/Hold assignments but found the Pedals page inside Loop settings clunky and
the growing Loop settings area cluttered. The current custom map places sixteen
gesture buttons inside eight editable pedal cards. The setup form mixes Mode
entry, shared recording holds, custom assignments and new-loop policy.

The owner explicitly set **Mode Press: Mute / Hold: Custom**. That default is
updated in the main prototype. The owner has selected **A — Select a pedal**.
The live pedal study now uses A exclusively; B and C remain historical Pen
references. This is an interactive design target, without audio dispatch.

## Why These Approaches

All three propose **Settings → Pedals** as a peer of Loop settings. Pedal
configuration affects the instrument beyond loop recording, including custom
performance functions and external expression. The comparison's Back button
shows that navigation relationship. Its Loop settings preview contains only
the six loop-related destinations. Those destination buttons are navigation
illustrations; their complete editors remain in the primary prototype.

| Option | Interaction | Advantage | Cost |
|---|---|---|---|
| A — Select a pedal | Compact physical map; select one pedal and edit its Press and Hold below. | Two assignment controls compete for attention. Both gestures of the selected pedal stay visible. Preserves the faceplate. | Comparing several pedals requires selecting each. |
| B — Gesture layers | Full physical map shows either Press or Hold, chosen at the top. Tap a function directly to replace it. | One assignment per pedal keeps the board uncluttered. Good for setting all presses, then all holds. | The other gesture is hidden; the selected layer must stay unmistakable. |
| C — Assignment table | Pedal names with aligned Press and Hold columns. | All pairs are easy to compare and edit directly. | Loses the spatial relationship to the actual switches and feels more like a settings form. |

**Chosen: A.** It preserves the appliance character while reducing simultaneous
edit controls. The owner preferred its physical map after the hardware widget
refinement. B and C are superseded; they are not alternate live implementations.

The source pattern remains Looper X's physical pedal map and function chooser,
adapted to Segno's ten switches and independent Press/Hold. The owner rejected
the earlier per-audio-track settings form; none of these options reinstates it.

## Key Decisions

- All options use the same ten-pedal positions and assignment fixture so the
  comparison concerns layout, not different feature sets.
- Track controls and Custom controls describe separate gesture contexts.
  Mode defaults to Mute/Custom in normal track control and remains Exit in
  Custom. Bank is available in Custom controls and fixed in Track controls.
- The normal track Hold setting still applies to all track pedals. Option A
  selects that shared group together rather than inventing per-track overrides.
- Foot-entered functions still require foot-only operation and Exit. These
  preparation screens do not substitute for those performance journeys.
- The main prototype keeps a separate editing draft. Save writes pedal settings
  into the same persisted rig as FX; Cancel restores the saved setup.
- The reviewed settings' features remain available in the primary prototype.
  Expression setup, new-loop reset policy and other page placement details must
  be resolved in the accepted structure; the layout decision does not remove them.
- Both physical display roles remain open. Each candidate uses the shared
  1920 × 1080 canvas, readable control sizes and encoder-style focus navigation.

## Open Questions

- Where should expression calibration/assignment and the new-loop policy sit
  within the selected Pedals structure without competing with common edits?
- What do the remaining performance functions do at each physical switch?
  Those action contracts remain separate from this layout choice.

[Try the accepted pedal layout](../design/fx-ux-prototype.html?review=pedal-setup).
[Performance behavior contracts](../design/2026-09-06-pedal-performance-contracts.md).

## Review artifacts and validation

- The accepted Custom controls, Track controls and LED color references are
  saved in `segno-ui.pen`. B and C are explicitly marked superseded.
- [Native Pen exports](../design/pedal-layout-previews/index.html) and
  [text geometry checks](../design/pedal-layout-previews/verification.json)
  accompany the interactive comparison. Each frame is 1920 × 1080.
- Chrome and Firefox checks pass for accepted A: independent gestures,
  Mute/Custom defaults, bank isolation, Save/Cancel, chooser dismissal and the
  proposed Settings navigation. No overflowing controls or page errors were
  found in the checked states.
- Native Pen text checks passed after replacing font-dependent dropdown glyphs
  with vector icons. Main-study Mode defaults and its two affected Pen exports
  are updated as well.
- Validation covers the prototype only. Physical touchscreen comfort and
  actual pedal gesture dispatch remain separate work.

## Hardware widget refinement

The owner narrowed the comparison to A and C and requested the real pedal
shape from Fusion, then clarified that it should be a reusable widget. Both
candidates now use the same vector face: tapered metal body, rubber pad,
5 × 6 raised grips, side hinges and the original manufacturing label outlines.
A shows the full physical map; C keeps small pedal faces beside readable row
names. B remains available as a comparison and uses the same face.

The implementation is a reusable browser prototype component and a reusable
Pen component, with label, size and selected appearance overrides. The Fusion
PNGs are reference evidence. They are not used as the interactive UI. See the
[widget reference](../design/pedal-hardware/README.md) for provenance and scope.
A production Flutter widget is not implemented in this design iteration.

The subsequent review favors A as the active refinement direction. The owner
requested more space between rows, then specifically moved Clear and Bank
upward. The front row and editing controls stay in place. Track controls dim
and disable Stop, Undo, Clear and Bank; these are skipped by touch and encoder
selection. The four track pedals remain a shared editing group. Custom mode
keeps Bank available, while its fixed Exit pedal is dimmed.

Ten pill indicators sit above the physical-map pedals, following the
hardware's 60 × 6 mm visible lenses. The owner subsequently clarified that LEDs
represent function state, not editing selection. The pedal face and encoder
outline retain selection feedback; the indicator observes the function's
active state in its configured color.

## LED colors and function state

The owner requested configurable colors and defined both behaviors:

- Momentary: active while held; release deactivates it and extinguishes the LED.
- Toggle: one activation turns the function and LED on; the next turns both off.
  Releasing the pedal does not change the latched state.

LED behavior follows the assigned function. It is not a second independent
Momentary/Toggle setting in LED setup. A function changed elsewhere must also
update its LED; the implementation must observe confirmed function state,
rather than count raw switch edges. Press/Hold arbitration must resolve the
function before changing a latched state.

In A, **LED colors** uses the same hardware map with all ten pedals selectable.
The color palette edits a single physical indicator. Fixed pedal actions remain
uneditable in Track controls, and track action edits still apply to the group.
LED colors are independent of those action edits. The current prototype uses
one color per physical LED across banks; function-specific color overrides and
arbitration between distinct Press/Hold state sources remain open decisions.

The main prototype's Stage view now supplies function state to the indicators.
There is no separate LED simulator. The LED colors page changes color only;
selection cannot trigger the pedal or change its state. The indicator remains
decorative and adds no encoder stop. Swatches are touch/encoder controls with
color names and a selected outline. Save/Cancel uses the main rig's persisted
pedal settings and a separate draft. Review routes are `pedal-setup`,
`pedal-leds` and `pedal-leds-active`; the last is a repeatable active-FX fixture.

## Locked direction

The owner explicitly chose **A — Select a pedal** after reviewing the hardware
widget, row positions, fixed-control treatment and state-driven LEDs. A is the
accepted design target. B and C are superseded references, not competing live
flows. The browser study now implements A only; Pen retains the earlier frames
marked superseded for review history. This locks the reviewed UX direction,
not the unresolved performance contracts listed above or hardware readiness.

## Accepted performance journey and main integration

The owner reviewed the performance layout positively and requested that all
accepted choices be implemented in `fx-ux-prototype.html`. It is now the
canonical interactive prototype. The standalone layout comparison and its
superseded test are removed; B/C and earlier Loop pedal screens remain only as
explicitly superseded Pen references.

Settings has a dedicated Pedals entry alongside Loop settings. Stage uses the
accepted hardware map. Mode defaults to Mute on Press and Custom on Hold;
Custom can enter FX, Bank selects the other four assignments, and Exit returns
to Tracks. Holding never also fires Press. Saved assignments and LED colors
remain after reload; unrelated FX saves cannot commit an unfinished pedal edit.

FX performance reads the actual main-editor rack assignments, including normal,
inverse and momentary rules, and changes the same logical pedal state. Its LEDs
observe that state. Active momentary release stays paired to its original FX
assignment across bank changes or Exit. Latched state survives those transitions.
This is distinct from the accepted pending track-hold rule, which follows the
newly selected track when the action executes.

The ten affected Pen screens are updated from full-size main-prototype geometry.
Chrome and Firefox checks cover setup and performance; the existing FX journeys,
placement, Loop settings, playback/decay and audio/tempo checks also pass. Native
Pen checks cover text anchors, fonts, clipping and ten pedal instances/indicators
per physical map. These are author-side prototype checks, not audio or hardware
validation. The remaining function workflows are open design work.
Expression setup has since expanded into the [External pedals study](../design/2026-09-06-external-pedals-ux.md), including single/dual switches and fixed track assignments.
