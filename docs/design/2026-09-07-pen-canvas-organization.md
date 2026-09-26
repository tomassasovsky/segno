# Pen canvas organization

The owner requested labeled groups and reported that the new section backgrounds were covering older screens. The existing `segno-ui.pen` is now organized into four separate regions and 30 numbered sections.

| Region | Contents |
|---|---|
| Current UX | 106 current study screens in 17 flow groups. Recorded acceptance and proposal labels are retained. |
| Earlier application | 128 earlier screens grouped by domain, with their original annotations. |
| Design system | Seven design-system boards and the reusable hardware pedal component. |
| Superseded | Eight previous pedal-layout alternatives. |

Screens are children of their section containers, above their backgrounds. The regions and section rectangles do not overlap. Screens retain their original IDs, dimensions, contents and component references. Only their canvas positions and parents changed. Two long original annotations now wrap within their boxes.

## Verification

- All 250 original screen/component frames and 375 original text annotations are accounted for.
- Before/after subtree fingerprints match for all 250 original frames, excluding their canvas x/y positions.
- No sibling overlaps or clipped nodes in the new grouping structure.
- Current and earlier-region exports were visually inspected. The native file was saved and its on-disk hash changed.
- These checks cover canvas organization; they do not claim to repair existing internal layouts in the earlier application screens.

[Section manifest and verification](pen-organization-previews/manifest.json) records frame IDs and native preview exports for all four regions.

A separate file for the new product design was recommended during review. That split has not been performed; the current source remains `segno-ui.pen`.


## Audio proposal added after the organization audit

The subsequent Audio library, backing & import section adds fifteen screens.
Prepared-list reordering is accepted; the import states remain proposals.
Current UX now holds 121 screens in 18 sections; the whole file has 265 original
and new screen/component frames across 31 sections. The Current UX region was
expanded, and Design system and Superseded were moved down to preserve space.
The three normal Tracks study screens gained a Library entry.

The original audit above records the unchanged content at the time of grouping;
these later additions and intentional header edits are listed separately in the
manifest. The expanded Current UX grouping has no clipped screens. The native
file was saved after the new views were verified.

[Audio preparation and performance gallery](audio-library-previews/index.html)
contains the current browser/native pairs and alignment evidence.

## Session Library added — 2026-09-07

Section **19 Sessions · New loop & recall** sits below the left-hand performance
sections inside Current UX. Six accepted screens bring Current UX to 127 screens
in 19 groups. Existing section bounds and the archive/design-system positions
remain unchanged. The shared Library navigation is reflected in the Audio screens
and the three normal Tracks variants.

## Record performance added — 2026-09-07

Section **20 Record performance** follows Sessions in the left column. Six proposal
screens bring Current UX to 133 screens in 20 groups. The existing regions remain
in place; the new section fits within Current UX. The three Audio browser states
also include the new recorder entry. Screens remain inside their labeled sections.

## USB export added — 2026-09-07

The accepted six-state USB export flow extends section **20 Record performance &
USB export** to twelve screens. Current UX has 139 screens in 20 groups. Current UX
was expanded downward, with Design system and Superseded moved below it. The Audio
browser and Prepared audio selections now expose Export to USB.

## Input routing and output setup added — 2026-09-07

Section **21 Audio routing** contains seventeen current screens: recording and
output routes, input names, and the accepted input setup with Pan/Balance and
recording trim. Section **22 Output setup** holds six proposal screens. Current UX
now contains 162 screens in 22 sections. The section backgrounds contain their
screens; the lower design-system and superseded regions sit below Current UX.
The current manifest records exact bounds, verification and saved-file evidence.

## Tuner and external function assignments added — 2026-09-07

Section **23 Performance · Tuner** contains five accepted screens. Section
**24 External pedals · Function assignments** contains four proposal screens for
the grouped picker and Press/Hold example. Current UX now has 171 screens in 24
sections. Current UX was expanded downward and the lower archive/component
regions moved below it; all section rectangles remain separate and contained.
Native checks cover 158 Tuner text nodes and 144 external-assignment text nodes
without alignment errors. Browser/native galleries and saved-file evidence are
recorded in the manifests.

### Performance feedback

Two gesture references fill the unused positions in the existing Tracks/Custom/FX/Mute section. Tracks and FX are refreshed; no group moved or grew. The current UX now contains 173 screens in 24 sections. Native alignment and section-overlap checks pass. [Paired gallery](performance-feedback-previews/index.html).

### Stage and display-role proposal

Five references, including four editable large-screen states and one raster paired-display annotation, now occupy section 25. Current UX contains 178 screens in 25 sections. Design System and Superseded move down to leave the new section clear. Native verification checks 145 texts and 989 elements; no section overlaps or clipping were found. [Review gallery](stage-display-previews/index.html).

### Revised main views

