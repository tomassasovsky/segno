# Pen sizing and visual review

Scope: the 22 `FX UX 2026` and 17 `LOOP UX 2026` study frames, not the older application reference
screens or a physical display assignment. All study frames are 1920 × 1080.

| Discrepancy | Correction |
|---|---|
| Compact and larger canvases mixed in the same journey | One canvas and shared control sizes in HTML and Pen |
| Single-line labels wrapped or disappeared in imported text boxes | Preserve rendered text lines and fit native text bounds |
| Font metrics cut off labels or offset their alignment | Correct text-container bounds and alignment in Pen |
| Parameter scroll arrows absent from Pen | Explicit centered arrow layers; browser encoder still skips them |
| Ed’s Rack title offset from its preset count | Restore shared left alignment |
| Inactive artwork more saturated than the browser | Use rendered muted states of the original artwork for these design fixtures |

The original source catalogue is unchanged. `state-art/` contains browser-rendered
muted artwork used only by the Pen review frames. Controls, labels, navigation,
and layout remain editable layers.

Verification: native Pen screenshots and full-resolution exports were reviewed
separately from the passing Chromium and Firefox prototype checks. The browser
sizing gate covers all captured routes, minimum 56 px targets, full canvas bounds,
and preserved scrolling and encoder interactions. Physical readability, touch
comfort and the roles of the 7-inch and 15.6-inch panels still need validation.

[Open the complete Pen export gallery](index.html).

The current gallery includes the complete FX add, arrange, name, save, replace
and reuse journey plus Loop settings, mode, recording, timing, signature, length/quantization, per-track inheritance and
lock states. Multi-line native text preserves line spacing, and encoder focus
rings sit outside clipped slider controls.

The accepted per-track selector uses Tracks, Defaults, then 1–8. Wider content
margins stay consistent, and the Defaults control aligns in both selected and
unselected states. Native text fitting preserves right-aligned track names,
line spacing and full focus outlines. The earlier no-clipping check was insufficient: it did not detect labels
aligned to the top of their buttons. The typography check below replaces that
evidence for text placement.


## Native text alignment correction

The owner identified misaligned text in Pen after the per-track work. The import
fitter had subtracted each text group's top offset, including labels inside
buttons, so centered labels moved to y=0. It also substituted Inter for the
browser's resolved Arial font and omitted CSS letter spacing. Small overview
images and clipping-only checks did not catch this.

The corrected import preserves each rendered browser line rectangle. Native
text uses Arimo for the browser's Arial metrics and JetBrains Mono for number
readouts, with the rendered weight and letter spacing. Each line remains an
editable text node. Its horizontal anchor and vertical center follow the source
rectangle; multiline spacing is retained. Control dimensions are never expanded
to accommodate misplaced labels. Focus outlines remain outside clipped controls.

All 39 study frames were refreshed. Measured alignment of 1,265 text nodes stays
within 1 px of the browser line anchors and centers. Width differences stay
within 3 px or 1%, whichever is greater. See
[text alignment results](text-alignment-verification.json). This validates text
placement, not pixel-identical rasterization or appliance readability. Native
screenshots of controls and full-size reference exports were also inspected.

The capture and fitting scripts are now stored with the design:

- `../../export_prototype_geometry.cjs` captures named review views into temporary
  JSON node lists. It does not read or write the encrypted Pen document.
- `../../fit_prototype_text.pen.js` runs through Pen MCP after inserting geometry
  and loading the fonts. Never replace it with a rule that sets all text to y=0.

Save the design through Pen's File > Save command after a native review, and
verify the on-disk change. Exported images alone do not save the design file.

## Playback and overdub extension

The gallery now has 42 study screens. The loop hub was updated and three
Playback & overdub views added: defaults, an inheriting track and a custom
track. Native text checks passed for all 87 labels in the four changed frames;
combined with the unchanged frames, the current report covers 1,341 text nodes.

This import exposed stale native parent/render state: newly inserted descendants
looked correctly nested in Get(), but resolved positions carried an extra 50 px
and screenshots were blank. Explicitly reaffirming each parent with Move(),
then allowing a separate tool call for native layout, restored the rendering.
`settlePrototypeParents` in the typography helper preserves that correction.
Run it before fitting new imports; verify screenshots and resolved bounds after
layout has settled. The full screen and individual controls were inspected, then
exported at 1920 × 1080. This does not establish physical screen usability.

## Audio and tempo extension

The current gallery contains 46 screens and 1,436 checked text nodes. Four
Audio & tempo variants were added and the loop hub now has six compact rows.
Parent settlement preceded text fitting on these new imports; all 108 labels
in the five changed frames passed alignment/width checks. The follow-pitch and
original-speed variants were visually inspected in Pen, then all five frames
exported at full size. The owner accepted the browser page and redirected the
next design slice to Pre/Post and output FX.


## Pre/Post, outputs and ten-pedal setup

The gallery contains 55 study screens. Pre/Post uses a direct switch with one
short consequence label. Outputs is a separate destination with no placement
control. Shared pedal settings and the custom assignment menu replace the
rejected per-track Press/Hold preview.

The custom menu follows the Segno faceplate: eight front pedals from Record/Play
through Track 4, with Clear above Undo and Bank above Mode. Mode remains Exit;
Bank switches the four track assignments in place. This preserves the reference
assignment interaction while matching Segno's ten physical pedals.

All 1,765 text nodes across the 55 frames pass the recorded alignment and width
tolerances. Native screenshots of the custom grid and selection overlays were
inspected after parent settlement and text fitting. Browser journey checks cover
touch, encoder, bank changes, Save/Cancel and persistence in Chrome and Firefox.
These are configuration prototypes; physical usability and audio/gesture
execution still require implementation and appliance validation.


## Independent Press and Hold assignments

The gallery now contains 57 screens. Seven frames were refreshed or added for
the revised pedal setup, custom Press/Hold controls, both assignment choosers,
Mode Hold and Bank B. All 1,947 text nodes pass the recorded alignment and width
tolerances. Native setup, custom-layout and Hold-chooser screenshots were
inspected after parent settlement and fitting. The browser checks pass in Chrome
and Firefox for independent gesture edits, focus return, banks, persistence and
Save/Cancel/Clear. Loop setup and FX placement regression checks also pass.

The page configures gestures; it does not prove exclusive press/hold dispatch,
function entry/Exit, or audio behavior on the appliance. Those remain explicit
performance-contract work. The obsolete single-action pedal-study data is
replaced by the new gesture-pair model rather than migrated.
