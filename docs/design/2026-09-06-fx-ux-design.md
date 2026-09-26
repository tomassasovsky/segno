# Segno FX: sound first, pedal assignments second

Date: 2026-09-06. Design study under the appliance roadmap, issue 919.
This records an evolving interaction study. It is not production implementation,
DSP parity, appliance validation or a completed plan review.

**Latest owner review: the owner tested the revised add/edit/order/save journey,
called it intuitive, and requested continued work.** Sizing and native Pen
rendering have a separate correction pass. The filled sliders retain double-tap reset, with
no standalone Default button. The earlier signal-flow diagram layout remains rejected;
the owner explicitly requests plain connections between consecutive racks
and pedals, without arrowheads. This does not revive the rejected technical routing overview.
The owner preferred the context-based replacement and requested Auto monitoring,
removal of selected-tab underlines, and clearer shared-track processing. The page
now has Live inputs and Recorded tracks; All tracks sits beside the individual
recorded tracks. This revision has passed author-side browser checks and awaits
further visual review. The larger-screen study now opens a rack directly into
an inline pedal editor. The former rack menu, module list and generic parameter
dialog have now been removed from the interactive journey.
The design must cover: effects on one recorded input within a track,
and clear distinctions between hearing live input, recording, playback, and rack
enablement. A rack being enabled does not by itself establish audible output.

[Open the interactive prototype](fx-ux-prototype.html) ·
[Connected pedal editor](fx-ux-prototype.html?review=pedal-chain) ·
[Paired display preview](fx-two-screen-preview.html) ·
[Original Looper X image atlas](../research/sheeran-looper-x-1.0.2/rendered/atlas.html) ·
[Implementation roadmap](../plan/2026-09-05-feat-appliance-ux-roadmap-plan.md)

## Simplicity assessment

The owner made self-evident, self-describing interaction the highest appliance
UX priority. The [simplicity review](2026-09-06-fx-simplicity-review.md) identifies
redundant navigation and the generic parameter dialog. The current revision
replaces both the rejected flow diagram and the competing rack collection
entrances with a single context-based rack page. The larger-screen study now
implements direct sliders and per-effect power; verified native units and
discrete choice descriptors remain unresolved.

## Owner decisions and design response

The owner requested full design freedom, appliance-only Linux UX, retention
of macOS for small development tests, focused settings destinations with
submenus, and rotary encoder navigation with visible focus alongside touch.
They asked to start with the exact Looper X rack families, presets, effect
identities and original artwork, including effects without working DSP.

The owner found the original rack selector cleaner than the earlier Segno
proposal and authorized simplifying the latter. The library now gives Ed's
Rack a dedicated wide entry, Single FX its own entry beside it, and the eight
remaining rack families two rows of four. Only the focused item has a prominent
border. Repeated counts and decorative card backgrounds were removed.
This follows the source selector's special wide first slot without copying
all original appliance limitations.

**Screen roles remain undefined.** The owner confirmed a 7-inch and a 15.6-inch
screen, then clarified that neither role is settled for this redesign. The
existing implementation uses the small display for a performance readout and
the large one for detailed interaction; this is precedent, not an accepted
constraint. Do not infer future roles from the current app.

The [paired display study](fx-two-screen-preview.html) shows **one unselected
option**: detailed tasks on the larger panel and persistent performance facts
on the smaller one. Other divisions of work remain open. The FX prototype is
a task-surface study, not an assignment to a physical screen. Removing its
routine footer is an owner decision independent of the eventual screen roles.

All prototype routes and all 22 `FX UX 2026` screen frames now use a single
1920 × 1080 logical canvas. The earlier 1280 × 720 canvas has been removed.
This standardizes the current review surface; it does not assign physical
screen roles or establish pixel density.
The source describes a 1024 × 600 small panel with compositor-dependent logical
sizing; actual displays, scaling, readability and reach need device checks.
The Looper X reference is 1280 × 800.

The shared sizing contract is:

| Element | Logical size |
|---|---|
| Page title | 42 px |
| Main control labels | 24 px |
| Secondary labels and values | 20 px |
| Primary buttons, modes and power controls | 64 px high |
| Sliders and floating scroll controls | 56 px high |
| Navigation icons | 28 × 28 px, centered |
| Header | 96 px high |
| Page side inset / section gap | 36 px / 24 px |

