

=====
# PR #1011 feat(console): accepted Tracks view, selected-track display and first-take crown
branch claude/segno-app-implementation-7c90a8 <- master
118 files changed, 5113 insertions(+), 7276 deletions(-)
---
commit 37a245eb 2026-09-09
feat(console): accepted Tracks view, selected-track display and first-take crown

Slice 1 of the accepted Segno design (epic #1009). The main display shows
the accepted stage: four columns for the active bank with name, primary
crown, number, bars, layers and the FX marker over one dB-linear whole-track
meter with a clip cap, a queued-action cue inside the track, a thin bottom
progress bar and shared dBFS scales; the top bar carries Library, the
session name, the bank, the Track/Wave view menu and Settings; the footer
carries tempo, signature, elapsed time, the output level and the loop mode.
The 7-inch display follows the selected track (number, crown, name, state,
bars, its own waveform with a bar ruler). The engine crowns the first
completed take and clears the crown when the session empties; the snapshot
gains a per-track playhead and the master-bus peak. The volume overlay,
the old status bar, the readiness strip and the TrackIndicator theme are
removed.

Closes #1010

---
commit 533d8585 2026-09-09
fix(console): act on the slice-1 review findings

Engine: configure drops the crown with the tracks it empties, a
non-defining finalize reconciles the crown, and the snapshot publishes
what a pending arm waits for (pending_trigger).

Stage: the queued cue reads the engine's trigger (Sound / Loop start /
grid) and names punch-out and section arms; the footer shows the
count-in; the clip cap retires on a timer; wave rows and the second
display read a waveform once per content change; the bar ruler paints
in its own layer; the readout gate ignores a growing take and follows
the cursor, not only the label.

Package lint infos that failed CI are cleared.

---
commit 8986bc05 2026-09-09
fix(console): keep the waveform copy in the repository, swept per lap

The engine's per-track visual buffer is a lazily swept tap: a bucket is
rewritten as the playhead leaves it, nothing is written during a
defining take, and a recording track contributes zeros. A copy keyed on
the track's steady facts therefore froze a flat or stale shape after a
take, an undo or a stop. The copy now lives in
LooperRepository.readTrackWaveform, re-read on every call until the
playhead has swept a full lap past a content change, on every call
while capturing, once per lap at the wrap while moving, and never while
the track stands still; a session load drops every copy.

Also: a queued take-end reads Play (Overdub under rec/dub, projected as
TransportState.recDub); the arm publish is release/acquire ordered so a
fresh arm never pairs with the previous trigger; the ruler layer sits
over the wave again; the footer count-in reuses countingInLabel; the
clip cap's state is its timer; a split view test is whole again.

---
commit ab914391 2026-09-09
fix(console): sweep the waveform copy on the clock the engine taps

The tap is bucketed on the master loop (the track's own loop in Free and
Song mode), so a track's progress was the wrong lap for a multiple and a
Sync division. Copies of tracks that lose their content, or vanish with
a stopped engine, are dropped on every projection so a later take under
the same steady facts starts its own sweep. setRecDub re-projects so the
queued take-end cue reads the setting on the next frame; the ruler test
asserts the layer order.

---
commit ec3e25f0 2026-09-09
chore(engine): drop the analyzer excludes a local flutter run added

Tooling side effect that rode the previous commit, not a change.



=====
# PR #1013 feat(engine): mode rules and reversible edits for the accepted design (slice 2a)
branch claude/segno-slice2-edits-1012 <- claude/segno-app-implementation-7c90a8
34 files changed, 3244 insertions(+), 497 deletions(-)
---
commit fb58fff3 2026-09-09
feat(engine): mode rules and reversible edits for the accepted design (slice 2a)

Mode changes with recorded audio follow the accepted contract: the engine
measures the gate (le_engine_looper_mode_gate: open, capturing, queued,
spans, playing); Multi needs equal spans, Sync and Band whole multiples or
the played divisions of the primary, Song and Free take anything; a
playing rig is stopped ahead of the switch in ring order and the switch
re-clocks the takes for the target. Captures, queued arms and unfit spans
refuse with their reason. Nothing is cleared, trimmed or stretched, and
the old clear-then-switch flow is gone.

Undo during an overdub punches out now and peels the pass once it
retires; undo during a take cancels it, finalized at its captured length
and held for an immediate-playback redo (LE_CMD_CANCEL_TAKE,
LE_EVT_TAKE_CANCELLED). A user clear on a capturing track freezes the
take stopped and keeps it restorable (LE_EVT_CLEAR_FROZEN). Clear All is
one grouped edit in the repository: undo on any member restores every
member, redo re-clears the group.

The console confirm dialog wraps long button labels.

---
commit 7dd83dcf 2026-09-09
fix(engine): close the slice-2a review findings

A cancelled take that captured nothing acks its state command once; the
cancel's control side no longer pre-zeroes the published length, since
the audio thread declines a cancel that raced a finalize; a late cancel
report is ignored after a clear or a fresh take; an undo queued behind a
freezing clear restores the frozen take instead of peeling a layer; a
freezing clear on a take with nothing captured keeps nothing.

Multi's gate measures whole multiples of the shortest take (what Multi
itself records); both threads measure against one base-channel helper;
the switch into a shared-clock mode re-establishes the tempo grid.

The remembered and persisted looper mode follows what the engine
reports; the mode flow re-checks the gate after the confirm; the
repository owns whole-rig recovery (undoClearAll), groups only takes the
clear can give back, stands down without forgetting while a member's
point is pending, and re-clears a group only when every member's next
redo is that re-clear (le_engine_redo_reclears). Stale content-lock
comments and tests are updated.

---
commit 438df12c 2026-09-09
fix(engine): close the second slice-2a review round

