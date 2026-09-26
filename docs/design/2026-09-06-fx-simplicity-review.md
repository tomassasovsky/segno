# FX simplicity review

Date: 2026-09-06. Scope: the current interactive FX study and original Looper X
QML. This is a design assessment and recommended revision, not a claim that the
prototype already implements these changes or that users have validated them.

## Governing owner requirement

**Simple, intuitive, self-evident and self-describing interaction is the highest
UX priority for this appliance.** Fewer words and fewer screens help only when
the controls still show their purpose, target, state and recovery path. Removing
visible controls while retaining hidden gestures would fail this requirement.
Physical allocation between the 7-inch and 15.6-inch screens remains undecided.

**Subsequent owner review:** the attempted signal-flow diagram was explicitly
rejected. Explaining routing is still required, but the box-and-wire layout must
not become the product interface. The replacement context-based rack page has passed author-side browser checks
and awaits owner review. The next visual proposal should return to the cleaner
Looper X references and express the selected sound target and hearing state
through focused controls. Do not treat this review's earlier recommendations as
owner approval of a layout.

## Findings

| Current design | What makes the task harder | Recommended disposition |
|---|---|---|
| Input FX and All racks are separate destinations | Both open the same instances and editor; users must choose an entrance before doing the work | One Racks surface with a source selector/filter, including All |
| Sound library is a peer of current racks | Stored presets and sounding instances look like competing places to manage sounds | Open Choose preset from Add rack or an explicit preset action; preserve the target source |
| Effects opens another four-choice landing page | Adds a navigation decision before displaying any racks | Effects opens Racks directly, with a clearly named Pedals view alongside it |
| Pedal view also opens racks | Useful context, but its generic Edit button obscures the task | Keep this view for switch-to-rack relationships; label its action Assignments and use the same rack/assignment editors |
| Parameter card opens a second, larger value | Repeats the object, covers surrounding controls and adds entry/exit steps | Edit ordinary values in their existing location |
| Every recovered parameter uses the same number editor | A normalized number does not reveal whether a parameter is a switch, a choice or a continuous control | Use the actual descriptor: explicit state buttons, a selector, or a slider/value control |
| Encoder edit → press for actions → choose Done | An extra interaction phase without a visible purpose | Press to adjust; press again to finish that adjustment; make recovery directly available afterward |
| Default is mistaken for an explanation or an undo operation | Returning to a preset baseline differs from reversing a recent change | Keep a real Default action where the baseline is known; provide separately scoped Undo for immediate edits |
| A footer and explanatory sidebars surround routine tasks | Repeated state and prose compete with the controls | Already removed; keep essential local state and actionable errors |

## Current replacement for review

Effects now has Live inputs and Recorded tracks contexts, with All tracks beside
the individual tracks. The owner found the separate Recorded mix label unclear. Each
shows the selected sound's ordered racks in the same page. A recorded track
adds an Effects on selector for Whole track or one separately recorded input.
The library opens contextually from Add rack, and Pedal assignments opens the
same rack objects. Hear live includes Auto with a separate resolved monitoring
state; the selected context uses a filled button without an underline. The global location table and flow diagram have been removed.

This supersedes the earlier proposal for an All-source rack filter. The owner
asked for understandable sound ownership and rejected the technical diagram;
a global list of every processing point did not solve that task. The extra
Segno capabilities remain requirements, while Looper X supplies visual and
interaction references rather than a fixed product structure.

## Subsequent rack browsing review

The owner accepted the revised layout direction and asked to see more than four
racks on one input or track, with a preference to evaluate horizontal scrolling.
The prototype now demonstrates ten racks on each in one strip, with a partially
visible next card, conditional scroll controls and encoder auto-reveal. It keeps
context controls stationary and preserves the scroll position through edits.
Wide artwork and portrait pedal illustrations use distinct fixed image frames
with consistently aligned captions. Physical appliance validation remains open.

## Direct editing: current larger-screen study

For a continuous parameter, keep its name, actual formatted value and visible
slider together. Touch can drag it directly. Encoder focus identifies the
parameter; a press begins adjustment, turning changes it, and the next press
finishes that adjustment. The selected control visibly changes state during
adjustment. Avoid a separate “choose actions” phase and instructional paragraph.

For on/off, show the actual two states. For a discrete model, division or mode,
show the current named choice and a visible selector. A long choice list can
open a focused picker because it introduces choices that cannot fit inline;
it should not open another generic numeric editor.

For direct edits, recommend one visible, parameter-scoped Undo action after a
completed gesture. It reverses that gesture, including a Default operation.
Default returns to the loaded preset baseline where verified. A different
parameter becomes the new undo target only after its edit completes; selection
alone must not discard recovery. Returning to the previous page must not trigger
an accidental edit. The editor must distinguish browsing from adjusting by more
than color alone. Touch and encoder share one value and gesture owner.

The owner subsequently requested a larger pedal-chain view with inline editing,
using the Rhythmic rack reference. The 1920 × 1080 study now implements direct
design-system filled sliders, adapted to a consistent slate-blue FX palette, and a combined
effect-name/power button beneath
six connected pedals. More/Less and standalone Default buttons have been removed.
Double tap restores the touched slider's exact preset value. Unresolved Mode and
pattern controls remain in research data until their choices are verified. Longer
chains scroll horizontally. Within an overflowing pedal, floating up/down
chevrons indicate hidden parameters and scroll that column without a count or
extra navigation bar. They disappear at the respective ends, and fitting pedals
have no arrows. Encoder
press starts and finishes an adjustment; Escape restores the opening value. Touch
commits on gesture completion. Completed-gesture Undo is still a recommendation.

