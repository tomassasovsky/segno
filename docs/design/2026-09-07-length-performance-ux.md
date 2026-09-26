# Multiply and Divide performance

Part of appliance roadmap issue 919. The owner accepted the original combined
length workflow on 2026-09-07, then requested separate Multiply and Divide
functions to reduce pedal presses. That revision replaces the combined mode and
its intermediate Half chooser. The split is interactive and ready for review;
its completed visual design has not yet been accepted.

[Try Multiply](fx-ux-prototype.html?review=performance-multiply) ·
[Try Divide](fx-ux-prototype.html?review=performance-divide) ·
[Native review](length-previews/index.html).

## Musical behavior

Choose one recorded track. Multiply doubles its current audio end to end.
Divide keeps either its First half or Last half with one direct pedal action.
The exact retained bar or beat range appears beneath each action. Track selection
and Bank keep their roles throughout; there is no intermediate selection mode.
Pitch and playback speed remain unchanged. Two bars become four, allowing a longer
overdub phrase. Repeated Double commands compound: two, four, eight bars.

Doubling a divided phrase repeats the retained half; it does not recover omitted
audio. **Undo restores the previous length edit, including omitted audio.** Each
track has a shared history used by both functions. Further Undo actions walk back
that track's length edits, regardless of which function made them. The prototype
stores ordered beat references and edit history, so recovery is tested against
content order as well as length. It does not process audio.

First and Last refer to the current source timeline, including earlier length
edits. Reverse does not relabel those regions. Normal speed, Transpose, Fade,
Mixer level/mute, FX, live monitoring, tempo and future-recording defaults remain
independent. Stopped tracks stay stopped. Length edits are unavailable while the
selected track records or overdubs; other tracks remain selectable.

## Separate foot journeys

Multiply and Divide are independent choices in the pedal assignment picker.
The proposed default Custom Bank B Track 3 position uses Press for Multiply and
Hold for Divide. Holding enters Divide without briefly entering Multiply, and
release cannot then select a track or edit its audio.

| Physical position | Multiply | Divide |
|---|---|---|
| Track 1–4 | Select one recorded track | Select one recorded track |
| Clear, tap | Double length | Keep Last half |
| Undo, tap | Undo the previous length edit | Keep First half |
| Undo, hold | One Undo on release | Undo once at the hold threshold |
| Bank | Switch banks | Switch banks |
| Record / Play | Current transport-track intent | Current transport-track intent |
| Stop | Stop all simulated recorded tracks | Stop all simulated recorded tracks |
| Mode | Exit to normal Tracks | Exit to normal Tracks |

Entry selects the current transport track if recorded, otherwise the first
recorded track, and reveals its bank. Bank selects the first recorded track in
the next bank. Selection LEDs identify the edit target. An empty bank has no
selection; edit actions are disabled, Bank and Exit remain available. The diagram
and length readouts never enter encoder focus order.

Length actions resolve on release. In Divide, holding Undo for 800 ms runs recovery
once and consumes the release; it must never apply First half afterward. Holding
Last half, Double or Multiply's Undo runs one action on release, without repeats.
Canceling an unresolved gesture or leaving the mode does not apply that action.
If selection changes during a pending gesture, its action addresses the newly
selected track, following the owner's established selection policy. Every edit
rechecks available audio and capture state.

Exit preserves edits and recovery history. Normal-URL reload restores both and
returns performance mode to Tracks. Review URLs reset demonstration fixtures.
The display groups long lengths rather than expanding or hiding controls. Divide
shows the two current regions while keeping the complete track selector visible.
Its small marks are schematic content references, not waveforms or live meters.

## Prototype limits and native implementation

This silent study uses integer notated-beat references, with a one-beat minimum
and a 1,024-beat maximum to bound its demonstration arrays. Divide cannot split a
beat in this model. These demonstration limits are not an approved Segno recording
cap. Real audio requires sample-accurate lengths, fractional and free-time
recordings, the recorded timebase and denominator, storage headroom, and mode
relationships. Displayed musical length is independent of manual Speed.

The proposed native transition preserves the current source position where
possible and remaps it to the retained region's new origin. A position outside the
retained half wraps into that region. Other tracks and global tempo are unchanged.
This native timing policy still needs specification and listening tests; silent UX
acceptance does not establish an audible transition. Multi, Song, Sync, Band and
Free must preserve their explicit timing relationships.

Length recovery is separate from layer Undo. Production history must include
repeated regions and subsequent overdubs coherently, and invalidate or reconcile
stale length history when audio is replaced, cleared or imported. The browser
cannot verify those audio interactions. No engine, DSP or firmware changes are
included in this study.

## Reference and verification

The [official Looper X guide, Functions B, page 17](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf#page=17)
describes whole-loop length choices of half, double, four and eight times, with
unavailable choices dimmed and total length displayed. Extracted
`Pages/Footswitches/Length.qml` reads the longest-track length and formats it as
time. Neither source establishes retained-region choice or Segno's Undo policy.
Separate entry functions, selected-track scope and direct First/Last controls are
Segno's intended workflow, not a claim about undocumented reference behavior.

`verify_length_performance.cjs` checks Chrome and Firefox: independent entry,
exclusive hold entry, direct First/Last edits, stable track-pedal meanings,
repeated and retained audio order, shared recovery, hold/release arbitration,
cancellation, target changes during a hold, banks, capture guards, empty tracks,
bounds, independent state, Exit, normal reload and full-size layout. Speed and
Fade regression suites also pass. Pen uses the reusable hardware component and
verified browser text geometry. These are author-side checks, separate from CI,
production audio and hardware proof.