The owner rejected the eight-card grid and generic small-screen readout. Those
five references now sit in Superseded. Section 25 contains six current references:
Track, first recording, Wave, Mixer, the selected-track waveform at its own
small-screen canvas size, and a paired-display reference. Current UX has 179
screens in 25 sections. Native checks cover 205 texts and 704 elements with no
alignment errors; section overlap and containment checks pass.

### Main track readout refinement

The latest correction removes per-track BPM, numeric dBFS and routine status
labels. A new editable queued-recording screen demonstrates the centered action
and timing cue. The current design area now has 180 screen references in 25
sections. Six editable display screens pass native checks for 233 text nodes and
753 geometry nodes; the paired reference was refreshed to avoid the cached,
rejected grid. The growing section and lower archive/component regions remain
separate. Chrome and Firefox checks pass for this refinement.

## MIDI controls and inline Mute update

The current area now contains 188 screen references in 26 labeled sections.
Section 26 groups MIDI controller mappings, Learn, knob/fader ranges, button
assignments, parameter choice, duplicate mappings, disconnected sources and the
empty state. The Settings reference includes its MIDI controls entry. The eight
MIDI frames pass native text and element alignment checks; current sections have
no overlap or containment errors.

The old separate Mute screen is under Superseded. Its current replacement keeps
the four active-bank track columns and lives with the other main-display views.
The adjacent recording annotation links that view to the shared transport model.
Pen was saved through its File menu and verified on disk. The gallery manifests
record the saved file fingerprint; earlier snapshots remain historical records.

## MIDI sync addition

Section 27 groups six approved-direction sync references. Current UX now contains
194 screen references in 27 sections, without section overlap. Eight MIDI headers,
Settings and three loop-clock references were updated in place. Native checks
cover 567 text nodes and 990 element bounds with no discrepancies. The Pen file
was saved through its native File menu after exporting the reference gallery.

The Wave refinement updates existing frames in section 25 and the function picker
in section 24. Frame and section totals remain 194 and 27. Its native text and
element checks pass, and the shared galleries now show continuous waveforms
derived from reference audio, spaced bars/layers/FX metadata and the same
waveform ruler as the browser. The previous block-bar artwork is replaced in
place, including the small and paired displays.

The compatible-only mode-change flow updates Loop mode and replaces the blanket
content-lock reference in section 05. Its playback confirmation adds one screen
to the same group: 195 current references across 27 sections. Subsequent groups
in the right column move down one row; outer region bounds stay unchanged. Native
checks cover 53 text nodes and 241 elements with no alignment errors, section
overlaps or containment errors.

## Audio device addition

Section 28 contains seven revised device references, including automatic latency
measurement and its cable fallback. The rejected interface-picker-first draft is
replaced in place. Current UX has 202 references in 28 sections. The outer region
extends down to retain section spacing; Design System and Superseded move below
it. Native verification covers 268 text nodes and 487 elements with no alignment,
section-overlap or containment errors. The interface name has an explicit light
color. Existing-audio mode changes are marked owner accepted.

Wi-Fi adds eight accepted references in section 29, with a compact connection
row, IP address and aligned Manage popup. The current region has 210 screen
references. Section bounds and typography were verified; the old large-card
Wi-Fi draft is replaced, not retained as a competing proposal.

Displays adds six accepted references in section 30. Track display comes first, matching the appliance. Current UX has 216 screens in 30 groups; section containment, overlap and text/element alignment checks pass.

Storage adds six accepted references in section 31. Current UX now holds 222 screens in 31 groups. Capacity, eject and recovery screens have verified geometry.

Power adds five accepted references in section 32. Current UX now holds 227 screens in 32 groups. Safe shutdown and restart states have verified geometry.

Updates adds six accepted references in section 33. Current UX now holds 233 screens in 33 groups. Update and power references have verified geometry.

Session backup adds six accepted references in section 34. Current UX now holds 239 screens in 34 groups. Library preview references use the accepted waveform layout. Native text and dimensions, section overlap and containment checks pass.

## Looper X comparison corrections — 8 September

The native Codex correction pass updated 34 existing references in place and
added seven About, controller and MIDI sync references in section 35. Together
with the two custom LED palette references added during consistency work, the
current gallery now contains 248 screens. Earlier acceptance records remain;
new correction behavior is available for review and does not imply production
audio or hardware support.

All 41 changed screens were reimported from the full-size prototype geometry,
checked in Pen, saved and exported. Native verification covered 1,867 text
labels and 3,899 element bounds without alignment discrepancies. All 35 current
sections remain inside their region, with no section or top-level region
overlap. Design System and Superseded remain below Current UX.

The [saved manifest](fx-ux-previews/pen-sizing/manifest.json) records the changed
frames, native checks and saved design hash. Use the
[correction review](parity-review.html) for interactive examples and the
[Pen gallery](fx-ux-previews/pen-sizing/index.html) for the exported references.