This replaces the modal entry path on the larger study. The compact comparison
still contains the earlier modal behavior. Native physical units and named discrete
options are not yet recovered: the remaining normalized continuous fields are research controls,
not final production descriptors.
Assignment changes, destructive actions and session replacement have different
consequences and need their own explicit commit/recovery rules; this proposal
is not a blanket removal of confirmations or application boundaries.

An enlarged value editor earns a place only if physical testing demonstrates
that precision or readability cannot be achieved inline. The two physical
screen roles are open, so the current canvas alone cannot establish that need.

## What the original source establishes

The following paths are relative to the supplied extraction:

- `AppUI/Pages/FxEdit/Parameter.qml`: continuous controls use SetValue directly;
  two-state controls expose Off and On; discrete values display a named value
  with a dropdown affordance. Visibility depends on native value descriptors.
- `AppUI/Controls/SetValue/SetValue.qml`: drag position writes the normalized
  translator value directly. This establishes the UI request, not acoustic
  behavior on the physical appliance.
- `AppUI/Pages/FxEdit/ParamsPanel.qml`: one selected parameter, formatted values
  and units supplied by translators, effect-specific subpages.
- `AppUI/Pages/FxEdit.qml`: parameter selection routes to the native edit target;
  discrete parameter menus use a separate choice popup.

The original interaction distinguishes control types. It does not justify
copying native descriptors we have not recovered, inventing physical units,
or calling a source-normalized value a complete user-facing control. Raw preset
values remain research evidence. Production controls need verified descriptors.

## Validation before calling the result self-evident

Use short tasks without coaching: add a vocal sound; change one parameter;
restore its preset value; undo an accidental edit; make one pedal alternate two
sounds; find and edit that same rack from both contexts. Exercise touch and
encoder separately. Record wrong turns, accidental changes, requested help and
recovery failures rather than just completed clicks.

Observe on the actual appliance at the expected stance, reach and viewing
distance, after the screen roles are selected. Green browser checks cannot
establish physical legibility or first-use understanding. The design review
should explicitly answer:

1. Can the player identify the source, rack and control being changed?
2. Is the next action visible and named by its result?
3. Does every adjustment give immediate, truthful feedback?
4. Is the active encoder target and state unmistakable?
5. Can an accidental change be recovered without instructions?

[Current design study](2026-09-06-fx-ux-design.md) ·
[Current interactive prototype](fx-ux-prototype.html)

### Long names and transport placement

The owner questioned long track names and the Stopped/Play controls on FX setup.
The next review keeps track numbers visible, gives names two lines, and shows the
selected name in full below the Effects heading. Playback controls were removed from this
page. The long-name fixture is `fx-ux-prototype.html?review=long-tracks`; selection
retains stable track identities and never triggers playback.

### Visible sources and visual activation

The owner rejected hiding the tracks in a chooser. Eight tracks remain visible;
eighteen inputs use a horizontal strip, with independent source and rack scroll
positions. The source chooser was removed. Enabled racks are bright green with a
lit power symbol; inactive racks are muted and bypassed racks also use a dashed
border. The cards no longer use FX on/off text to communicate state.


## Sizing pass

The owner authorized standardizing the current FX study. All prototype routes
and the current Pen study frames share the 1920 × 1080 canvas and the sizing contract
in the [design record](2026-09-06-fx-ux-design.md). Six pedal columns remain visible;
longer parameter lists scroll instead of shrinking controls. Browser-fit scaling
is a review convenience, not hardware validation. The earlier dialog comparison has since been replaced by the named-preset
save flow. The physical display
roles remain undecided.

The owner caught defects during the Pen update. The correction pass addressed
unintended text wrapping, native font bounds, and missing floating arrows. Pen
rendering must be checked independently from the browser; successful browser
checks do not certify the design-file rendering.


## Owner-tested journey update

The owner tested the add, direct edit, reorder, name/save and reuse flow and
described it as intuitive. The former rack/menu/module/parameter hierarchy is
removed from the executable prototype. My presets is reached from Add effects;
named copies, replacement and source ownership are explicit. Ordering uses the
same horizontal artwork strip with cancellable touch/encoder movement. See the
[current interaction contract](2026-09-06-fx-ux-design.md#adding-arranging-and-saving-effects).

The next [Loop setup study](2026-09-06-loop-setup-ux.md) was challenged for being
too generic. The owner wants the personality of musical equipment while keeping
mode selection simple. The proposed full track timeline was dropped. Recording
and tempo receive the richer task-specific treatment; loop mode stays five clear
choices. The first version required further owner review; the later decisions below
record the accepted provisional baseline.

The owner accepted compact diagrams inside the five Loop mode choices, then
requested slightly smaller cards. Recording's pictogram cards were rejected as
too much; it now has two compact rows for the start trigger and second pedal
press. Timing stays on one page, with a tempo area above aligned click/count-in
rows. The owner rejected splitting it into more menus to solve crowding. These
are the provisional baseline; loop length and quantization are the next slice.


The per-track Length & quantize extension keeps one editor for Defaults and all
eight tracks. The owner rejected nine large cards as overly prominent navigation
and accepted a compact numbered selector with the selected name alongside it.
The owner also requested wider horizontal padding: the title, selector and
settings rows share a 100 px inset on the 1920 px canvas. Each field independently
shows Default or Custom, with Use default only when an override exists. This is
an interactive design proposal; engine integration remains separate.

The final selector order is Tracks, Defaults, 1–8. Tracks is a static row label;
Defaults aligns with the Auto/Bars controls below. The owner preferred this to
adding a New recordings label or offsetting the selected button into the margin.
