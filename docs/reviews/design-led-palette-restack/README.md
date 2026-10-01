# Reusable pedal LED colors

Pedals now includes an LED colors context for all ten physical switches. The
same custom color can be reused on several switches; editing it changes their
shared definition. Assignments and colors share one local draft with Save and
Cancel. The activity of an indicator continues to come from the actual function
state, independently of its hue and the pedal selected for editing.

Base: `27b13351a7ad43828a4bd83d14305ed5978572b4`.
Original proposal parent: `1e1dbc6088ccd438f5c3d93086c6cd6eef2d3310`.
The [source binding](source.json) covers implementation, tests, images and saved
Pen changes before these report-only additions.

## Behavior

- Eight named colors and reusable custom colors. Hue, Saturation and Brightness
  edit an exact RGB value. New setups use full white; black is a valid choice.
- Colors belong to physical switches across banks. Bank selects its own lamp
  in the color editor, and fixed-action switches remain editable there.
- Draft colors preview only in setup. The confirmed pedal frame is unchanged
  until a successful durable Save. Selection never changes the activity mask.
- Saving only colors preserves held contacts, pending Press/Hold gestures,
  accepted Hold ownership, delayed action results and the FX return context.
  Changing the actual assignments still retires those gestures.
- Stable custom IDs, detached immutable maps and canonical serialization
  prevent accidental changes through shared data. Malformed explicit palettes
  are refused through the existing unavailable-settings recovery path.
- Clear custom assignments and Restore retain later color and Track edits.
  Failed writes retain the existing durable rollback and uncertainty behavior.

The accepted hardware geometry is retained. Context buttons sit together above
the lower pedal row without overlapping Clear and Bank. Swatches remain
reachable by touch and encoder as the palette grows. The color editor uses
the shared slider and restores its preview when encoder editing is canceled.
All new strings are present in English and Spanish.

## Verification status

The full application suite passes 2,371 tests with six existing skips and
90.045% line coverage (20,397 of 22,652 lines), above the required 90%. The
source stayed unchanged during the final run. Formatting, strict analysis,
real Bloc lint across 672 files and whitespace checks pass. The one test-only
change after the first run also passes its focused static checks.

The first aggregate found a token-adoption scanner matching the saved hardware
RGB palette. Its existing, documented exception mechanism now names only that
model file: saved physical hues must stay independent of screen theme. Product
code did not change for that repair; the original failure log is retained.

An independent source reviewer completed the bug gate and five quality roles;
the five roles share one reviewer. A separate adversary passed nine model and
real-engine cases plus four widget cases, using expectations frozen before the
implementation. The adversarial report distinguishes fixture corrections and
unexecuted permutations from observed passing cases. No unresolved actionable
finding remains.

Nine setup images were generated and independently inspected. Native macOS
interaction confirms adding a custom color, sharing it between Mode and Bank,
Save and app restart retain the choices. A layout overlap caught in the visual
pass was fixed before the final source freeze. Pen contains the saved color
context and behavior note. These are author desktop/design checks, not device
proof. Remote CI still must pass on the exact published PR head.

No protocol, firmware, native audio or package source changes are part of this
slice. Their earlier checks are reused only after verifying unchanged source,
dependencies and workflow definitions. The current app uses protocol 8 and the
ten-indicator state established by PR #1031; obsolete protocol code is not
restored. No device was flashed. Physical brightness, perceived hue and
electrical behavior still need appliance validation.