A record pressed behind a cancel in flight resets the grid the cancel
would have set; an undo tapped behind a freezing clear on a recording
take waits for the restore point; a clear right behind a queued restore
measures the length the restore will publish and keeps a restore point;
a declined or void cancel still reports so its flag never lingers; an
empty track never shows peelable layers on the wire (the depth is held
while a frozen point is pending or a restore is in flight, republished
once applied — the fuzz suite's depths-sane invariant); a fresh capture
drops the frozen take's layers with its pending point.

The repository takes clear-all membership from the engine
(le_engine_clear_restore_pending beside undo_restores_clear), ends a
group when the engine retired a member's point or a single clear
happens, and drops a mode request the reports never confirm.

---
commit 6984a486 2026-09-09
fix(engine): close the third slice-2a review round

A clear right behind a queued restore records the master grid that
restore re-establishes, not the wire's 0; a cancel of a take that
captured nothing empties the track without the clear handler's
layer-generation bump (only a control-side clear matches it, and a
mismatch dropped every later retired layer on the track), and the
count-in grace abort takes the same path; the repository keeps
unconfirmed frozen members apart from the clear-all group and drops one
whose capture held nothing instead of ending the group; the restart
replay of the looper mode is armed as a request so the first report
after a start cannot overwrite the remembered mode.

---
commit fd13ca36 2026-09-09
fix(engine): close the fourth slice-2a review round

A record pressed behind a queued restore of the only take measured the
wire master (0) and took the defining path; the press now reads the master
the pending restore re-establishes. The repository counts a frozen
clear-all member as a member from the clear (the engine queues the tap),
restores the chains for an undo tapped at a frozen clear, and gives a mode
request six polls of a running engine before dropping it.

---
commit a8ed5305 2026-09-09
docs(plan): record the fourth slice-2a review round

---
commit 222c3e03 2026-09-09
fix(looper): close the fifth slice-2a review round

An undo tapped at a frozen clear is held until the engine files the point,
then taken; a capture that held nothing is forgotten rather than restored
onto an empty track, and leaves the restored group's redo. A frozen capture
comes back audible. The round-4 native test now arms with quantize on so it
fails without its fix. The mode request window is twelve polls.

---
commit 6cdfb9fb 2026-09-10
fix(engine): seven defects an adversarial review round confirmed

Free and Song now put the shared master dormant whether or not anything is
recorded. Undo-to-empty deliberately keeps the master so redo can restore
through it, so an empty-looking rig still carries a live clock; the mode
switch returned before the reset, and the next Free take was rounded up to
the erased take's length and played on its clock instead of its own. The
grid the master measured goes with it, as it does at a clear; the tempo and
its source survive.

The mode gate measures what the audio thread will find. A restore that is
posted and not yet applied does not publish its length, so the gate read the
track as empty and answered OPEN for a switch the audio thread either drops
or applies to spans nothing checked. Both halves read the effective length
now, the base pick comes from one read rather than two — which is also what
made a concurrent clear divide by zero — and a posted arm counts as queued
on the same terms the audio thread blocks on.

Two undo taps inside one audio block peel; they no longer restart recording.
LE_CMD_RECORD does not bump the state acks, so the second tap still read
OVERDUBBING and posted a second punch, which the audio thread applied as a
punch back in. A control-side latch makes the punch-out idempotent for the
length of that window, and a deliberate press re-opens it.

A looper mode chosen while the interface is closed is persisted. It never
reaches the engine until the next start, so the reported-state guard, which
writes on a change in the report, wrote nothing: the mode worked for the
session and reverted on the next launch. The bloc now also writes what the
repository holds, which is the old mode when a change was refused.

A redo pressed before the settling poll keeps a restored clear-all group
whole. A member whose undo is still parked is intact by construction, and
cancelling its parked tap is its re-clear; treating it as moved history
stood the group down and left one track restored and one re-cleared out of
what the player performed as one undo and one redo.

Every fix above is mutation-checked except the divide by zero, which is
structural: the double read it removes is the whole failure mode, and the
race binary that could exercise it deliberately links no engine code.

Part of #1012.



=====
# PR #1014 feat(engine): own record timing, overdub decay and Once per track (slice 2b)
branch claude/segno-slice2b-timing-1012 <- claude/segno-slice2-edits-1012
55 files changed, 2467 insertions(+), 211 deletions(-)
---
commit 7a8c7c3b 2026-09-09
feat(engine): own record timing, overdub decay and Once per track (slice 2b)

Record timing is one setting (Immediately, Loop start, bar to 1/16) that
the engine's quantize gate and division pair into, by default and per
track: a per-track division override joins the per-track gate and is read
live at every boundary check. Overdub decay is a percent by default and per
track, taken by the engine as feedback with a ramped live change. Once
stops a track at the end of its own lap in every mode, on the shared clock
in Multi, Sync and Band. Count-in and Sound start exclude each other in the
repository and the cubits as they do in the engine; the snapshot publishes
the record start settings and the feedback coefficients. The overrides
persist as settings (migrated from the old gate key) and round-trip through
the session manifest.

---
commit 621c5ac6 2026-09-09
fix(engine): close the first slice-2b review round

The Once check runs after the grid and section arms fire, so a queued
punch-out, a section stop and the held-transport measure land as queued;
a track whose arm fired into an overdub keeps that pass. A track counts the
frames it has been sounding and Once stops it only after a whole lap, so a
take finalized mid-lap plays a full lap. The count-in and Sound start are
projected from the repository's held values, which read right while the
engine is stopped and in the mock flavour.

---
commit b77d258f 2026-09-10
fix(engine): the per-track decay log code collided, and session defaults never loaded

The new perf-log code reused 315, which LE_PLOG_PERF_ARMED already had
further down the enum. Duplicate enumerator values are legal C, so it
compiled silently, and the two codes carry different arms of the union:
a per-track decay set during a capture could hand the offline renderer a
position, a master length and an iteration read out of a float. It is
317 now, documented in the wire-format table, and a test walks every
code so the next one cannot collide.

The session's own record timing and overdub decay were saved and never
restored: only the per-track overrides reached the rig, so a track that
follows the default came back on whatever the app was last set to.

---
commit 42c4d079 2026-09-10
fix(engine): a rotated Sync take and a split quantize snapshot

A Sync force-armed defining take begins at the primary's loop top again.
Sync arms an empty non-primary track whatever the quantize setting says,
because the division-playback formula reads a phase locked to the primary's
top and only holds if the take began there. The per-track division this
slice added made a mid-loop boundary reachable on a rig whose global
division is off, which started the take a quarter into the cycle and played
the sub-loop rotated by that much. The rule is now keyed on the arm's
nature, so it covers a per-track division and a global one alike — the same
rule the Band section transport already states.

The quantize gate and its division are published together. The gate is a
plain control-side int the setter writes at once while the division reaches
the audio thread through the ring, so a snapshot could carry one without the
other: a session saved in that window recorded the gate on with no division,
which is "at the loop start", not the "every quarter" the player chose. The
snapshot now publishes the control thread's mirror of both. The audio thread
still reads the wire field, and the raw-push clamp is asserted there.

Part of #1012.



=====
# PR #1015 feat(console): the Loop settings pages (slice 2c)
branch claude/segno-slice2c-loop-settings-1012 <- claude/segno-slice2b-timing-1012
134 files changed, 6988 insertions(+), 5851 deletions(-)
---
commit 555b9c9d 2026-09-09
feat(console): the Loop settings pages (slice 2c)

The Loop domain moves out of the settings tray into a full-screen route:
a hub with six rows (Loop mode, Recording, Tempo & click, Length &
quantize, Playback & overdub, Audio & tempo) and one page per row, drawn
at the pen's 1920x1080 geometry inside a scale-down canvas. Each page
shows the global default and a per-track scope selector; a track that
departs from the default shows a Use default button, and Multi mode
locks length and Once to the shared default.

The tray rail's Loop item now opens the route, the Settings section list
gains a Loop entry, and the old tray Loop tabs, tempo keypad sheet,
Tempo and Mode settings sections and QuantizeCubit are gone.
RecordTimingCubit replaces QuantizeCubit (a RecordTiming value instead
of a bool plus a division). The repository owns the default loop length
and Once, pushes them per track, and a session restore only writes a
per-track override where the manifest value differs from the default.

Screenshot suites share one font loader, and the loop goldens load the
lucide package font so the rail and stepper icons render as glyphs.

Part of #1012.

---
commit e3aa2625 2026-09-09
fix(console): close the first slice-2c review round

The Click tab's output routing and level, deleted with the tray's Loop
domain, come back on the Audio tray's Device tab and the desktop Audio
section until the Mixer owns them; the sync switch that went with the
same tab has no place in the design, so its key and setter are gone and
the engine default stands. The record timing cubit keeps the last
musical division while the gate is off. The session manifest carries the
per-track length and Once overrides and the rig defaults instead of the
effective values, so a load no longer derives overrides from the device's
own default. The legacy per-track rows (the tray's Lengths tab, the
desktop length and One Shot rows) and the events behind them are retired
in favour of the Loop settings pages. A dropped mode request re-pushes
the presets it had moved; a mode change pushes only override channels
across the Multi boundary; the setters write the engine before the
projection and the default setters return early when unchanged. The mode
cards rebuild on the state the gate reads and share the refusal wording
with the snackbar; the stop dialog is the one confirm. The sliders
commit once at the end of a drag. The hub reads the defaults from the
cubits, the page ids are one enum, the rail is an explicit entry list,
sixty-five orphaned l10n keys and a duplicate are gone, and the
screenshot suites share one font loader.

Part of #1012.

---
commit f6299400 2026-09-09
fix(console): close the second slice-2c review round

An override on a channel with nothing recorded was lost on save, since
the manifest only wrote the per-track fields for a channel with content;
the length and Once overrides are session-level maps keyed by channel
now, on the manifest and on the rig, and restore bounded to the engine's
tracks. The mode cards rebuild on the count-in and the in-flight layer
too, both of which the gate reads. A cancelled slider gesture ends at the
committed value.

Part of #1012.

---
commit 839cb330 2026-09-09
fix(console): commit a slider touch once and clamp manifest presets

The tap and drag recognizers each cancel on the interaction the other
wins, so a plain tap on a Loop slider committed twice, once at a stale
value; the commit rides the raw pointer now, one pointer up for one
commit, and a cancelled touch ends at the committed value. A manifest
length preset above the engine's 64-bar limit was cached and re-saved
while the engine refused it; every path clamps to the limit.

Part of #1012.



=====
# PR #1017 feat(engine): the mix model (slice 3a)
branch claude/segno-slice3-mixer-fx <- claude/segno-slice2c-loop-settings-1012
57 files changed, 4872 insertions(+), 171 deletions(-)
---
commit 6d71b895 2026-09-09
feat(engine): the mix model (slice 3a)

Per-lane pan with a unity-centre balance law (the near side at unity, the
far side on a quarter-sine, exactly silent at the hard side, centre
bit-identical to the engine before it), per-track Solo beside mute in the
audible gate, a capture trim per input that scales only what a lane
records, monitoring for every hardware input, and the meters the Mixer
needs: post-fader stereo peaks per track, per-input raw peaks, per-monitor
peaks and per-output peaks after the master bus.

The repository fixes a lane's image from its input's setup when the take
starts (a pair member hard on its side, a mono input where its pan put it,
the pair's balance as a gain on its side) and gives the engine each lane's
effective pan and volume, so a track's fader and pan move every lane
together without rewriting the take. Stereo pairs are two lanes. The
input setup (trims, pans, pairs) is the repository's remembered intent,
projected on the state, kept in settings per device, saved with the
session and restored on load; track pans likewise. Typed mix targets carry
a canonical identity for the assignments of slice 4.

Part of #1016.

---
commit 012d927f 2026-09-09
fix(engine): close the first slice-3a review round

A lane's level, image and balance are the repository's own values in the
projection and the manifest, so a save and load no longer fold a pair's
balance into the level; a lane added after the defining take gets the
track pan and, on its first take, its own image; boot restores the pans
after the lane counts. Solo gates the offline render and the DAW export
like mute, seeded from the arm manifest. The meters read only what
reaches an output; the pan's gains are computed when the pan is set; the
trim and the solos are read once per block; the meter publish and the
Dart snapshot lists are bounded by the device's channels and the Dart
snapshot drops the trim it never read. Pairing is refused while a fed
track is armed or capturing and past the engine's ceiling; reset mixer
walks every remembered track. A session load re-persists the input setup
and the track pans it applied, and the settings writers are per input.
The input setters share one path, MixTarget follows FxAddress and drops
the track level TrackVolumeTarget already names, the write-only monitor
pan and the dead dB conversion are gone.

Part of #1016.

---
commit 37f328ef 2026-09-09
fix(engine): close the second slice-3a review round

A lane whose fader was never touched had no level of its own, so the
fresh-take path still projected and saved the engine's gain as the level;
the seed and the lane growth give a lane the track's level now. A load's
wholesale setup push posted sixty-four ring commands; it pushes only the
inputs either setup names. The DAW export writes a track's audibility at
the start when it was silent at arm, since the activator's manual value
is on. A reset while stopped clears the caches without a refused engine
call.

Part of #1016.



=====
# PR #1018 feat(engine): output destinations (slice 3b)
branch claude/segno-slice3b-outputs <- claude/segno-slice3-mixer-fx
54 files changed, 4949 insertions(+), 738 deletions(-)
---
commit f628c741 2026-09-09
feat(engine): output destinations (slice 3b)

Output buses over stereo pairs with level, mute, Stereo/Mono and balance
and a post-sum chain each (the Master insert is bus 0's chain; the click
rides the bus), the performance capture tap before the destination's
level by default with a per-take Follow output policy the offline render
mirrors, Cut all sound, bypass draining its tail into the dry signal,
Stop draining Post tails while Mute gates them; the output setup held by
the repository, persisted in settings and the session manifest, restored
at boot and re-persisted on session load.

---
commit 393f16f7 2026-09-09
fix(engine): close the first slice-3b review round

A disabled output channel no longer carries audio and Mono averages only
the enabled channels of its pair. A retype while a bypass drain is in
flight starts clean instead of replaying the previous effect's ring. Only
a ring-owning type with no reported latency drains its tail; everything
else keeps the crossfade, so a kernel with no memory cannot overshoot and
the octaver cannot double the dry path. Cut all sound is perf-logged per
track. The performance capture's destination is published, recorded in the
arm manifest and replayed by the offline render, and a manifest with no
capture policy is treated as the post-gain take it is. The policy itself
survives a device change. Each output edit posts one ring command and
writes one settings key. The Master insert compatibility layer is gone
from the C API, the ring codes and the Dart engine interface.

---
commit 8625ba75 2026-09-09
fix(engine): close the second slice-3b review round

The capture destination is read after the arm, not from a snapshot taken
before lane export and manifest I/O: the engine settles it inside the arm,
so the manifest could name one destination while the take captured another
and send the offline render to the wrong level rides. Two source-level
goldens pin the snapshot copy helper to the field list and to its own
fields, because the constructor's defaults let a later field compile
without it. The stale contracts in the FX header, the command enum and the
click comments now say what the code does.

Several tests passed against their own reverted fix and were rebuilt to
fail: the Cut and retype tests read zeros because they never filled the
delay ring, the render's capture-destination filter had no coverage, and
the pumped engine snapshot had none. Each is mutation-checked. The
test-library build script had stopped compiling before the vendored
denoiser landed, so every FFI-gated Dart test was skipping silently;
repairing it brings back 72 tests.



=====
# PR #1020 feat(console): Audio routing and Output setup (slice 3c)
branch claude/segno-slice3c-routing-surfaces <- claude/segno-slice3b-outputs
73 files changed, 5771 insertions(+), 2420 deletions(-)
---
commit e57de47b 2026-09-09
feat(console): the Audio routing route and Input setup (slice 3c)

The accepted Audio routing surface as its own route under Settings: the
pen's four tasks as pills in one nav row, on the Loop settings frame and
canvas rather than a second copy of them.

Input setup is the first task. It picks a jack from a row that scrolls
past the pen's four cards, records it on its own or as one half of an
ordered stereo pair, places it with Pan or with the pair's shared
Balance, and sets the capture gain in half-decibel steps beside a meter
that keeps a clip lit for as long as the engine holds it. A track armed
or capturing that jack freezes the format and says why. Every control
dispatches the slice-3a and 3b events that had no consumer until now.

---
commit 3dbabd77 2026-09-09
feat(console): Recording inputs picks a track's jacks (slice 3c)

The second Audio routing task. A scope row picks the track, then the
hardware inputs it records. Unchecking frees that lane in place; a new
jack fills a free lane, and only a full track grows before it is routed.
A capturing track says why its jacks are frozen, and only that track is
held.

---
commit 4e61105b 2026-09-09
feat(console): name output destinations, per device (slice 3c)

Both remaining Audio routing tasks send audio to a destination, and a
destination needs a name before it can be offered as one. The unit is
the stereo pair a player patches, not the jack: bus k drives outputs 2k
and 2k+1, so one name covers the cable pair and the per-jack output gate
keeps its own key. An unnamed destination falls back to its jack numbers
in a short form, so a card can carry the full label above the name.

---
commit e02ab316 2026-09-09
feat(console): Output routing sends a source to its destinations (slice 3c)

The third Audio routing task. Live inputs, recorded tracks and the click
each carry their own destinations, so a recording-only track route never
becomes a live input route. A track's choice is the whole track's and
writes every lane. Hear live belongs to the live inputs, says whether
Auto is hearing anything now, and says when the monitor is muted in
Mixer.

The accepted design's backing-track source has no seam in this console
yet, so the kind ships with the click alone.

---
commit ebe61cec 2026-09-09
feat(console): Output setup sets what a destination is heard through (slice 3c)

The fourth Audio routing task: format, level, balance and mute per
destination, with the meters reading that destination's own jacks and a
muted destination metering silence.

Also fixes the routing meter's fill, which lit cells in proportion to
amplitude while the scale under it prints four evenly spaced ticks: a
signal at -24 dBFS lit a sixteenth of the meter under a label that says
a third.

---
commit 6df2ed42 2026-09-09
feat(console): name the ports from Audio routing (slice 3c)

The header action opens the names list for the side of the rig the task
is on, behind the same frame, so Back returns to the task rather than
out to Settings. Outputs are listed per destination, not per jack.
Renaming goes through the console's one rename sheet, with an empty name
allowed: that is how a port is handed back its numbers.

---
commit ae44bb39 2026-09-09
refactor(console): retire the surfaces Audio routing replaces (slice 3c)

The Tracks routing tab and its per-track dialog were the only
dispatchers of the lane routing events, which the new tasks now own;
their quantize group is already covered by slice 2's Length & quantize
page. The interim click output card and the desktop section's output
chips go the same way, leaving the click's level where it is until the
Mixer holds it.

The Signal face's per-jack output gate stays: a structural switch with a
last-live-output guard is a different fact from a destination's mute,
and the accepted design does not replace it.

---
commit 333324fb 2026-09-10
fix(console): the review round's findings across Audio routing (slice 3c)

Audio routing was unreachable on the appliance: the accepted design
reaches it from Settings, and on the console the tray is Settings. A row
on the Audio face opens the route, carrying the click's level, which the
console had lost with the interim card.

The format lock now asks about both members of a pair, as the repository
does. Every projection clamps its chosen source to the open device, so a
narrowed interface cannot leave a control editing a jack or a bus that
has no card. Setting a destination claims only the jacks the device has
while clearing reaches both, so a route saved on a wider rig can be
switched off, and jacks a track records beyond the device keep cards of
their own. A full track's cards are inert and say why.

Input setup was 96 pixels low, the whole tab, and was missing the meter
readout, the clip line beside the trim note, the pen's card ordinals and
the pair side on the card and the trim label.

---
commit f8b2c717 2026-09-10
docs(plan): record what the review round found beneath this slice

---
commit 6f7a3451 2026-09-10
docs(plan): record the twelve engine findings and how each was settled



=====
# PR #1021 feat(console): the Mixer view (slice 3d)
branch claude/segno-slice3d-mixer <- claude/segno-slice3c-routing-surfaces
12 files changed, 1554 insertions(+), 9 deletions(-)
---
commit 2bca71f4 2026-09-10
feat(console): the Mixer view (slice 3d)

The stage's third view: four channel strips per bank, each with Mute,
Solo, the FX bypass, a pan bar and a stereo meter whose level marker
rides on it. Mute, Solo, pan and level dispatch the events slice 3a
built, so a Mixer edit never creates a second mixer state.

Both sides meter from the per-track peaks slice 3a added and nothing
drew until now, subscribed in their own leaf so a level tick redraws two
bars rather than the strip. The stage's dB scale now takes the insets of
whichever view is showing. Reset mixer appears only here; clearing every
Solo is a long press on a Solo button.

The pen's FX edit button is left out: its editor is slice 3f and would
open nothing. The Backing & click sheet is left out for the reason slice
3c left out its backing source.



=====
# PR #1022 feat(engine): FX placement and printing (slice 3e)
branch claude/segno-slice3e-fx-placement <- claude/segno-slice3d-mixer
44 files changed, 6534 insertions(+), 327 deletions(-)
---
commit 66249962 2026-09-10
feat(domain): Pre/Post placement per instance (slice 3e)

Every chain entry now says where it sits relative to the loop player.
Pre is recorded into the loop; Post runs downstream of the player and
can ring after Stop. Placement rides the entry, not the address, so
moving an instance leaves every pedal binding that names it resolving.

A chain is stored Pre entries first, so the split the engine has to know
is one boundary index rather than a per-slot flag. The write boundary
partitions before it clamps: an over-long chain loses its trailing Post
entries instead of whichever entry happened to sit last, because a clamp
that cut across the partition would name a Pre count larger than the
chain describing it.

The partition is stable, so re-partitioning an ordered chain is the
identity and a reorder within one stage survives the next write. A
placement change removes the instance and appends it, which is the
accepted "moves to the end of the destination stage" with its identity,
parameters and enable state intact.

Live inputs, whole recorded tracks and recorded parts have a setter.
Outputs do not: their stage is fixed after the mix, so their write
boundary forces Post rather than trusting the surfaces to remember.

Post is the wire default and is omitted, so a chain without a Pre entry
persists byte for byte as before. The legacy `stage` integer of the
removed pre/post model is a different key and still decodes as ignored.

---
commit bd6a25e0 2026-09-10
feat(engine): print the Pre stage from the dry take (slice 3e)

A lane's chain now carries the split as one boundary index, pushed with
the count it belongs to so the audio thread never sees a Pre run longer
than the chain it splits. Entries below it are Pre, the rest are Post.

The loop-stage cache becomes the printer. It renders exactly the Pre
prefix from the lane's dry pool and swaps the result in at the lane's
loop boundary, which is the accepted "prepared from original sources"
and "switched at an audio-safe boundary". The recording is untouched:
the print is a rendered copy, so the dry original stays the render
source however many times the Pre chain is edited, and nothing ever
applies the old wet version again.

The Post entries stay live over whatever is playing, printed or not.
That is not a choice: a Post tail has to be able to drain past a Stop
and a baked tail cannot, so a whole-chain render was already at odds
with the tail contract slice 3b shipped. The cost is that a cached lane
now pays its Post chain's CPU, where before it paid none and its Post
tail could not drain at all.

The print's key is the Pre prefix, so editing a Post entry leaves it
standing rather than dropping the lane to live processing for a change
that cannot make the render stale.

Stop takes the Pre tails with it. There is no single place a track
stops here, so the edge out of sounding is watched per track and clears
each lane's Pre slots, leaving its Post slots to drain. That is
"Printed Pre stops with its recording", and it holds on the live
fallback as well as under a print.

---
commit 7a29dda1 2026-09-10
feat(console): a live input's Pre run is what its takes record (slice 3e)

Record already copies a routed input's chain onto the lane by value, so
carrying each entry's placement through that copy is all it takes for an
input's Pre entries to become what the take prints and its Post entries
to become what runs after that take's player. New instances on a live
input are created Pre, which is the accepted default and the one that
matches what the chain is for.

Placement moves by slot id, never by index: the move is the one
operation that changes an index. The lane event and the input setter
reach the repository's movers; the control that calls them is slice 3f.

Reorder now stays within a stage on every chain. The chain is stored
Pre-first, so honouring a drag across the boundary would re-partition
the result straight back and land the entry somewhere nobody asked for.

Two defects fixed in passing. Retyping a lane or input entry rebuilt it
from its type alone, dropping the slot id, the power decision and now
the placement: a retype would silently re-mint the entry and dangle
every binding on it, and power a bypassed device back on. The bus stage
already kept both and is the rule the other two were missing.

A whole track's chain is stored wholly Post, like an output chain. A Pre
entry is printed from a dry original and this stage has none: it
processes the sum of the track's parts, computed live from lanes that
each own their own recording. The accepted design does give a whole
track a Pre/Post switch; what that needs is recorded on the issue rather
than stored as a placement the engine cannot honour.

---
commit 919e337d 2026-09-10
feat(engine): the All tracks recorded-mix chain (slice 3e)

The accepted design's third FX destination: the single shared chain
applied after the loop tracks are combined. It runs after every track's
own chain and before live monitoring, the click and the output chains
join, which is the whole difference between it and an output chain. An
output chain processes every source routed there; this one processes the
recorded tracks alone.

One chain, one DSP instance per destination. Since slice 3b every source
picks its own outputs, so "the combined recorded mix" is a
per-destination quantity: a track on Main and a track on Monitor are two
different mixes, and one shared instance would have to send each track's
audio to the other's jacks. The chain the player edits is one; the
filter memory cannot be.

Topology keys off emptiness, exactly like the track bus, so an empty
chain leaves the tracks routing straight to their outputs
bit-identically and the stage costs nothing until something is put on
it. Its entries are always Post: the stage processes a sum computed live
from lanes that each own their recording, so it has no dry original to
print a Pre entry from.

It persists like every other chain: its own settings key, and a manifest
field at schema v8, presence-keyed so a v7 bundle loads with no such
chain and a session that describes none resets whatever was live.

Cut all sound clears its tails on every destination, beside the output
chain on the same jacks.

---
commit eda3f9b3 2026-09-10
feat(engine): channel handling and level per FX instance (slice 3e)

The accepted design puts an input choice, an output choice and a level
around each instance in a chain: the input choice before its effects, the
output choice and then the level after them. Stereo keeps what the
effects made and the placement is a Balance; Mono averages them and the
placement is a Pan, on the one unity-centre law the lanes, monitors and
output buses already use. Centre and unity are exactly that, so an entry
left alone is bit-identical to one with no channel handling at all.

The choices ride the entry's FEED, not the dry signal it is crossfaded
against, so a bypassed entry passes the pair through exactly as it
arrived: the choices belong to the entry and leave with it.

Four values, one call. They are one control surface and a half-applied
change is audible, so the setter takes them together. Direct atomic
publishes like the params: they change gain within an entry, never its
DSP state, so nothing resets and there is no ring command to order
against. Every chain owner has one — the five destinations the accepted
design shows a rack footer on.

The audio thread reads them from a per-chain cache refreshed once per
buffer, the same two-tier arrangement the enable bits use, so the hot
path costs a flag on an untouched chain and needs no per-lane array. A
zeroed chain state reads as "nothing to do", so a fresh one is safe
without anything having to remember to seed a unity level.

They key the print. The render applies them, so a change to an input
choice, a placement or a level makes a published render stale exactly as
a parameter change does; the fold lives in the print key alone, leaving
the chain hash the repository mirrors unchanged.

The engine's pan law moves to the shared header: the control thread now
precomputes an entry's gains with the same function the audio thread's
handlers store a lane's pan with.

---
commit 7eca3ac2 2026-09-10
docs(plan): record what slice 3e settled and what it left

---
commit 6ae28ad7 2026-09-10
fix(engine): a stopped track's own Post tail was routed nowhere

The idle-track lane skip (#897) leaves a STOPPED track out of the lane
loop when none of its parts carries a chain. The Track-stage chain runs
outside that loop and kept ticking, but bus_mask is built INSIDE it, so
the tail reached no output: the accepted "Stop drains Post tails" held
for a track whose parts had chains and silently did not for one whose
parts were plain, which is every track with all its effects on the track
itself.

A track carrying a Track-stage chain is no longer idle. The skip still
covers what it was written for, an EMPTY or STOPPED track that has
nothing to run at all.

Also lands the wire a whole-track Pre run needs: a bus chain carries a
Pre count like a lane's, pushed with the count it belongs to and clamped
against it by every reader. Only the track instance will use it — an
output chain and the All tracks chain process a sum computed live and
have no dry original to render from.

---
commit bcb258e9 2026-09-10
docs(design): fix the whole-track Pre render boundary

---
commit 5a53222d 2026-09-10
feat(engine): the whole-track Pre render (slice 3e)

A track's Pre run is now a non-destructive rendered copy of its combined
material: every part's own printed material at its level, mute and pan,
summed, through the track's Pre run, into one stereo buffer swapped in at
the track's loop top. The combination is processed as ONE signal, which
is the whole point — a compressor or a distortion on a sum is not the
same as the same effect on each part.

The parts' prints are the render's INPUT, not something it re-renders,
so the job costs one stereo buffer rather than a copy of every part, and
a part that has already settled is simply read. A part with no chain
contributes its dry recording at level, which is its own printed
material.

It renders only while every part's chain is wholly Pre. A part carrying
a Post entry keeps the track's Pre run live, with the reason reported,
because the render would otherwise have to bake that entry — it is
upstream of the track's chain — and a baked tail cannot drain past a
Stop, which is the promise that part's own switch makes. Nothing is
disabled and nothing sounds different: the live path computes the same
function the render materializes.

Engaging removes the parts from the bus entirely rather than merely
bypassing their slots, because a bypassed entry is unity passthrough and
not silence, and masks their effective bits for the rest of the buffer
so the engage edge cannot land mid-buffer and ramp them back in.

The key is refolded every buffer rather than memoised. It spans every
part's chain, level, pan and mute as well as the track's own Pre run, so
a memo would want a bump on fifteen setters and one missed bump would
play a render that no longer describes the track. The refold is gated on
a published render, so a track without one costs a single load.

The Stop edge takes the track's Pre tails with the recording and leaves
its Post run to drain, printed or live alike.

The cache now carries two entry classes. The graveyard sizing, the LRU
scan, the budget, shutdown and the job accounting all became class-
generic rather than lane-indexed; the accounting in particular is now
derived from a job's shape instead of assuming one mono source.

---
commit f114efb4 2026-09-10
docs(plan): record the whole-track render and what it cost

---
commit be987759 2026-09-10
fix(test): the performance repository suite stopped compiling at slice 3e

Its fake engine never grew the methods slice 3e added to the engine
interface — the five All tracks setters, the four channel-handling
setters and the two preCount arguments — so every test in the package
failed to compile and the whole suite went silently absent.

Part of #1016



=====
# PR #1024 feat(app): the accepted FX surfaces, and the Signal tray retires
branch claude/segno-slice3f-fx-surfaces <- claude/segno-slice3e-fx-placement
416 files changed, 14024 insertions(+), 13693 deletions(-)
---
commit 30b38ea6 2026-09-11
feat(app): one FX chain per destination, and All tracks gets an address

The FX surfaces the accepted design draws address five destinations: a
live input, a recorded part, a whole recorded track, All tracks, and one
output. The stage enum named four, and two of those five had no address
at all.

FxStage is input / loop / track / allTracks / output. The master stage
is gone: it named one insert on the first output pair, which slice 3b
had already made one chain per output destination, and FxStage.output
carries the destination in the address field it already had. A binding
still spelling master decodes to null and goes inert rather than
retargeting itself at a destination its author never chose.

The repository holds one chain per destination, keyed by bus, with the
Track stage's own conventions: an entry dropped when the chain lands
back at the default, applySession writing every destination the old rig
configured as well as the ones the arriving rig names, and the restart
replay walking the map. Persistence follows: output_fx_chain.<bus> in
settings with a clear for a dropped destination, outputChains in the
session manifest (schema v9), and PerformanceOutputChain per destination
in the arm snapshot.

A binding can point at the All tracks chain and at every destination the
open device has, not only the ones already carrying effects: a
destination exists because the interface has the jacks.

Part of #1016

---
commit ff705eb0 2026-09-11
feat(console): the Effects destinations surface

The pen's 01 Effects · destinations: one page for every destination
rather than one page per stage. The Sound type row picks the strip, the
strip picks the source, and the chain underneath is whatever that source
carries — which is what makes a live input, a recorded part, a whole
track, All tracks and an output arrive at the same editor.

The chain is the pen's horizontal strip: a card per effect, a plain line
between consecutive cards, and a wider break with no line where the Pre
run hands over to the Post run. No arrowheads, twice rejected.

Each stage keeps its own owner for writes: the monitor cubit for a live
input, the looper bloc's per-stage events for the rest. Each strip keeps
its place across a context switch, and so does each kind's chain scroll.

The All tracks chain gained a projection on the way: slice 3e built it in
the engine and the repository and left it unreadable from the app.

Part of #1016

---
commit 13b82ef4 2026-09-11
perf(engine): raise the chain ceiling to 64, off the audio thread's stack

The accepted FX design builds a chain out of racks and one factory rack
is about six pedals, so an eight-slot chain held roughly one rack where
the design shows ten.

The cap was never a CPU limit — the audio path iterates the active count
and an unused slot allocates no DSP state — but the per-buffer snapshot
arrays were locals of the audio callback, sized by LE_FX_MAX. At 64 they
would have put 195 KB in one stack frame, of the one budget in this
engine that is neither ours to set nor reported by the host.

They are now le_fx_snapshot inside le_engine. Nothing about them is
state: each is written and read inside a single callback, so they need
no atomics; they live in the struct so their size is charged to an
allocation whose size is known. The callback's frame went from 32,048 to
7,200 bytes and stays there — 7,184 at the old ceiling — while the engine
struct grew from 1.27 MB to 4.92 MB.

The per-buffer settle sweep now skips a slot whose enable ramp is
already parked at bypass, which is where almost every slot past a
chain's count sits. Forcing bypass on such a slot writes nothing, so
skipping it is the same sweep with the atomic load removed.

Part of #1016

---
commit 1788822e 2026-09-11
feat(fx): commit the factory effects catalogue

Nine rack families, 159 presets and 66 artwork images, as their own
package with a loader and nothing else. Shipping the extracted assets is
the owner's decision, taken on #1016.

Data only. Nothing here knows about a chain, an engine or a screen: what
a preset means to this engine is the repository's business, and the
accepted design is explicit that unverified source scales and values are
evidence rather than permission to claim factory defaults. So the family
is the folder and not the source's type field (two families share a type
value and one family carries two), names are kept exactly as written,
every numeric parameter survives the parse, module names are documented
as a reading of the parameter prefixes rather than a recovered chain, and
the artwork slugs are mapped rather than derived — the folder and image
names follow no single rule, and a slugging function would silently draw
the wrong rack.

Loading is driven by the import's own manifest, checked against
Flutter's asset manifest before any read: a bundle has no directory
listing at runtime, and loadString raises an Error for a missing key. A
build without the assets loads an empty catalogue.

Eleven tests against the real files rather than a fixture, at 100% line
coverage with its own CI job.

Part of #1016

---
commit 86641648 2026-09-11
feat(fx): read a preset's modules, and say what this engine can build

Two tables, both written by hand and both pinned against the data.

A preset is a flat map of parameter names to values that never says
which modules it holds, and the three vocabularies in the source
disagree about how to name the same pedal: the power key (Compressor),
the parameter prefix (Comp Ratio) and the artwork (Compressor2). Delay
enables Del, Reverb enables Rev, OvDrive enables OD. So the module table
is written down rather than derived, and its doc says it is a reading.

What the tests pin is that the reading matches what is there: every
power key appears and is binary wherever it appears, which is what
separates it from a continuous key like Cab that also has no space;
every group the table names appears; every group in the catalogue is
claimed by exactly one module or listed as deliberately unclaimed; and
every illustration is a file that is here. A module with several
illustrations records them all, because nothing says which numbered
variant a family used.

The readiness map says what building each module amounts to here: full
when nothing the preset carries is dropped, partial when the engine
builds the kind but some controls have nowhere to go, and unavailable
for most of them. Stranded controls are kept and named rather than
discarded, an unread parameter keeps the engine's default rather than
falling to zero, and an unavailable module still takes its place in the
chain and passes signal through.

The reverb's brightness is deliberately not wired into the engine's
damping, though it is that control's complement: inverting someone
else's control into ours is the silent substitution the accepted design
forbids.

Part of #1016

---
commit ff2de10b 2026-09-11
feat(console): Add effects, from the library to the chain

The pen's 03 Sound library & presets: the rack families and Single FX in
one artwork grid, then the chosen family's presets as plain rows.

The library returns a choice and changes nothing itself. What the choice
does to a chain belongs to the destination that opened it, which is what
makes one Back from a completed addition land on the destination: Add,
the family and the preset are page state inside one route, so they are
never in the completed addition's history.

A rack becomes one chain entry per module it names, built through the
readiness map, and every entry arrives bypassed whatever the preset's own
power keys say — adding a rack mid-set must not change the sound until
the player says so. One write rather than one per pedal, so a half-built
rack is never heard on the way in. A rack that will not fit is offered
and says how many slots it needs against how many are free, rather than
half-landing.

The catalogue loads lazily on the first open of the Effects route: 6 MB
of assets only these surfaces want, and a rig that never opens them
should not pay for it on the way to the stage.

Part of #1016

---
commit 5b09279f 2026-09-11
feat(console): the effect editor, with the Pre/Post switch in its footer

The pen's 02 Single effect: an effect opened in place with its controls
direct, which is what the removed generic parameter dialog was in the way
of. One control per parameter the effect actually has, each saying Scale
unverified under it — the accepted design shows raw source values without
inventing physical units for them.

The Pre/Post switch is a direct segmented control with the one
consequence line that changes with it, and it is offered only where the
placement is the player's to choose. All tracks and the outputs omit the
control and its line, because their stage is fixed after their respective
mixes and a control that could not move would be a promise the rig cannot
keep.

Channel handling is one write: the input choice applies before the
effects, the output choice and its placement after them, and the level
last, so a half-applied change is audible. The same control is named for
the job it is doing — Balance on a stereo output, Pan on a mono one.

Each stage keeps its own owner for writes. The editor is pushed above the
page's providers, so the two it watches are carried in by value rather
than snapshotted: an edit made here and an edit made from a pedal land in
the same place.

LoopOutlinedButton drew a button with no callback exactly like a live
one. Effect options and Save preset arrive with the rack-options surface,
and until then they were the working-but-silent control the accepted
design says to explain rather than present.

Part of #1016

---
commit 87684b29 2026-09-11
feat(fx): the rack becomes a thing, with its options and reorder

The accepted chain is a run of racks: named groups of pedals the player
adds, renames, reorders and removes as one thing. This engine's chain is
a flat run of entries, so the grouping rides the entries. A chain entry
gains the rack it belongs to (an id shared by every module of that rack,
a name and an artwork slug) and the catalogue's own name for the pedal,
which is what still says which pedal an unprocessable module is.

fxChainGroups turns a chain into what the surfaces draw, and the
transforms beside it are the only things that rearrange one. Two rules
live there: channel handling is read around a group, landing the input
choice on its first module and its output side on its last, and a rack
never straddles the loop player, so the Pre/Post switch moves every
module together to the end of the other stage.

A card on the destination chain is now a group. Opening a rack opens the
rack chain editor: one column per pedal with its own power, artwork,
controls and a persistent scrollbar, plain cables between them, and the
rack's channel handling in the footer. Rack options holds rename,
reorder, remove one pedal and remove the rack. One reorder surface
arranges both a destination's racks and a rack's own pedals; its draft is
local, its stage is a boundary it will not cross, and Cancel discards it.

Two things part 2 and part 7 shipped are corrected: the card's artwork
frame was 189 tall where the pen fixes it at 138, and both editors'
titlebar rows were left-aligned where the pen right-aligns them.

A rack has no bypass bit of its own. Its power writes every pedal's, so a
rack turned off and on comes back with every pedal on.

Part of #1016

---
commit 5000a23b 2026-09-11
feat(fx): save a sound, and recall it from My presets

A saved preset is a COPY, not a reference, and everything the accepted
design says about saving follows from that: replacing a definition leaves
existing instances unchanged, recalling one creates an independent
instance, and saving does not rename the active rack.

A save copies the effect parameters, the channel settings and the
catalogue's name for each pedal. It drops the rack, the slot ids and the
placement, because those three are what make one instance distinct from
the next, and placement belongs to where a sound is used rather than to
the sound.

FxPresetsCubit owns the list, because three surfaces touch it: the two
editors save into it, the library recalls from it, and My presets renames
and deletes in it. The name check is case-insensitive, since two rows
differing only in case are two rows nobody can tell apart.

Save preset names the sound and then either saves it or asks. A name
already taken offers Replace preset or Use another name; cancelling the
question keeps the previous preset untouched. My presets lives inside Add
effects, listing each saved sound as a card over the row that renames or
deletes it.

Import presets, Export all and each card's Export are drawn where the pen
draws them and do nothing: moving a preset on or off this console is the
USB export domain's job, and that domain is not built.

Part of #1016

---
commit 4219c3fb 2026-09-11
refactor(console): the Signal tray domain retires

Parts 1 through 10 of this slice built the accepted Effects surfaces.
This removes what they replaced.

Signal was the tray's first domain and its landing, because the signal
path is what the rest of the console configures. The accepted Effects
page is that same signal path, so it takes the same first position and
the same glyph, as a route rather than a face — the treatment Loop
settings already has, because the page takes the whole screen and its
editors are direct controls rather than a list that opens a dialog. The
tray lands on Control now, and G opens the Effects route.

Going with the domain: its nine view files, the two fx_editor helpers
only they used, and the lane-cache indicators. The Signal detail panel
was the only surface that rendered cache state, so its telemetry scope
and the preference gating it were a switch for nothing — the toggle's own
subtitle named the surface it drew on.

The hosted-plugin browser goes too. Retiring Signal removed the only way
to add a VST3 or CLAP plugin to a chain, the accepted Add effects offers
the factory catalogue and Single FX, and the pen draws no plugin entry;
the owner's call was to drop the browser rather than invent a surface for
it. Plugin hosting stays in the engine, the repository and the chain
model, so a chain that still carries a plugin entry works as before.

Written back into segno-ui.pen as c/signal-domain-retired, since a
shipped departure from the pen is a design change rather than a PR note.

Part of #1016

---
commit 95dcea0d 2026-09-11
fix(console): Remove rack asked with a sentence about saved presets

The confirmation reused the preset-deletion copy, so removing a rack from
a chain was asked with 'Effects already added from it are not affected'
under a 'Delete' title. Its own words now, saying the accepted rule:
removing a rack leaves the sounds saved from it in My presets. It also
confirms afterwards, which it had not, since the editor pops on removal
and nothing else said the rack had gone.

Part of #1016



=====
# PR #1027 feat(control): Press and Hold, and the selected-track scope
branch claude/segno-slice4-assignments <- claude/segno-slice3f-fx-surfaces
8 files changed, 1098 insertions(+), 109 deletions(-)
---
commit ab09dfb4 2026-09-11
feat(control): Press and Hold are separate actions

The accepted rule: holding a navigation or control pair must not first
execute its short action, nor act again on release in the newly opened
mode, and pending gestures are cancelled on invalidating navigation,
disconnect or configuration.

Holds were four hard-wired switches — undo, MODE, BANK and Stop-in-FX —
each with a field of its own, and a bound switch had no hold at all. A
binding now carries a hold beside its press, and a switch carrying both
moves its press to the release: until the threshold passes neither half
is known to be the one the foot meant. Firing the hold retires the tap,
so the release after it stays silent.

The four track footswitches are the only ones that may carry a hold, and
every exclusion is the design's own. Record/Play and Stop keep immediate
contact. Undo, Stop, MODE and Bank already carry a system hold, which a
remap never overrides. Clear is the one irreversible stomp. A momentary
press cannot carry one either, because holding is already that gesture.

Cancelling a gesture needed a generation rather than a cancelled timer: a
release already on its way up the wire cannot be recalled, so a press
belongs to the generation it started in and a release landing in a later
one runs nothing. One call point is now reached from every invalidating
path the rule names.

Two defects that exposed: unbinding the pedal left the hold timers armed
to fire into a rig with no pedal on it, and the take lock reached the
press but not the release, so a press taken just before a take still ran
its latched tap when the foot came up.

Part of #1026

---
commit b89342e2 2026-09-11
feat(control): a binding acts on the selected track, or the one it names

The accepted rule gives a binding an explicit scope, resolved once: the
track it names, or whatever is selected when it fires. The same chain
target means a different chain under each, so the scope rides beside the
target rather than being folded into the address, and a press and a hold
each carry their own.

There is no following machinery. The scope is read at the instant the
action fires rather than when the switch goes down, which is both halves
of the accepted rule at once: a pending hold acts on the newly selected
track because it reads the cursor when it fires, and stays attached to
what it resolved because the momentary restore captures the resolved
target.

Identity for a track here is its engine channel. Tracks are never
reordered, so a channel is not a visible slot that could drift under a
binding; no second identity was invented for something that had one.

Only the two stages whose index is a track are repointed. An input, an
output and All tracks have no relationship to the selection, so a scope
on one of those is honoured as written. A lane survives the repoint,
because dropping it would widen the binding to the whole track. An
unrecognised scope decodes to fixed, never to selected.

Part of #1026



=====
# PR #1028 feat(control): Pedals setup, and one action catalogue for every picker
branch claude/segno-slice4c-pedals-setup <- claude/segno-slice4-assignments
31 files changed, 3913 insertions(+), 512 deletions(-)
---
commit 8123a162 2026-09-11
feat(control): Pedals setup, and one action catalogue for every picker

The accepted Layout A: the hardware map stays on screen while the chosen
switch's Press and Hold are edited together. Track controls edits the fixed
plate — MODE's pair, a Record / Play hold, and one hold shared by the four
track switches, which are selected and marked as one group. Stop, Undo, Clear
and Bank are drawn dimmed with what they do, rather than offering an
assignment the model would refuse. Custom controls is the free map: eight
switches, each with its own pair, and a pair per bank on the four track caps
while a transport switch keeps one whatever the bank.

Everything lands in a local draft. Nothing reaches the rig until Save, which
is what lets Cancel mean something and lets Clear custom assignments offer
Restore; an unfinished draft cannot ride out on some other surface's save,
because it never leaves the page.

The shared catalogue is the other half. One vocabulary — modes, transport
commands, the track pedals and the per-track operations by scope — named once
and listed by the same words wherever a control is assigned, so the external
and MIDI pickers do not each invent their own. Keys are identity, never
labels: renaming a row cannot re-point an assignment, and a key this build
cannot honour reads as unassigned instead of binding to whatever now sorts
nearby. Actions with no behaviour behind them are absent, and the part that
builds each operation adds its entries with it.

ModeSwitchStyle retires into it. The two-way setting was a partial answer to
the question the accepted design answers in full, and keeping both would mean
two places deciding what MODE does. A press enters the mode it names, a hold
enters the mode it names, and either leaves that mode when the rig is already
in it — so nothing a foot can stomp strands it. With no hold assigned the
press acts on contact; with one, it moves to the release, because until the
threshold passes neither half is known to be the one the foot meant. BANK
goes back to paging and nothing else.

Record / Play and the track switches keep their immediate contact: their
holds are layered on top rather than deferring the press, which is what the
accepted design pins them to.

One gap this opens, closed by the Custom controls mode: the foot has no path
to arming a performance recording until then. It was the MODE hold, which now
belongs to the mode pair; the catalogue carries the action, and the mode that
dispatches it is the next part. The toolbar and the keyboard are unaffected.

---
commit b6ab43b9 2026-09-11
test(control): a track hold stays out of FX mode, where the remap owns those switches

---
commit f93a4b6d 2026-09-11
perf(control): the setup compares as fields, not as an encoding

`props` returned `encode()`, so answering "did the setup change" meant
building a JSON string. The comparison runs whenever a fresh setup reaches
the control state, and the answer never needed the bytes — an ordered
flattening of the map says the same thing, and says it without the encoder.

The Track controls map also stops following the bank. Nothing in that context
is per-bank — one hold covers all four track switches — so a map reading
TRACK 5-8 named a bank the context had no way to leave, since BANK is dimmed
there.



=====
# PR #1029 feat(pedal): protocol v4 unreserves the mode field's fourth value
branch claude/pedal-protocol-v4-763 <- claude/segno-slice4c-pedals-setup
16 files changed, 307 insertions(+), 86 deletions(-)
---
commit 3fd9bf05 2026-09-11
feat(pedal): protocol v4 unreserves the mode field's fourth value

A fourth interaction mode cannot ride v3. The mode field has had two bits
since v3 and the fourth value has been reserved-and-rejected by both decoders
ever since, so a custom-mode frame sent at v3 would not render wrong, it would
be refused whole and blank the pedal. That rejection is the entire reason this
version exists.

So v4 is the smallest version that ever shipped here: version byte 0x04, the
same 17-byte payload for a third time, and value 3 meaning custom from v4 on
and nothing below it. Encoding custom below v4 writes it as mute, the
inert-safe degrade FX already takes below v3, so an un-reflashed pedal shows
the wrong mode LED rather than no LEDs at all. Button behaviour is app-side
and unaffected either way.

Amber for the mode LED, in all three places that colour it: both sketches,
held identical by the drift gate, and the on-screen plate, which a widget test
now pins for every mode rather than only FX.

Two golden fixtures carry the contract across the language boundary:
custom_mode_v4 and the same frame on the v3 wire, which isolates the mode
degrade from the LED degrade the FX twins already pin. The C contract test
reaches the decoder's version gate by relabelling a v4 frame, since the
encoder will not write those bits below v4 on its own.

No app-side mode yet: nothing constructs a custom frame until the mode lands.
Nothing in the console selects v4 either — `selectFirmwareVersion` has no UI
caller today, so a real pedal stays at the unknown-firmware v2 floor and the
simulator, which speaks max, is what renders custom on screen.

Part of #763. Direction approved 2026-08-26 (D2: zero-growth wire).



=====
# PR #1030 feat(control): Custom controls, the fourth mode
branch claude/custom-controls-mode-763 <- claude/pedal-protocol-v4-763
21 files changed, 613 insertions(+), 57 deletions(-)
---
commit 27efe48a 2026-09-11
feat(control): Custom controls, the fourth mode

The mode the Pedals setup's Custom map runs in. Every switch but MODE and
BANK does whatever the setup put on it, and an unassigned one does nothing at
all — this is the one mode with no contextual defaults to fall back on, which
is what "fully user-defined" costs and is why an unassigned switch is inert
rather than guessing.

MODE and BANK keep their jobs here as everywhere. The binding model refuses to
hold an assignment on either, so in the mode where every other switch has been
handed over, the way out and the way to the other four tracks are still there.

Press and hold follow the rule the rest of the plate follows: a switch with
only a press acts on contact, and one carrying both moves its press to the
release, because until the threshold passes neither half is known to be the
one the foot meant.

`_runAction` is the single dispatch point for the shared catalogue. The
built-in switches reach it here, and the external and MIDI surfaces will reach
the same method rather than growing interpreters of their own. Scope resolves
once, at dispatch: a selected-track action fires on whatever the cursor holds
when the foot commits, and a fixed-track one never follows the bank.

The track LEDs report the SWITCH rather than the track: lit when that switch
carries an assignment, dark when it does not. Most of the catalogue has no
on/off state a lamp could report, and what a performer needs before stomping
is whether the switch does anything at all. That is its own invariant, and it
is why the empty-track-dark rule now exempts this mode as it already exempted
FX.

With the mode in place the accepted MODE default lands: Mute on the press,
Custom on the hold. The foot gets its path back to arming a performance
recording too — `command:record-performance` is in the catalogue, and this is
the mode that dispatches it.

The on-screen tiles select and stop. What a control does in Custom controls is
assigned per footswitch, and a tile is not one; running some other switch's
assignment from a tap would be a guess.

Part of #763 (slices 3 and 4) and of #1026 part 4d.



=====
# PR #1031 feat(pedal): v4 carries a colour per footswitch, and the decoder stops trusting the wire about length
branch claude/pedal-v4-colours-763 <- claude/custom-controls-mode-763
16 files changed, 550 insertions(+), 46 deletions(-)
---
commit 424e12d0 2026-09-11
feat(pedal): v4 carries a colour per footswitch, and the decoder stops
trusting the wire about length

The zero-growth call rejected exactly these bytes, as bytes for feedback no
hardware could show. That was true of the six single LEDs the v2 faceplate had
when it was made, and stopped being true under #930: the pills are ten 8-LED
colour segments now, one per footswitch, which is the hardware the accepted
design assumes when it asks for colour on all ten. The reasoning survived; the
premise did not.

Widening v4 rather than spending a v5 because nothing has been flashed with
v4 — it is unmerged, and no Pico 2 firmware exists — so the version is still
being written. Completing it now is what keeps "v4 lands once" true when the
console's controller arrives.

Raw RGB, not a palette index. The colours a user picks reach the LED
unquantised, the frame is pushed a handful of times a second so 30 bytes that
rarely change cost nothing on this link, and the pedal is left holding no
second thing that could go stale across a reboot the app did not see. Below
v4 the colours fall off the wire entirely and decode as the default palette,
because reporting a colour nothing sent would be an invention.

Nothing renders them yet. What lights an indicator is still the frame's own
state; this adds the hue dimension, and how a configured colour combines with
a fixed-action pedal's own signal is a behaviour call that belongs with the
palette editor.

## The decoder was reading past its buffer

`pedal_unpack7` writes one byte per payload byte it finds, into a fixed-size
stack buffer, and the length came off the wire unchecked. A long SysEx walked
straight off the end. That predates this change — the buffer was 17 bytes
before — and it is reachable from anything that can send MIDI to the app or
the pedal.

Both copies now bound the body before unpacking it, and the contract test
builds with AddressSanitizer so this is a failure rather than a silent write:
remove the guard and the suite reports a stack-buffer-overflow in
`pedal_unpack7`, which is how it was verified.

Part of #763.



=====
# PR #1032 feat(pedal): the ten indicators take the performer's colours, and state stops being the hue
branch claude/pedal-led-colours-1026 <- claude/pedal-v4-colours-763
41 files changed, 2396 insertions(+), 278 deletions(-)
---
commit 29e5f89e 2026-09-12
feat(pedal): the ten indicators take the performer's colours, and state stops being the hue

The accepted LED contract splits one indicator into two questions. Function
state decides whether it is lit; the performer's palette decides what colour it
comes up in. Both sides of the wire answered the second question for themselves
until now: a track LED read green for playing and red for recording, and the
MODE LED said which mode it was in by its hue.

Protocol v4 already carries a colour per footswitch. This is what picks them
and what renders them.

The palette is eight built-in hues plus any number the performer mixes, each
with a name and a number that outlives an edit. A custom colour is a REFERENCE,
so several footswitches can point at one and editing it moves all of them —
which is what makes it reusable, and impossible if each switch held its own
copy. It rides in PedalSetup, so it is the same draft, the same Save and the
same Cancel as the assignments, and Clear custom assignments keeps it because
the confirmation says it will.

The colour editor is Hue, Saturation and Brightness over a live swatch and its
hex. A new colour opens mid-space rather than on the switch's current one:
white has neither hue nor saturation, so two of the three sliders would move
with nothing happening on screen.

MODE is now dark in the normal Tracks mode and lit in every other one. Stop and
Undo are never lit — both do a thing and finish, so an indicator on them could
only report that the function exists.

One consequence worth stating plainly: a lit track indicator no longer says
whether the track is playing or recording, because both are now that switch's
own colour. The default palette is white on all ten, so a performer who never
opens the editor loses the green/red reading and gains nothing. The accepted
design is explicit that colour is configurable on all ten and that LEDs
represent function state, and the pen's two scenes show exactly this, so that
is what shipped; a state override on top of it would be a design change, not an
implementation detail.

Also fixes Restore after Clear custom assignments, which put the whole draft
back and so rewrote a colour picked after the clear. The recovery point is the
assignments now, which is what the closure pass asks for.

PedalColor.defaultColor becomes the palette's white rather than full white, so
the default is one number instead of one on each side of the wire.

Part of #1026
Part of #763

---
commit 1e1dbc60 2026-09-12
fix(pedal): the setup map reads the frame the app pushed, not one it re-projects

Review of the slice. The map lit its pills by re-projecting a frame from the
LooperBloc's engine state paired with the control overlay — two sources that
converge but do not update in step. `projectFrame` asserts the control-surface
invariant spec, and one of those invariants constrains the PAIR: a stored mute
exclusion or parked-resume member must name a track that still holds a loop. A
clear landing while the setup screen is open publishes the new engine state
before the overlay has dropped the stale channel, and the projection throws
inside build.

The frame the app pushes is the one consistent answer, so the repository
publishes it and the map reads that. A rig with no pedal bound still has a
mode, a bank and lit tracks, so the frame is published whether or not anything
is listening on the wire.

Also from the review: a lit pill drew a dark rim around a colour the hardware
lights edge to edge; the colour editor's doc claimed a performer could type a
hex back in, which nothing offers; and the drift gate's comment lost its verb.

Adds the round trip the editor rests on: it holds HSV and commits RGB, so
opening Edit on a colour and saving without touching a slider has to give back
the colour it opened on. Every built-in and every corner of the cube survives.

Part of #1026



=====
# PR #1034 feat(console): the Pedals setup map draws the footswitch instead of a rectangle
branch claude/pedal-face-art-1033 <- claude/pedal-led-colours-1026
16 files changed, 1680 insertions(+), 58 deletions(-)
---
commit e05c109e 2026-09-12
feat(console): the Pedals setup map draws the footswitch instead of a rectangle

The map drew each switch as a rounded rectangle with a pad block and a
nameplate block. The accepted design draws the real thing, and so does this
now: a tapered metal body under a four-stop gradient, two side hinges, left and
right rolled edges, a textured rubber pad carrying thirty grips on the pitch it
was moulded to, and a trapezoid nameplate. Selecting a switch brightens its
alloy and lights its edge, which is how the study says so.

It is a PORT, not a drawing. Every outline is a path constant from
`docs/design/pedal-hardware-widget.js`, the vector reconstruction of the
populated Fusion assembly and the same source the pen's component was built
from. A test holds the two together: each of the study's seven outlines must be
quoted in the port, so an eighth added there fails until it is carried across.

That study was never committed. It sat untracked in the working copy along with
most of `docs/design`, which is why a worktree could not see it and why part 4c
substituted shapes for it. The four files this port reads are committed with
it; the rest of that directory is 226 MB and is the owner's call.

The nameplate keeps app text rather than the manufacturing ink in
`labels.json`. Those outlines exist for TRACK1 to TRACK4 only, because that is
what the silkscreen carries, and the map names the channel the active bank
drives — TRACK 5 on bank B. The affordance is worth more than the exact ink.

No new dependency. The outlines are short enough to transcribe into `Path`
calls and the grips are circles, so an SVG runtime would have been a large
thing to add for one illustration.

Closes #1033

---
commit ef50473b 2026-09-12
fix(console): the face strokes its body before the rolled edges, and builds its outlines once

Review of the port.

The body was stroked AFTER the rolled edges went on, so the metal's outline
was drawn back over them. The study strokes it first and lets the edges lie on
top where they meet it. Visible at the sides of every switch, and the
transcription gate could not see it: it checks that the outlines are quoted,
not the order they are painted in.

The nameplate was placed with the horizontal scale on both axes, so a box
whose aspect was not the art's would slide the legend off the plate. Each axis
scales by its own now, and a face asked to draw into an unbounded box says so
rather than positioning at infinity.

The seven outlines are built once rather than on every paint, and the thirty
grips share one shader with the canvas moving under it instead of building
thirty. Ten faces on a screen made that three hundred shaders per repaint.

Part of #1033



=====
# PR #1035 feat(console): the CTRL jacks take a switch, and the switch does something
branch claude/external-pedals-1026 <- claude/pedal-face-art-1033
27 files changed, 2167 insertions(+), 6 deletions(-)
---
commit e08c1ccc 2026-09-12
feat(console): the CTRL jacks take a switch, and the switch does something

The two external jacks had no model and no screen. They have both now, for the
switch half: choose CTRL 1 or CTRL 2, say whether a single or a dual switch is
plugged in, and give each button its actions from the same catalogue the
built-in map draws from.

A jack keeps every type's assignments side by side. Plugging a dual pedal in
for one song and the single one back afterwards must not cost either of them
what it carried, and the accepted design says so outright.

The hardware is a setting, not a preference. A momentary switch reports a
closure and a release, so it has a Press and a Hold; a latching switch reports
only that its state changed, so there is nothing to time a hold against and it
carries one action. The screen says which, and says why, rather than offering
a Hold that could never fire.

The artwork is the study's own generated art, downscaled to what the screen
draws and converted to WebP: 284 KB against the 2.6 MB the PNGs weigh, on an
appliance image. It depicts a category of pedal, not a product anyone can buy.
What is exact is where the switches are, because that is what a performer
points at: the centres are measured in the source raster and the hit targets
are placed as fractions of it, so any rescale keeps them on the switch.

Expression is in the model and not in the type picker. What it needs —
calibration, and a list of destinations with their own heel and toe — is its
own part, and a type that opened an empty panel would be worse than one not
offered yet. The Controls panel, where a button drives FX activations and
parameter values, is the same story.

The action picker moved into one function both screens call, so the built-in
map and the jacks cannot drift about what a control can be asked to do.

Part of #1026

---
commit b1a37fbe 2026-09-12
fix(console): the dual pedal has two contact indicators, not one

Review of the jack setup. The study measures an indicator above each of the two
switches; the port carried the first and dropped the second, so button 2's
contact would have had nowhere to show once a jack can report one.

The face had a gate for exactly this class of error and the jacks had none, so
they have one now: the study's `artwork` object is parsed out of the JavaScript
and compared against the app's, raster size, switch centres and indicator
centres alike. A pedal added there fails until one is added here. Dropping the
second indicator again fails it and nothing else.

The study is committed with it. It is the source of these numbers and it was
untracked, which is the same hole that had the built-in map drawing rounded
rectangles.

Also drops `ExternalJack.fromName`, which nothing called: the setup reads the
jacks by iterating them. It comes back where a jack has to be parsed out of a
source id, which is the part that makes these assignments fire.

Part of #1026



=====
# PR #1036 feat(pedal): the CTRL jacks reach the same interpreter the footswitches do
branch claude/external-dispatch-1026 <- claude/external-pedals-1026
11 files changed, 652 insertions(+), 17 deletions(-)
---
commit 97975749 2026-09-12
feat(pedal): the CTRL jacks reach the same interpreter the footswitches do

The jacks had a screen and no dispatch: what a performer assigned to an
external switch did nothing, because nothing carried a jack's contact into the
app.

The console board reads those jacks alongside the ten footswitches and the
encoder, so an external switch arrives the way a footswitch does: a Note on the
same link, at numbers that follow the plate's. A build that predates them
decodes nothing rather than mistaking one for a footswitch, and the numbers are
a wire contract with firmware that does not exist yet, so both protocol copies
carry them and the C suite pins them.

One event for both edges rather than the plate's pressed and released pair: a
latching switch has no press and no release, only a contact that is now closed
or now open, and both hardwares have to arrive the same way for the setup to
decide what a change means.

The accepted event rules, in the cubit:

- Momentary with a hold waits for the release, because until the threshold
  passes neither half is known to be the one the foot meant. Reaching the
  threshold runs the hold and consumes the release.
- Momentary with no hold acts on contact, like the plate's own switches.
- Latching runs its action on every CHANGE. A state that did not change is not
  a change: a resent message or a bouncing switch must not act twice.
- Only the active type dispatches. A dual pedal's second switch is silent
  while the jack is set to a single one, whatever it still carries.

The contact register tracks the WIRE, not the assignment, so a switch that was
down while nothing was listening is still down when something starts.

The gesture registry now keys on a control's own enum rather than on
PedalButton, so the jacks and the plate share one machine and cannot diverge
about when a pending gesture is retired.

Nothing plugs in yet: no firmware sends these notes and no jack transport
exists. What this closes is that an assignment now has a path to the one
interpreter, tested end to end in software.

Part of #1026

---
commit cafd2a3b 2026-09-12
fix(pedal): a link drop forgets what the jacks were doing, and a jack is named not indexed

Review of the dispatch.

The contact register survived an unplug. It exists to tell a change from a
repeat, and across a link drop there is nothing to compare against: a switch
still down when the cable goes reports its closure again on the way back, and a
remembered "already closed" swallowed it. The switch then did nothing until the
foot came off and went back on.

The jack was reached by indexing the app's two jacks with arithmetic on the
wire enum's own index. They are declared in different packages, so a switch
appended to one would have indexed past the other at runtime. It is an
exhaustive switch now, which fails to compile instead, and the wire enum drops
the `jack` getter that invited the coupling.

Adds the two paths nothing covered: a take in progress refuses a jack the way
it refuses the plate, and the register clearing across an unplug.

Part of #1026



=====
# PR #1039 feat(pedal): an expression pedal's wire numbers, travel and value dispatch
branch claude/external-expression-1026 <- claude/external-dispatch-1026
18 files changed, 1099 insertions(+), 18 deletions(-)
---
commit 9951ef64 2026-09-12
feat(pedal): an expression pedal's wire numbers, travel and value dispatch

The third piece of part 4f. An expression pedal is a potentiometer the
console board reads on the same CTRL jack a switch uses, so its position
reaches segno on the link the ten footswitches and the encoder already
share: an absolute Control Change, one number per jack, carrying the RAW
reading. Both protocol copies hold the numbers and the C contract suite
pins them, because they are a contract with firmware that does not exist
yet.

7 bits, one message. The inbound half of this link is 3-byte MIDI only --
segno's native capture drops SysEx -- so a higher-resolution position
would need the MIDI 14-bit MSB/LSB pair and a half-assembled value held
between two messages, which would move the wire contract out of the
codec and into whatever held that state. 128 raw steps is what a
commercial expression input delivers; the cost lands at the bottom of the
calibration range, where a span near the accepted 10% minimum leaves
about 13 distinct positions. If the bench shows that stepping, the answer
is a 14-bit pair on the wire.

Calibration is why the wire carries a raw reading at all. A pedal's
electrical range and its travel are not the same thing, and a pedal can
be wired the other way round, so the app is taught both ends and the same
subtraction puts 0 at whichever was captured as the heel. A travel too
short to divide by positions nothing rather than turning pot noise into a
full sweep.

Dispatch reuses the continuous-binding model a learned MIDI CC already
goes through: one normalized target, resolved against the live rig,
skipped when what it named is gone. A target that disappeared is never
repointed -- a pedal bound to a filter cutoff must not start sweeping the
delay that replaced it. Both sources now write through one method, since
master gain has a second reader in this cubit and a write that skipped
the accumulator would make the next encoder detent jump.

Not gated on the take lock, which every switch path is: that lock stops a
take starting behind the power-off route, and sweeping a filter starts
nothing.

Part of #1026

---
commit 4b8be459 2026-09-12
fix(pedal): a calibration the wire could not have produced, and one name for the value write

Three from my own review.

An end stored outside the raw 0..1 domain is rejected rather than pulled
into it. A reading the wire cannot produce says nothing about where the
pedal's travel is, and clamping would invent a travel the foot never
took; the jack reads as untaught instead, which the screen already has a
state for.

The shared write is `_applyValueTarget`, not `_writeValueTarget`: the old
name was one character from the repository extension method it wraps, and
the file already names its dispatch helpers `_applyControllerValue` and
`_applyControllerSwitch`.

And the wire numbers are pinned to their literals on the Dart side too.
The C suite pins the same three macros; nothing can compare the two
languages, so each side has to hold the number for a one-sided change to
fail.

Part of #1026



=====
# PR #1041 feat(control): the expression half of External pedals
branch claude/expression-screen-1026 <- claude/external-expression-1026
28 files changed, 2883 insertions(+), 62 deletions(-)
---
commit 69ea159c 2026-09-12
feat(control): the expression half of External pedals

The screen an expression pedal needs, and the type picker finally offers
it. Four bodies of one page, because the accepted design draws the
pickers and the calibration as whole views rather than panels: the lists
behind them are as long as the rig is. Back steps through them, so the
page keeps one draft and one Save.

Two different things are drawn beside the pedal, which is the point of
the pair. The meter shows the raw reading whether or not the pedal has
been taught anything, so a performer can see the jack is alive. The
number shows the position within the taught travel, and shows nothing
until there is a travel to measure against -- a percentage of an unknown
range would be a number that means nothing.

A jack that has reported no position at all reads as not connected. The
board is expected to report each jack once when the link comes up, which
is what makes that reading honest; the protocol header now says so, since
it is the only place the obligation can live.

Teaching the travel stages a draft of a draft. Use calibration puts the
captures in the page's draft and Save commits them, so a half-taught
pedal never replaces a working one; a travel under the accepted minimum
is refused in the panel the performer is standing at rather than stored
and ignored later; and the captures are discarded when the link drops,
because they were readings from a board that is no longer there.
Sweeping to teach the ends writes nothing, which the interpreter is told
before the view opens rather than after.

Choosing what to sweep reuses part 4b's continuous targets rather than
growing a second catalogue: pick a destination, then a control on it. A
track's own fader and the effects on its whole-track chain are ONE
destination, because they are one thing to the performer, and the kinds
are the Effects page's own Live inputs / Recorded tracks / Outputs. A
control already swept is offered and refused rather than hidden, since a
control that vanished from the list would read as a rig that does not
have it. Repointing a mapping keeps its endpoints: the performer chose
how far this pedal should travel, and a different destination does not
change that.

Two things the pen draws that are not here, both for the same reason --
the app has no source for them. Each row's 52 x 68 illustration comes
from the extracted Looper X factory images, which the owner rejected for
shipping, and no surface in this app draws effect icons. Double-tap to
reset an endpoint and encoder editing are accepted interactions that no
slider on this console implements; they belong to LoopSlider and the
encoder-focus model, not to this screen.

Part of #1026

---
commit 1f6b563d 2026-09-12
fix(control): repointing to the control it already has, and keys that are identities

Three from my own review.

Choosing, under Change control, the control a mapping already sweeps sent
its row to the bottom of the list: the repoint removes and re-adds, and
the target it already has is deliberately selectable (it is excluded from
what the picker refuses). A choice that changed nothing now changes
nothing.

The picker's rows and the mapping values are keyed by a target's
canonical form rather than that form's hash. The canonical form IS the
target's identity; two hashes that collided would be two rows of one list
sharing a key, which is a crash rather than a wrong label.

And the remembered cubit sits with the rest of the page's state instead
of in the middle of the pen's metrics.

Part of #1026



=====
# PR #1043 feat(pedal): an external button drives effects and parameters beside its actions
branch claude/external-controls-1026 <- claude/expression-screen-1026
7 files changed, 1174 insertions(+), 22 deletions(-)
---
commit f2bd9229 2026-09-13
feat(pedal): an external button drives effects and parameters beside its actions

The dispatch half of part 4f's Controls panel. A button can now turn any
number of effects on and off and set any number of parameters, in the
same gesture that runs its Press, Hold or On change.

Two different facts about a button feed those controls, and they are
not the same fact. ON / OFF is logical: each completed press flips it, a
latching switch sets it to its contact, and it is remembered across a
restart because an effect being on is part of how the rig sounds. HELD
is physical: the contact is closed right now. An effect is active On,
Off, Held or Released; a parameter switches between two values on On /
Off or on Held / Released.

The accepted rules, each tested and mutation-checked:

- With no Hold, a press is complete on contact and flips the button
  there. With a Hold, only a completed short press flips it, and running
  the Hold does not also flip it -- which is what makes a hold usable
  beside On / Off. The tap is armed even with no press action, because
  the controls hang off the gesture, not off the action.
- Held and Released follow the contact and do not wait for the hold
  threshold. A latching switch never reports how long a foot stayed on
  it, so they are skipped there.
- Writes are edge-triggered, never level. Saving a mapping, opening the
  screen or plugging a pedal in writes nothing, and a control moved by
  hand stays where it was put until the button next says otherwise.
- A button the active type does not have writes nothing, so an Off or
  Released control cannot turn an absent source into an active effect.
- Disconnect and Save both end a hold and apply what Released means --
  on Save, under the setup the hold was pressed under -- and a foot still
  down after a Save has to lift before it counts again.

ON / OFF is stored under its own settings key, apart from the setup.
The setup is configuration, edited as a draft and undone by Cancel; a
stomp is not.

Not the accepted design's storage for activations, and on purpose: the
design keeps an effect's activation rule on the rack, and this app has
no rack activation rule to keep it on. Every other source that toggles
an effect -- a footswitch binding, a learned MIDI switch -- carries its
binding on the source, so this one does too, and removing it simply
stops future writes.

Part of #1026

---
commit 1562b8e9 2026-09-13
fix(pedal): a take lock ends an old hold and refuses a new one

From my own review. Under the take lock the contact handler returned
before anything about a button's controls, which went wrong both ways.

A hold that began before the lock never ended: the foot lifting during
it wrote nothing, so a Held effect stayed on under a dialog, outliving
the gesture that turned it on. Released starts no take, so it now
applies while the lock is up, beside the gesture cancel the plate
already does.

And a closure refused by the lock was still in the contact register, so
its release after the lock wrote Released for a hold that never began
-- a real write, which can move a knob the performer set by hand. A
refused closure is now held back until the foot lifts, by the same
mechanism a Save uses.

Part of #1026



=====
# PR #1044 feat(control): a button's Controls panel
branch claude/external-controls-panel-1026 <- claude/external-controls-1026
21 files changed, 1966 insertions(+), 175 deletions(-)
---
commit 4ea276de 2026-09-13
feat(control): a button's Controls panel

The screen half of part 4f's last piece. A button's editor gains the
accepted Actions / Controls tab, and Controls lists every effect and
parameter the button drives, with the rule of the one open below it.

An effect's rule is its condition: On, Off, Held or Released, with the
line under it saying what the choice means. A parameter's is its
behavior, On / Off or Held / Released, and its two values. On a latching
switch the two conditions that read how long a foot stayed on the button
are offered and refused rather than hidden, with the reason written
under them.

Adding a control happens inside the button's editor, not over the
page: the switch art stays beside it, because the performer is still
adding to THAT button. The destination step reuses the expression
pedal's picker at one column; the control step lists the destination's
effects first and then its parameters in one list, and since that list
has no section headings, a parameter row names its effect. A newly
added parameter starts at the value it has NOW on both sides, so adding
the mapping invents no sound change, and moving a value edits the draft
and writes nothing.

Three pieces now shared, because this PR would otherwise have written a
third copy of each:

- One control row, used by the expression pedal's sweeps, a button's
  controls and both pickers, so the three read as one list.
- One list around it, which keeps the open row in view. That is not
  decoration: the list shrinks when a parameter's values open below it,
  and a selected row left scrolled out of sight would have its values
  edited with nothing on screen saying whose they are.
- The accepted design's overflow arrow, which neither list had.

The repository gains a master gain reader and the resolver a value
reader, both for the starting value above.

Part of #1026

---
commit fdc92b4f 2026-09-13
fix(control): a scrolled list stays scrolled, and a picker closes with its jack

Two from my own review.

The shared control list revealed its open row on every rebuild, not
only when the selection changed. The expression pedal's list rebuilds
each time the pedal reports a position, so a performer scrolling past
the open row was snapped back to it the moment the pedal moved. It now
reveals only when which row is open, or how many rows there are, has
changed.

And the toolbar stays on screen while a button's control is being
chosen, so the jack or the type could be changed with the picker still
open -- over a different button, with a destination chosen for the old
one. Changing either now closes it.

Part of #1026



=====
# PR #1045 feat(control): the External pedals rows draw the factory pedal pictures
branch claude/external-row-art-1026 <- claude/external-controls-panel-1026
17 files changed, 351 insertions(+), 37 deletions(-)
---
commit 1e8ba6f0 2026-09-13
feat(control): the External pedals rows draw the factory pedal pictures

The owner's call: the rows use the Looper X factory illustrations for
now, the same ones the Effects page already draws from the fx_catalogue
package. No generated artwork.

Resolved the way the Effects page resolves them, so a pedal in a row
here is the pedal on that page:

- a parameter, or one effect, draws the pedal it belongs to (its
  module's first stomp illustration);
- a whole chain draws its rack's footswitch picture when the chain IS
  one rack end to end, and nothing when it is several racks or a rack
  beside a lone effect -- there is no single pedal to show;
- a fader or the master gain draws nothing, as the pen draws them.

Every list on the screen gets them through the shared row: the
expression pedal's sweeps (52 x 68), a button's controls and the button
control picker (68 x 68), and the expression control grid (42 x 54),
each at the pen's size and gap. A picture that fails to load keeps its
space, so the names of every row stay in one column.

The footswitch path was spelled in two places, the FX chain strip and
now here; it lives in the catalogue package as fxFootswitchAsset, next
to the family and stomp paths it belongs with.

Part of #1026



=====
# PR #1047 feat(midi): Program Change is captured, and MIDI formats are read explicitly
branch claude/midi-formats-1026 <- claude/external-row-art-1026
19 files changed, 1073 insertions(+), 19 deletions(-)
---
commit 37789aa7 2026-09-13
feat(midi): Program Change is captured, and MIDI formats are read explicitly

The foundation of part 4g. Two things the explicit-format Learn needs
before it can exist, and one learn-hygiene gap they exposed.

Program Change reaches the app. The native parser classified 0xC0 as
ignored and the Linux backend never forwarded it; now the parser reports
LE_MIDI_PROGRAM (one data byte, value always 0), ALSA's PGMCHANGE is
forwarded, CoreMIDI already framed it, and the Dart source carries it as
ControllerSourceKind.midiProgram. The existing 7-bit bindings read a
value and a release, and a Program has neither, so the repository
neither learns nor dispatches one through them; it is carried for the
formats.

MidiProtocol, MidiSource and MidiDecoder state the accepted design's
formats as a pure module: Standard Note/CC/Program, 14-bit CC, NRPN,
Bank + Program and relative CC. Nothing is inferred from one byte -- the
decoder is told the format and returns only COMPLETE readings. Every
worked Learn example in the design document is a test here, verbatim.
The receiver choices the design records as prototype contracts are the
decoder's: a 100 ms freshness window and a fresh pair per update, RPN
selection and the NRPN null selection cancelling NRPN, Data Increment
and Decrement discarding pending data, and a partial bank invalidating
the one before it. Partial state is kept per device, channel and
protocol, and reset per device.

A source's identity is device, channel (or All), format, number, and the
NRPN parameter or bank. Overlap is refused across formats on any shared
raw footprint on channels that meet, on the same device: a CC 53 knob
and a 14-bit CC 21/53 knob cannot both be mapped, because every message
of one is a message of the other. Distinct NRPN parameters and banked
Programs stay independent.

And the learn-hygiene predicate that keeps the pedal's own traffic out
of MIDI Learn did not know the CTRL jacks: the external switch Notes and
the expression CCs added in this slice were learnable, so a binding
learned from one would run beside the pedal setup's own assignment. It
claims them now.

Part of #1026



=====
# PR #1048 feat(midi): the MIDI mapping engine
branch claude/midi-mapping-engine-1026 <- claude/midi-formats-1026
4 files changed, 1309 insertions(+)
---
commit 280f116f 2026-09-13
feat(midi): the MIDI mapping engine

The second of part 4g's three PRs: what a mapped MIDI control DOES, as a
pure engine in controller_repository. Nothing reads it yet; the page and
the switch-over are next.

A mapping is one source with any number of controls: parameters swept
between two values, and actions run on an edge. Its behavior is a knob,
a momentary or toggle button, or a Program trigger, and a mapping can be
disabled without losing its source. Every control's key is opaque here,
so the package stays free of the looper and the app's action vocabulary.

The engine returns outputs rather than writing, and reads a parameter's
current value only because two accepted rules need it. The runtime rules
are the accepted design's, each tested and mutation-checked:

- a knob writes nothing until it lands within a step of the value or
  crosses it, so opening a rig never jumps a parameter;
- a relative control moves from the current value by the parameter's
  step, in the direction its range runs, and stays inside the range;
- a button is down while any channel it listens on is; a toggle flips
  on press; a press action is ended on release; a Program is always a
  press and is never released;
- turning Control off, disabling or deleting a mapping, pausing its
  device for Learn, or a disconnect all end every hold -- momentary
  parameters return to Released, held actions end -- and none of them
  runs an action;
- a reconnect clears contacts, takeover and toggle latches.

Saving refuses a source that overlaps another mapping's, disabled or
not: a disabled mapping keeps its source so it can be turned back on. A
mapping that cannot drive what it carries says why -- a 14-bit, NRPN or
relative control has no edge to run an action on, a Program has no
release -- and a learned source starts with the behavior it fits.

One departure from the prototype's implementation, not its design: a
toggle's parameters are written when the latch moves, not again on
release. The release changes nothing, and writing the unchanged value
would snap back a value adjusted on screen since the press.

Part of #1026



=====
# PR #1049 feat(midi): the control interpreter runs the MIDI mapping engine
branch claude/midi-engine-wiring-1026 <- claude/midi-mapping-engine-1026
14 files changed, 767 insertions(+), 2 deletions(-)
---
commit bb3ba109 2026-09-13
feat(midi): the control interpreter runs the MIDI mapping engine

The first half of part 4g's last piece: the engine from the previous PR,
wired into ControlCubit, persisted, and fed. The MIDI controls page that
creates mappings, and the removal of the old binding model, are next;
until then the new set starts empty, so nothing a performer has mapped
changes.

- MidiDeviceRepository publishes every recognized message UNDEBOUNCED.
  The input stream drops a repeat of one control inside 30 ms so a
  bouncing footswitch cannot double-toggle a take, and 14-bit and NRPN
  pairs repeat far faster than that.
- The open device, while connected, is the identity a mapping's source
  must name. A device going away or being swapped ends its holds under
  the engine's rules, and the arriving one starts from nothing.
- Parameter writes go through the same value-target path a learned CC
  and an expression pedal use, keeping the master-gain accumulator in
  step. Actions go through the shared catalogue's one interpreter, and
  are refused behind the power-off route like a footswitch's.
- Learn listens on the open device in the chosen format, never takes the
  pedal's own traffic, reports the saved mapping the captured source
  overlaps -- disabled or not -- and pauses that device, which releases
  its momentary values. Leaving the editor resumes it; the device going
  away ends Learn.
- Save refuses an overlap or a mapping that cannot drive what it
  carries. Mappings and Control enable persist under their own settings
  keys, and Control off keeps every mapping and ends every hold.

Part of #1026

---
commit 63d8d7b5 2026-09-13
fix(midi): a stored mapping that could not be saved is dropped on read

From my own review of the wiring. MidiMappingSet.fromJson kept a stored
mapping with a problem -- nothing to drive, or an action on a knob -- and
every later edit of the set goes through withMapping, which refuses one.
A single hand-edited or older entry would have made the whole set
uneditable: turning ANY mapping on or off would throw. Such an entry is
now dropped when the set is read.

Part of #1026



=====
# LOCAL page (unpushed)
branch claude/midi-controls-page-1026 <- claude/midi-engine-wiring-1026
48 files changed, 5607 insertions(+), 136 deletions(-)
---
commit 5a9679af 2026-09-14
feat(midi): the MIDI editor pauses its controller, and Learn times out

The accepted design pauses a controller while one of its mappings is being
edited, with or without Learn. ControlCubit now has an editor session
(beginMidiEdit / endMidiEdit) separate from Learn (startMidiLearn /
cancelMidiLearn): opening the editor ends the device's holds and stops it
dispatching until the editor closes.

- A device that disconnected while Learn was open stayed paused forever:
  Learn was cleared without resuming it. The editor now stays open across a
  disconnect, a listening Learn hears the device when it returns, and
  closing the editor always resumes it.
- Learn gives up after 15 seconds and records that it did, so the editor can
  say to try again or to reconnect.
- A MIDI settings write that fails changes nothing: the set is written first
  and only then dispatched and emitted. Writes run one after another, so two
  quick edits cannot both start from the same set.
- MidiSource.withChannel for the channel picker, MidiMappingSet.nextId for a
  new mapping, and MidiSignalLevels, which reads the last value each source
  received for the list's signal meters without touching the engine.

---
commit 2b9e39c9 2026-09-14
feat(midi): the MIDI controls page

The accepted MIDI controls page, opened from a MIDI controls row on the
Control face.

- The list: a card for every MIDI input, the mappings of the input in use
  with a signal meter, a warning and a power button, MIDI control On / Off,
  Add mapping, No mappings and Controller disconnected.
- The editor: the learned control in its explicit format, what Learn
  received, the receive channel, Learn and Cancel Learn, the overlap with
  Edit existing mapping, Knob / fader or Button, Momentary or Toggle, and
  every control the mapping drives with its range or its Pressed / Released
  trigger, Change control and Repair control.
- The pickers as whole views: destinations with Performance actions (refused
  for 14-bit, NRPN and relative controls), a destination's parameters, the
  receive channel and the message format, which starts Learn.

The editor's rules live in MidiMappingDraft and the names in midi_labels, so
the page only decides when to make an edit. The overlap is computed from the
draft rather than carried by Learn, since the channel can still change.

---
commit efa5a24f 2026-09-15
fix(midi): the MIDI controls editor keeps to the rules on every path

Review of the page found paths around the rules it checked in one place.

- Every Learn start refuses a format that carries no press while the mapping
  drives actions, not only the format picker: Cancel Learn then Learn another
  control could learn a 14-bit or relative control the actions could never
  run from, leaving a draft Save could not take and nothing saying why.
- Opening a picker stops a Learn that is still listening, as the accepted
  design does, so a control moved while choosing a destination no longer
  becomes the source out of sight. A Learn that already heard its control
  keeps its Received readout.
- Save keeps whether a mapping is enabled. A power-button toggle still being
  written when the editor opened is no longer undone by the editor's Save.
- A Save, Delete or MIDI control switch that lands after the performer moved
  on no longer closes or writes a notice into the editor they opened since.
- Choosing Button again no longer turns a Toggle button Momentary.
- The meters keep their readings through a visit to the editor, drop a half
  pair when the controller goes away, and read the whole last reading
  instead of a fraction rebuilt with a copied maximum.
- Screen readers can press the page's own controls: each Semantics wrapper
  that hid its InkWell now carries the tap.
- Repair control says Save keeps it; None in the action picker returns to the
  editor; the list's notices sit under the rows in the warning style; a
  disabled row uses the theme's disabled opacity; the two behavior groups
  have their own accessible names.
- The unused MidiEdit.editingId is gone.



=====
# LOCAL removal (unpushed)
branch claude/midi-old-model-removal-1026 <- claude/midi-controls-page-1026
78 files changed, 389 insertions(+), 8703 deletions(-)
---
commit 3876f578 2026-09-14
refactor(midi): the old MIDI binding model and fixed CC scheme are removed

The MIDI controls page and the mapping engine replace the old model, so it
goes rather than staying beside them.

- controller_repository keeps the raw message model, the formats, the
  mappings, the engine and the signal levels. ControllerRepository,
  ControllerMapping (the fixed CC 80-86 transport scheme), LooperAction,
  ControllerEvent, ControllerBinding and its set and events,
  ControllerSource and SimulatedControllerSource are deleted, with their
  tests. BindingBehavior moves next to the pedal binding, its only user.
- MidiControllerSource delivers every message on one stream; the debounced
  inputs stream only the old repository read is gone.
- ControlCubit loses the old binding, learn and simulate paths and the
  controller.mappings blob; LooperBloc loses its controller subscription.
- The Control face drops its MIDI tab and tab strip, and Audio settings drops
  the old EXTERNAL MIDI CONTROL section. MIDI controls is the one place MIDI
  is mapped.
- Tap tempo joins the shared action catalogue, since the fixed scheme was
  the only external way to reach it.
- Tests that covered behavior the new path still has (master gain staying in
  step with the encoder, a missing parameter, a knob value holding across a
  disconnect) are ported to the MIDI mapping tests; the rest go with the code.
- docs/MIDI_FOOT_CONTROLLER.md describes the MIDI controls page.

