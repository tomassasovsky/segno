# Design consistency review

Requested by the owner after the backing playback slice. Investigate existing
screens and saved variants directly; do not ask the owner to enumerate each
instance of a systemic problem.

1. Color hierarchy: blue and muted amber/yellow dominate inconsistently between
   pages. Compare selection, primary actions, focus and performance-state colors
   before proposing a single clear hierarchy.
2. Main Settings menu: owner prefers an earlier version shown in an isolated
   preview. Find that variant among local prototypes and saved design references;
   compare it visually with the current menu.
3. Power off: side padding is missing. Check the actual button and shared action
   sizing so the correction applies consistently.
4. LED palette: allow adding fully custom colors to the reusable palette, beyond
   the current fixed choices. Preserve state-based momentary/toggle behavior and
   the active state when assigning or editing colors.

Backing seek/end/repeat is implemented and verified in the prototype and Pen,
awaiting owner review. Library waveform preview was approved on 2026-09-08
and its native references are saved.

5. The button/parameter-values screen is a concrete example of conflicting yellow
   and blue action hierarchy; trace shared classes and native references.
6. Rename flows (tracks, sessions and other named items) should use the agreed
   keyboard bottom sheet instead of centered keyboard dialogs. The sheet must
   not scroll or dismiss through dragging/outside taps. Retain intentional
   completion/cancellation paths and check the earlier keyboard decision.
7. Encoder focus frames clip at the left edge on several pages, including Session
   save / Storage error. Audit scroll containers, outlines and imported Pen
   geometry; fix the shared cause, then check every affected flow.

8. Center the content and power icon on Safe to switch off and Restarting.
9. Compare Add effects directly against the Looper X reference and revise its
   composition; preserve the original artwork and full factory catalogue.

Owner correction: Settings feedback concerns the earlier theme, not reducing
the number of entries. The five-group restructuring is rejected; retain all
ten direct destinations while locating and comparing the earlier theme.

Owner confirmed the earlier blue-gray palette. The main Settings menu now
uses that palette, the isolated study’s wider 100 px margins, regular heading
weight and spacing. All ten destinations stay direct. The owner remembers
another difference; these typography/spacing details remain a comparison,
not a claim that the exact earlier menu has been recovered.

## Implemented refinement

| Item | Current result |
| --- | --- |
| Shared control colors | Primary actions use light blue with dark text. Selected choices use a darker blue surface and light text. Amber identifies encoder focus or warnings; musical state and LED colors keep their meanings. |
| Settings | Ten direct entries, with the confirmed blue-gray palette, 100 px side margins and regular-weight heading. The five-group interpretation is superseded. |
| Power button | A 64 px square with consistent side clearance. |
| LED palette | Add and edit reusable custom colors using Hue, Saturation and Brightness. Touch and encoder work; the saved palette survives reload and changing color preserves function state. |
| Keyboard | Existing naming and Wi-Fi password flows use a fixed, non-scrolling bottom sheet. Outside taps and dragging do not dismiss it; Cancel and Done remain explicit. |
| Encoder focus | Inset outlines avoid clipping. Native references retain the control's parent stacking order, so focus behind a dialog cannot appear over it. |
| Power terminal screens | Icon and message are centered as one group on Safe to switch off and Restarting. |
| Add effects | Original artwork sits above labels, with Ed's Rack spanning two columns beside My presets and Single FX. The full factory catalogue remains available. |

The [review gallery](consistency-previews/index.html) shows the saved native
screens with links to the corresponding interactive prototype states.

Validation: Chrome and Firefox passed the consistency, session Library, pedal
setup, pedal performance, backing playback, power and network checks. The native
geometry audit checked 523 text objects and 1,266 elements across the revised
screens, with no alignment, section-overlap or containment errors. All 244 focus
markers across 241 current screen references match their controls and remain in
bounds. Visual review additionally caught and corrected a percentage-radius
import error and the bottom keyboard's lower corners.

Pen was saved and its on-disk change verified. The current saved hash and check
results are in [verification.json](consistency-previews/verification.json).
All current native gallery images were refreshed. These are prototype and design
checks; no production audio, operating-system settings or hardware behavior is
implemented by this slice.

## Settings cards and original artwork follow-up

The owner found the wide menu panels too large relative to their labels. The
revised draft uses two rows of five compact cards, preserving all ten destinations
and their order. Each has a centered illustration above its label. The cards are
smaller in area and keep the agreed blue-gray surfaces and inset encoder focus.

The first stock-symbol pass was superseded at the owner's request. Settings will
use original Segno artwork, with subjects drawn from musical equipment: chained
effect pedals, loop lanes, a pressure-pad footswitch, MIDI DIN connector, audio
patching, audio interface, network connection, the two physical displays,
storage media and software installation. No extra descriptive copy is added to
the cards. The owner preferred this original-artwork version.

The ten illustrations are saved as reusable Pen components and 480 px PNG assets.
The original atlas, full generation prompt and crop/component mapping are in
[the artwork manifest](settings-art/manifest.json). The updated Settings frame
passed the native audit (13 text objects, 42 elements), with no alignment or
containment errors. Chrome and Firefox passed the revised consistency suite.

## Normal prototype entry

Opening or reloading the normal prototype URL now starts in the main Tracks
view, showing four tracks for the active bank. Settings and Effects are reached
through normal navigation. Saved music and configuration remain available;
opening the app does not reset the rig. Explicit review links continue to open
their named design fixture. Chrome and Firefox verified launch, reload from
Settings and Effects, the Back journey, and saved palette persistence.

## Further surface and scrolling corrections

The owner identified remaining warm-looking FX cards and dialogs, black text in
USB update choices, and a separate MIDI palette. Shared cards and dialogs now
use the agreed blue-gray surface and cool light text. USB packages and interface
choices have explicit readable text colors. MIDI Controls and Sync use the same
surface, selection, action and slider colors. Amber remains encoder focus and
warning feedback. The power status label is simply “Restarting”.

My presets now has original pedalboard artwork, informed by the tonal equipment
illustrations in the adjacent catalogue entries. Its
[generation prompt](settings-art/my-presets-prompt.txt) and PNG are retained with
the other original assets.

The earlier floating FX parameter arrows are superseded. Overflowing pedal
columns have a persistent scrollbar with a separate gutter, clear of the
controls. It supports touch/mouse dragging, while normal touch scrolling and
encoder focus continue to reveal parameters. The scrollbar is outside encoder
navigation. Fitting columns do not show an unnecessary scroll indicator.

## Mixer reference follow-up

The owner accepted the current Track view and supplied the Looper X Mixer view
as a separate reference. The Mixer revision keeps track names, bars, layers and
FX indicators visible alongside mute, pan and volume. Each channel also shows
its level meter and playback progress. This Mixer layout remains a proposal;
the accepted Track view retains its existing composition. All audio and meter
behavior remains simulated in this study.