Track names use 22 px, identifiers use 18 px, and library family titles use
32 px (38 px for the wide Ed's Rack entry). Those differences express hierarchy;
individual pages no longer choose a different general control scale. Eight
tracks plus All tracks remain together. Input and FX strips retain horizontal
scrolling. Longer parameter lists scroll vertically with centered cues.

The default browser preview scales this whole canvas to its panel. Add
`&canvas=actual` to a review URL for an unscaled logical-pixel view; this is still
not physical calibration. The independent two-display study remains an unselected
role proposal. Existing application references outside the `FX UX 2026` study
have not been redesigned by this sizing pass.

The first Pen import exposed two defects: text wrapping inside constrained
imported boxes, and omitted arrows whose browser wrapper used `display: contents`.
The corrected frames use measured full-canvas geometry, native text bounds and
explicit scroll cues. Browser checks and Pen visual checks are separate evidence.
A four-destination Settings menu leads to Effects, Loop settings, Connections,
and Device. Effects opens the current sound's racks directly. Other settings
entries are explicit design boundaries, not completed functionality.

## The current FX journey

| Destination | Purpose and next step |
|---|---|
| Effects → Live inputs → Guitar / Vocal / input | Show that live input's racks and its Hear live Off/Auto/On control |
| Effects → Recorded tracks → track | Show Whole track processing and its separately recorded inputs |
| Recorded track → Effects on → Guitar / Vocal | Edit only that separately recorded input, before the whole-track processing |
| Effects → Recorded tracks → All tracks | Process the recorded-track mix; live monitors are outside this existing engine stage |
| Add rack → family → preset | Add an independent instance to the selected sound; the target stays explicit |
| Rack → connected pedal editor (larger study) | Edit beneath each pedal, change activation or save a preset; input and rack names stay visible |
| Pedal assignments → bank → position | Inspect switch relationships and open the same rack objects |
| Back | Restore the selected sound and recorded input; never silently apply an edit |

The rack view shows only the selected sound's racks, in processing order. There
is no All racks page, global location table, separate Input FX entrance, or
flowchart. Presets are reached through Add rack. Racks form one horizontal strip, in processing order. Four are fully visible
and the next rack peeks into view. The strip has no product rack-count limit;
scrolling and encoder navigation reach the remainder.
The base fixture includes fourteen racks, including independent guitar and vocal
copies on Track 1. The populated review fixture has ten racks on Guitar and ten
on Track 1; these are demonstration sounds, not a DSP capacity claim.

The recorded-input picker offers only parts present in the selected track.
Whole track remains a distinct processing target. Changing tracks resets the
part selection to Whole track. The empty-track fixture has no recorded parts;
adding recorded FX is disabled there. Preparing processing before
recording is a separate journey still to design, not an engine limitation.

## Hearing state and source ownership

Hear live offers Off, Auto and On per input. On keeps monitoring enabled; Off
keeps it disabled. Auto enables it while **any** track fed by that input is armed
(including a pending quantized arm), recording or overdubbing. Playback alone
leaves Auto closed. An unrelated input's capture does not open it, and one track
ending capture cannot close it while another qualifying track remains armed.
The selected Auto mode stays visible alongside its resolved Live on/Live off
state; when open, the current track and capture state explain why.

This follows the existing `MonitorMode`, `monitorResolved` and `_autoArms`
contract in [looper_repository.dart](../../packages/looper_repository/lib/src/looper_repository.dart)
and [input_monitor.dart](../../packages/looper_repository/lib/src/models/input_monitor.dart).
The Looper X source also exposes On/Auto/Off, but the prototype's exact resolution
rule is grounded in Segno's code, not assumed to reproduce native Looper X audio.
Prototype lab controls supply arm/record/overdub fixtures without recording audio.

Changing monitoring mode retains rack configuration and pedal assignments. Playback
controls are absent from FX setup. Card styling shows effect eligibility, not
measured sound at an output. An enabled rack can coexist with monitoring off
or a stopped track.

These controls simulate state only. Fixed recording-input fixtures are used to
resolve Auto. Recording itself, editable destinations, track/input mutes, output
routing, gains, metering and effect tails are not modeled here. The
complete audibility journey remains a validation requirement; the current study
must not call a playing track or enabled rack proof of audible output. Physical
display allocation remains open.

The existing native order is recorded-input FX, track FX, recorded-mix FX, then
addition of live monitoring, followed by output gain/limiting. The engine's
current Master FX does **not** process live monitoring. Its routing additionally
limits processing to the first enabled output pair; the design label alone does
not resolve that production limitation. See
[engine_process.c](../../packages/segno_engine/src/core/engine_process.c),
`mix_tracks_frame`, `master_fx_frame`, `mix_monitors_frame`, and `master_bus_frame`.

Fresh recording copies a live input's eligible FX chain by value to its recorded
lane; later input edits do not alter that take. The original audio stays dry.
The prototype's recorded parts are explicit fixtures demonstrating separate
ownership, not a recording implementation. See
[looper_repository.dart](../../packages/looper_repository/lib/src/looper_repository.dart),
`record` and `_snapshotMonitorChainsOntoLanes`. Per-input processing requires
separately recorded parts; it cannot separate sources already merged into audio.

## Track visibility and navigation icons

The follow-up review caught two missed issues: the review page forced a 1280px
container into a narrower browser panel, and the fixture exposed only four of
Segno's eight tracks. The preview now scales the full appliance surface to the
available panel width. This is preview fitting; the two physical display roles
remain undecided. The recorded-track selector shows Track 1 through Track 8 and
All tracks together in one row. Tracks 4 through 8 are empty fixtures and remain selectable.

The long-name study (`?review=long-tracks`) keeps each track number visible,
allows two lines for its name, and truncates only the selector label with an
ellipsis. The source selector owns the label; its accessible name retains the
full text. The owner rejected repeating the selected source in the overview title.
The individual effect editor retains source context because it has no source selector. Names are display labels attached
to stable track identities, so changing a label cannot move its racks.

Stopped/Play was removed from FX setup after owner feedback. Transport belongs
to performance controls; opening or selecting an FX target does not start, stop,
or solo audio. The author lab retains a playback simulation for behavioral
checks. Accurate audibility feedback remains a separate design requirement;
this revision does not claim that an enabled effect is necessarily audible.

Back, next/previous, dropdown, reorder and value-edit icons now use centered SVG
geometry in a consistent 24px box. Font glyphs were the cause of uneven arrow
placement; the original Looper X artwork is unchanged. Browser checks cover
682px, 1024px and 1328px panel widths, all nine track selectors, second-bank Auto
monitoring, icon centering and encoder access to the last rack after scaling.

## Scaling the visible source row

The owner preferred visible tracks over the proposed destination dialog. That
chooser was removed. Eight tracks and All tracks remain visible together; names
use two lines, with the full name retained in the accessible label.
Inputs use the same visible horizontal strip. The `?review=many-inputs` fixture
has eighteen inputs. A partial next input, previous/next arrows and visible range
indicate additional channels. Input browsing and rack browsing have independent
positions: scrolling inputs does not switch the edited source or move its racks.
Touch, wheel/trackpad and encoder focus can reach every source. Back and context
switches preserve each strip's position. Scrolling does not change the selected
source. The later title-cleanup decision removes the repeated source breadcrumb;
when that button scrolls offscreen, its label is no longer pinned separately. The owner's reference to outputs was corrected
to inputs; this study does not add output processing destinations.

## Visual rack activation

Enabled cards have a slate-blue background and border, bright original artwork and a
lit power symbol. Inactive cards use a muted surface and dim, desaturated artwork.
Bypassed cards also have a dashed border. FX on/off text was removed from these
cards, while accessible button labels retain the state. Pedal-condition text
still identifies the assignment (including inverse conditions); it does not
replace the visual state. The amber encoder outline is independent of activation.
The `?review=fx-states` fixture shows enabled, inactive and bypassed racks together.
These are activation states, not an assertion that sound reaches an output.

## Artwork and horizontal rack browsing

The owner accepted the context-based UI direction, requested corrected artwork
alignment, and asked to evaluate horizontal browsing with more than four racks.
Wide rack banners now occupy fixed aspect-ratio frames aligned to their preset
labels. Catalogue rack and pedal illustrations occupy fixed, centered slots;
labels share their alignment and the artwork cannot shrink under a wrapped name.
Original assets remain unchanged. Ed's Rack retains its wide library entry.

The populated study is available as `?review=scroll-input` or
`?review=scroll-track`. Both contain ten racks on Guitar and ten on Track 1.
One horizontal strip keeps the processing order visible while monitoring and
Add rack controls stay still. A partial next card indicates overflow;
previous/next controls and a visible range appear only beyond four racks. Names
can occupy two lines; the full name remains the button's accessible text.

Touch uses native horizontal panning. Wheel/trackpad movement over the strip
scrolls it; the encoder selects racks and reveals the focused rack completely.
Scrolling never changes processing order or opens a rack. Each sound remembers
its scroll position through pedal state refreshes, context changes and returning
from an editor. Edge navigation buttons disable at their corresponding boundary.

Horizontal browsing is the proposed default for this ordered rack collection.
It must still be tried at appliance scale; a long effect catalogue can retain
its vertical grid. The next test is whether a player can find the fifth and last
rack without instructions, then return without losing their place.

## All tracks and selection styling

The confusing Recorded mix peer tab was removed. Recorded tracks → All tracks
opens the single shared chain applied after the loop tracks are combined. It
has no input or per-track subsections. Vinyl and Quarter Pump are named rack
presets in that chain, using their original family illustrations; they are not
navigation categories. This processing does not include live monitoring.

Sound-type buttons use a filled selected state with a full border, and a separate
encoder focus outline. Neither selected nor unselected buttons use underlines.
The change preserves the difference between the selected context and encoder
focus moving to another control.

## Content fidelity and readiness

The generated catalogue contains **9 rack families, 159 exact preset files,
26 inventoried single-effect identities, and 66 original artwork files**.
The import script verifies the 225 copied preset/artwork files byte for byte.
Preset names, native type/version fields, raw parameters and source identities
are retained. A source spelling or trailing space is not silently corrected.

Single-effect display names interpret native icon identifiers; the native
ordering and full algorithm descriptors are still unverified. The prototype
groups preset keys by name prefix to make navigation inspectable. Those groups
and their displayed order are **design proposals**, not recovered native
signal chains. Raw source values are shown without invented physical units.
Empty single-effect editors explicitly say their controls are unavailable.

The browser lab labels the prototype as a simulation with no audio. Raw-value
editors identify unresolved mapping. Production needs per-effect/preset readiness
states and truthful partial-support behavior; it must not silently substitute
another effect and call that exact sonic parity. The source preset copy stays
immutable; editing an instance never mutates the factory catalogue.

## Connected pedals and direct editing

The owner selected the [Rhythmic rack reference](../research/sheeran-looper-x-1.0.2/rendered/images/rack-rhythmic-rack-3.png)
as a useful direction. That image is a source-based reconstruction, not a hardware
capture. `AppUI/Pages/FxEdit.qml` supplies the connecting cable and pedal selector;
`FxEdit/Parameter.qml` uses sliders, state controls and discrete selectors according
to native descriptors. Segno's larger-screen study gives each pedal its own
controls beneath the original artwork instead of requiring effect selection first.

The [1920 × 1080 Funk Wah study](fx-ux-prototype.html?review=pedal-chain) shows
Delay, Parametric EQ, Low-pass Filter, Pumper, Reverb and Slicer in one connected
strip. Plain cable lines show their connection; left-to-right order defines the
chain. Each pedal has a single button containing its power symbol and effect name;
enabled pedals and controls are bright, while bypassed ones are muted. A pedal's
own enabled state and its rack's activation rule remain separate. The output level
belongs to the rack and sits after its controls. The overview also connects adjacent
rack cards. These are proposed processing orders, subject to the source-mapping
limitations above.

Six pedal columns fit across the study canvas. With standardized controls,
columns with longer parameter lists scroll vertically; the centered cue shows
that more controls are available. Longer chains scroll horizontally. There is no More/Less step: available controls
are visible under their own pedal. Unresolved mode, pattern and step-length
descriptors stay in the research data; empty or generic numeric substitutes are
not shown as working choices. Column scrolling is local; power changes and
encoder edits preserve the chain's position. New presets open this editor directly
throughout the prototype. The earlier list hierarchy and parameter dialog are
removed. Rack options holds rename, reorder and removal; the direct controls
remain the primary editing surface.

Touch moves the actual slider. Encoder focus selects it, press starts an adjustment,
turn changes the draft, and press finishes. Escape restores the exact opening value
without leaving the page. Double tap restores only that slider's loaded preset
value, without changing the other parameters or the effect's enable state. There
are no standalone Default buttons on this view. The reset is a verified preset
baseline, not an inferred neutral DSP default. Touch commits at the end of the
gesture. Pedal-triggered persistence excludes unfinished
encoder drafts. A completed-gesture Undo remains a recommendation, not implemented
behavior in this study.

The preset's stored normalized values are retained. Mix, feedback, depth and
resonance are presented as percentages of that stored range; they are not proof of
the native formatted values. Time, frequency and similar mappings remain normalized
decimals. Mode/pattern fields are preserved in the catalogue but omitted from
the working controls until their named choices, units and ranges are verified. This study makes
the layout and interaction reviewable without claiming recovered native descriptors
or working audio processing.

## Adding, arranging and saving effects

The [Add effects library](fx-ux-prototype.html?review=add-effects) gives the wide
Ed's Rack artwork its own space and keeps Single FX beside the rack families.
At the larger canvas size, the artwork and spacing expand with the available
area. The destination is stated once in the header; there is no repeated source
subtitle.

[Adding an effect inside a rack](fx-ux-prototype.html?review=add-effect) uses the
same full-page artwork catalogue as choosing a standalone effect. The cramped
text-list dialog is removed. Back cancels without altering the chain. Selecting
an effect returns to the rack, reveals the new pedal, and leaves it bypassed.
When a matching extracted module exists, its editable parameters and source
preset provenance travel with the new instance, as they do for standalone FX.
Unsupported parameter mappings remain unavailable; this does not implement DSP.
The added effect does not change the rack's pedal assignment or other effects.

The complete journey now returns from a newly added effect to the selected
input/track in one Back. Add, family and preset-selection steps do not remain in
the completed addition's Back history. Cancel from the catalogue changes nothing.
Saved sounds have a visible **My presets** entry in Add effects.

**Save preset** opens naming before creating a reusable copy. Saving does not
rename the active instance. A matching user-preset name requires Replace preset
or another name; cancelling keeps the previous preset. Factory definitions are
never overwritten. Loading a saved sound creates a bypassed, independently
editable instance on the chosen destination. It copies effect parameters and
channel settings, not a pedal rule or another destination. Replacing a saved
definition leaves existing instances unchanged.

**Reorder** on the source page arranges its rack/single-effect chain. **Rack
options → Reorder effects** arranges the modules inside one rack. Both use a
horizontal strip with the original artwork, plain cable lines and stable
identities. Touch can drag the grip or use Move left/right. Encoder press picks
up a card, turning moves it, and press drops it. Done commits the order; Cancel,
Back and Stage discard the draft. Rack output level stays after its effects.
Pedal events do not persist uncommitted ordering. Removing a rack preserves saved
presets; removing one effect keeps the other effects and rack assignment.

The focused author checks are in `verify_fx_journeys.cjs`; they exercise name
collision, cancellation, replacement isolation, target ownership, touch dragging,
encoder reordering and removal alongside the main visual/behavioral suite.

## Single effects alongside racks

The owner asked for a single FX without managing a rack. Add effects opens the
existing library, which offers Single FX alongside rack preset families. Both are
independent entries in the selected input or track's processing chain. A single
FX opens directly into its own controls and original pedal artwork, with one
power control, preset saving, and the same eight pedal-assignment positions.
There is no inner rack list or Add effect-inside-effect step. Channel labels read
Effect input and Effect output. This direct entry applies throughout the standardized canvas.
The [single Delay study](fx-ux-prototype.html?review=single-delay) makes it reviewable.

The prototype's single-effect controls borrow a matching module's parameters from
an extracted rack preset, with the source preset ID retained. The Delay study uses
Funk Wah's Delay values. These are explicit design-study starting values, not a
claim that native single-effect factory defaults were recovered. The module's own
enable parameter is engaged; the new effect instance starts bypassed. Missing
matching descriptors remain unavailable. Saving a preset copies its parameters,
channel choices and provenance. Grouping existing single effects into a new rack
is a separate journey still to design.

## Hidden parameters in the multi-FX view

Each pedal scrolls its own parameter column vertically. The chain continues to
scroll horizontally. The owner chose a simple floating chevron over a separate
navigation bar or count. Each chevron floats horizontally centered over its
parameter column and is excluded from encoder focus. It remains tappable. A down
chevron appears only while parameters remain
below, and an up chevron appears only while parameters remain above. Tapping
moves through the controls; vertical swipe and wheel work in the same area. A
partially visible next control also signals that the column continues.

Pedals whose controls fit show no arrows. The pedal name, artwork, and channel
controls stay in place. Encoder focus reveals the complete parameter including
its label, and edits, bypass changes, and cancellation retain each column's
scroll position. The single-effect editor is outside this change's scope.

The [Ed's Rack overflow study](fx-ux-prototype.html?review=parameter-scroll) uses
Acoustic Rhythm 1's extracted parameters, including the fourteen Four-band EQ
controls. Its separate `EQ 4-Band` enable value belongs to the power button.
This introduces no additional effect parameters or inferred native units.

## Design-system controls and channel handling

The slider track comes from `segno-ui.pen`'s reusable `ParamSlider` (`ThalA`):
53px bar, 12px corners and a 2px value edge, without a knob. The owner
rejected the vivid blue accent, then rejected green against blue-gray surfaces.
The owner then rejected a blue-tinted background. The current proposal uses a
near-black background, with muted slate-blue fills and pale blue-gray highlights
confined to controls, and darker inactive controls. The owner accepted the
near-black background. Residual green tints in shared surfaces, borders, text,
scrollbars and dialogs are now neutral gray; active glows, monitoring state and
edit highlights use the existing pale blue accent. Original pedal artwork keeps
its source colors. Pedal columns put the label and monospaced value above the bar to
fit their width. Fonts come from the existing Inter and JetBrains Mono assets.
The earlier thin tracks with round handles were rejected. On/off ownership is
explicit because the power symbol and effect name share a single button.

Reset follows the app's `ConsoleResetTap` principle in
[console_surface.dart](../../lib/common/console_surface.dart): the first tap writes
immediately, the second clean nearby tap restores the baseline, and a drag cannot
be half of a reset pair. This browser study uses a 300ms window, 28px between taps,
12px drag threshold and 250ms maximum tap duration. Cancelled and interrupted
pointer gestures clear the candidate. Physical sizing and encoder-only access to
reset still require appliance interaction review; this touch gesture does not
establish that complete hardware contract.

The owner also requested channel selection, pan and mono handling. The current
proposal belongs to each **rack**, before it feeds the next rack:

| Control | Proposed behavior |
|---|---|
| Rack input: Stereo | Preserve the incoming left and right channels before effects |
| Rack input: Left only / Right only | Use that incoming channel on both sides before effects |
| Rack input: Mono sum | Average incoming left and right, then feed both sides before effects |
| Rack output: Stereo | Preserve effect-generated stereo; Balance changes the relative left/right level |
| Rack output: Mono | Average the effect output to mono; Pan places it between left and right |
| Rack level | Apply the rack's level after its effects |

For a mono source already present on both sides, left-only and right-only receive
the same signal. These controls do not choose hardware sockets, split a recorded
mix into original inputs, or change whole-track mixer controls. Physical input
pairing and output-bus routing remain separate journeys. Pan/balance law and gain
staging need engine design and audio validation; the prototype stores and exercises
channel intent only. The existing `InputMonitor` model has a mono input index,
output mask, gain and FX chain; it does not already implement this proposed rack
channel model. Looper X's `Mixer/TrackBar.qml` supplies a pan-control precedent,
not proof of equivalent Segno processing.

Channel choices persist per rack, survive Back, and are copied into a saved
preset. The factory source files remain unchanged. Input and track source strips
now align with both content edges; padding retained for focus is compensated at
the viewport boundary. The overview has an Effects heading and the selected
source in its source strip, with no duplicate subtitle or source breadcrumb.

## State rules proposed by the prototype

The owner confirmed both latched and physical state sources. Each of eight
logical positions can drive many independent rack instances. These rules make
that requirement concrete for review:

- On/Off refer to a persistent latched state; Held/Released refer to the physical
  press. One down event toggles the latch immediately and begins Held. Release
  ends Held without toggling again. There is no hold-duration threshold here.
- A normal and inverse assignment can switch complementary rack combinations.
  Both state sources may drive different targets from one press. No general
  Boolean expression language is introduced.
- Bank changes select four visible controls; they do not alter rack activation.
  A down event captures its logical position, so release after changing banks
  still releases the original position.
- Each instance uses a stable identity. Renaming and reordering leave its
  assignment intact. Saving a sound makes a separate reusable definition.
- Manual bypass takes precedence over its condition. Resume control returns it
  to the saved rule. New rack instances start bypassed.
- Assignment edits use a draft and apply together. Back/Cancel discards it.
  The direct editor follows the gesture rules above. Unfinished encoder edits
  and uncommitted order changes are excluded when a pedal event saves the rig.
- Disconnect freezes effective activation and clears physical holds. Reconnect
  starts all physical sources released and reevaluates conditions. This may
  change momentary targets; the prototype announces that transition. This is
  a proposed appliance policy requiring hardware validation.
- Reload restores the saved rack/assignment/latch/bypass state. Physical holds
  begin released. Browser storage is only demo persistence, not the session
  implementation or a proposed production storage format.

Existing dry capture, frozen inherited input processing and recording-boundary
semantics remain production requirements. Changing a live input must not rewrite earlier takes; the prototype cannot
prove audio inheritance,
capture replay, resource budgets or real-time transitions.

## Encoder and touch

Buttons and inline sliders participate in encoder focus. Turn advances through the current screen
in a stable order and scrolls the selected item into view. Press opens or
activates it. Back returns to the previous screen and its selected control.
Dialogs restrict focus to their own controls. Routine helper prose and the main-screen bottom status bar were removed after
owner feedback. The task surface shows choices, relevant state and errors when present. Where
persistent performance information belongs remains part of the screen-role decision. The amber ring indicates focus;
the pale blue ring indicates active value adjustment.

Preset naming and rename use the same on-screen keyboard, reachable by encoder.
The former generic parameter dialog is removed; touch reset and direct encoder
editing remain on the parameter itself.

The browser lab controls simulate the encoder, two banks and four physical
pedals. Arrow keys/Tab move focus, Enter presses, Escape goes back, and the
mouse wheel turns the encoder while over the screen. These are test controls;
they do not add a desktop product requirement.

## Design source and verification

`segno-ui.pen` contains 22 standardized `FX UX 2026` review frames in one grid
beside the existing work. The library, live-input sounds, recorded-input sounds, activation, pedal bank and value editor record
the new visual and interaction direction. The 1920 × 1080 connected pedal editor
records the latest larger-surface proposal with original artwork and controls.
The HTML prototype is the executable
interaction study; the design file is the visual source. Review exports live
in [fx-ux-previews](fx-ux-previews/). The [Pen export gallery](fx-ux-previews/pen-sizing/index.html)
and [discrepancy review](fx-ux-previews/pen-sizing/review.md) record this sizing pass.

Author-side browser checks exercise more than eight instances, complementary
latch conditions, held release across banks, cancellation, draft isolation
during pedal persistence, rename identity, independent saved copies, loading
bypassed, disconnect/reconnect, independent monitoring/playback, Auto arm/capture routing, recorded-input
ownership, contextual Back, empty tracks and scrolling past eight racks, native browser touch swipes, horizontal wheel
scrolling, fixed controls, preserved scroll through editing, artwork alignment,
direct slider gestures, exact per-parameter double-tap reset, rejection of drag
and distant-tap reset candidates, per-effect bypass, longer pedal-chain scrolling,
and direct entry for existing and newly added racks on the larger surface.
The sizing gate checks every captured route for a 1920 × 1080 canvas, minimum
56 px control targets and page controls contained within the screen. These are
logical dimensions, not proof of physical usability. Thirty-six representative views are captured
with no Chromium browser errors or missing artwork. A separate Firefox run
checks the theme, local fonts, native range gestures, channel controls and source
alignment, and captures seven comparison views. Firefox uses its own range-track,
progress and thumb rules; the earlier WebKit-only rules caused native slider
fallbacks there. See
[verification results](fx-ux-previews/verification.json) and
[Firefox verification](fx-ux-previews/firefox-verification.json).

Reproduce with Playwright available to Node and a browser installed:

```sh
python3 -m http.server 8768 --bind 127.0.0.1 --directory docs/design
node docs/design/verify_fx_prototype.cjs
node docs/design/verify_fx_firefox.cjs
node docs/design/verify_fx_journeys.cjs
node docs/design/verify_loop_journeys.cjs
```

Set `ATLAS_CHROME` to use local Chrome and `FX_PROTOTYPE_URL` to use another
server. Regenerate original catalogue assets with
`python3 docs/design/import_looperx_factory.py EXTRACTED_DIRECTORY`.

## Implementation boundary

This study refines roadmap S03 (navigation/focus) and the S09–S11 FX sequence.
The next production slice should connect one complete input-rack journey to
existing repository/engine ownership and persistence, remove its superseded
UI path, then add capabilities on that working foundation. Factory data/artwork
availability, working DSP, audible reference parity and appliance budget proof
remain distinct milestones. The broad roadmap and original-reference gaps
are not marked complete by these screen designs.

## Owner direction: recording placement, tails and output effects

The owner requested explicit Pre/Post placement and a reverb that processes
live inputs and recorded tracks together. These are target requirements, not
limits to infer from today's engine. The prototype now exposes
them; All tracks remains only the recorded-track mix.

- **Record (Pre):** the processed sound becomes part of the recorded take's
  playback. Stopping the track stops that captured sound, including any captured
  delay/reverb tail. Retaining original dry material for recovery is compatible
  with this audible behavior; this requirement does not authorize discarding it.
- **Playback (Post):** processing is downstream of the loop player. Track Stop
  stops feeding recorded audio into that chain while delay/reverb already in the
  chain can finish. Ordinary Stop must not flush or mute a post-effect tail.
  Bypass, mute, clear and an explicit all-sound cut need distinct semantics.
- Live monitoring is a separate audible source. If a live input is still being
  heard, stopping a recorded track does not stop that source or its effects.
  Pre/Post labels alone must not imply that all output becomes silent.
- **Output effects:** provide a true output chain after all sources routed to
  that output are summed. A reverb there processes live monitored inputs,
  recorded tracks and other routed sources together. A source routed elsewhere
  is outside that chain. Do not quietly exclude click/backing audio if it is
  routed through the same output bus.
- Proposed canonical home: **Outputs**, beside Live inputs and Recorded tracks.
  Select the output mix and manage its racks with the same editor, assignments
  and preset flows. Preserve All tracks for effects on the recorded mix alone;
  it is not another name for this true output stage.
- A downstream output reverb can ring after a Pre-processed track stops. That is
  the output effect's tail, not continued playback of the stopped recording.

### Reviewed placement interaction

Placement is a direct **Pre / Post** segmented control in the same footer as
channel handling. It appears on live-input and individual recorded-track/part
editors, for both racks and single effects. One short consequence line changes
with it: “Recorded into loop” or “Can ring after Stop.” The owner rejected the
wordy dropdown and explanatory modal; neither remains. There is no tooltip.
Cards show only Pre or Post. Outputs and All tracks omit both the control and
card label because their placement is fixed after their respective mixes.

Input instances default to Pre; new recorded-track/part instances default to
Post. Placement is instance context, excluded from reusable sound presets along
with destination and pedal assignment. Reusing a preset applies the destination's
default, starts bypassed, and creates independent parameters. Output chains
always resolve to Post. Two named output mixes are illustrative fixtures, not
hardware detection or an implemented routing editor.

The overview orders Pre before Post, with a cable break between the stages.
Reorder moves effects within their stage. Changing the explicit switch moves
that instance to the end of the destination stage and preserves its identity,
parameters, channels, enable state and pedal assignment. The direct choice saves
immediately and retains encoder focus. It does not rewrite another input, track,
output, or saved preset. The separate module order inside a rack is unaffected.

### Target audio ownership and implementation requirements

Live-input Pre and Post are captured as distinct, independent processing
recipes when creating a recorded input part. The Pre result is heard as captured
loop material; Post runs after its player. Live monitoring hears the configured
input chain while monitoring is enabled. Later live-input edits affect future
takes and the live sound, not existing takes. The prototype still uses explicit
recorded-part fixtures and does not perform this capture.

On a recorded input part or whole track, Pre denotes processing committed to the
playback representation before the loop player. Original dry sources and prior
edit state remain recoverable. Changing that track's Pre settings or switching
placement is an intentional non-destructive edit; production must prepare the
replacement from original sources, avoid applying the old wet version twice,
and switch at an audio-safe boundary. Until preparation succeeds, keep the prior
working sound. Do not retroactively modify other takes. How background rendering
and undo integrate with overdub/capture needs an implementation plan and audio
validation; the prototype's immediate metadata change is not that renderer.

Ordinary Stop stops the player feed and captured Pre sound, while downstream
Post/output buffers can drain. Live monitoring is independent and can keep
feeding effects. Bypass, mute, clear and explicit all-sound cut must be separately
specified and tested; a stopped track is not permission to flush every downstream
effect. The rejected signal-flow diagram and transport controls remain absent
from FX setup.

### Verification of this slice

`verify_fx_placement.cjs` passes in Chrome and Firefox: direct touch/encoder
selection, focus, save/reload, parameter and assignment preservation, stage
ordering, recorded-input isolation, output selection and independent preset
reuse, absent redundant output controls, 18-input scrolling and 1920 × 1080
layout. Existing FX journeys, broad prototype and Firefox checks also pass.
These checks exercise configuration and navigation only. They do not prove
capture, DSP tails, simultaneous audibility, or physical touchscreen comfort.

Review routes: `fx-placement`, `fx-pre-post`, `outputs`, `output-reverb`,
`output-monitor`. Existing review routes retain the same canonical editor.

Current-source gap: `master_fx_frame` is upstream of `mix_monitors_frame`, and
the track-stage API says output is routed only while some lane is audible.
Neither present routing nor a DSP tail continuing internally proves the desired
output tail is heard. Implementation needs end-to-end audio tests for Pre stop,
Post decay, output FX over simultaneous live/recorded sources, monitoring off,
independent outputs, and all-sound cut. This remains UI design work, not a DSP
change or an audio-validation claim.
