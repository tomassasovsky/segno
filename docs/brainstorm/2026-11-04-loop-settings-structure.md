---
date: 2026-11-04
topic: loop-settings-structure
---

<!-- cspell:words Sheeran Blooper Ableton Harmonix mkII XFADE -->

# Loop settings: how the pages should be grouped

Tracking: [#1659](https://github.com/tomassasovsky/segno/issues/1659),
`stage:brainstorm`, `autonomy:plan-gate`. Analysis only: no code changes.

Every `file:line` below is on `claude/segno-integration` at `7142a1052`.
Screens are from the #1590 audit captures (`screens/11-loop-hub.png` and
`20-loop-mode.png` to `25-loop-audio-tempo.png`).

Related work being built now, not repeated here: #1653 (exact tempo entry,
Clear tempo, footer shortcuts to the Tempo and Loop mode pages) and #1654
(tempo, loop timing and bars on the 7-inch readout).

## Summary

- Loop settings has six pages. Three of them hold two settings each. The six
  per-track settings are spread over three pages. Each page has its own track
  selector, and each one starts at Defaults when the page opens. To set up one
  track you pick it three times.
- How a take starts is split over three pages that change each other. Start
  (Pedal or Sound) is on Recording. Count-in is on Tempo & click, and choosing
  a count-in turns Sound off. Record timing is on Length & quantize, and its
  note says the first loop "follows Recording".
- Two page names contain "tempo". "Audio & tempo" does not say what it
  controls: whether a recorded loop follows a tempo change.
- Recommendation: four pages instead of six, in setup order.
  1. **Loop mode**: unchanged.
  2. **Tempo & click**: unchanged. Count-in stays here, as accepted behaviour
     §2.4 requires.
  3. **Recording**: Recording plus Length & quantize. Everything about how a
     take starts and ends.
  4. **Playback**: Playback & overdub plus Audio & tempo. Every per-track
     setting that stays editable while loops play.

  The two scoped pages share one track selection. Tabs on the title row
  replace the hub.
- Each merged page has one lock rule. Everything on Recording locks while a
  take records. Nothing on Playback does. That is already true of the pages
  being merged.

## 1. What is there now

The route is `LoopSettingsPage` with a hub and six submenus, plus a Time
signature page opened from Tempo & click
(`lib/looper/view/loop_settings/loop_settings_hub.dart:14-40`). The hub
(`screens/11-loop-hub.png`) lists them in this order: Loop mode, Recording,
Tempo & click, Length & quantize, Playback & overdub, Audio & tempo.

### Inventory

Scope:
- **Global** means one value for the session.
- **Defaults + track** means the page's Tracks / Defaults / 1-8 selector edits a
  default, and each track can override it.

When it acts:
- **Before** means when a take is armed or starts.
- **During** means while recording or overdubbing.
- **Playback** means while loops play.

| Setting | Page | Scope | Acts | Editable while recording |
|---|---|---|---|---|
| Loop mode (Multi, Sync, Song, Band, Free) | Loop mode | Global | Configuration; playing loops ask Stop loops and switch | No: the capture gate refuses it |
| Start recording (Pedal, Sound) | Recording | Global | Before | No (`loop_recording_page.dart:81`) |
| Second pedal press (Play, Overdub) | Recording | Global | During: the end of a take | No (`loop_recording_page.dart:117`) |
| Tempo (slider, 1 BPM / 0.01 BPM steps, Tap tempo) | Tempo & click | Global | Before the first take; Playback when loops follow tempo | Not locked by the page |
| Time signature (17 choices, own page) | Tempo & click | Global | Before the first take | Not locked by the page |
| Hear click (Off, First recording, Recording, Play & record) | Tempo & click | Global | During and Playback | No (`loop_tempo_page.dart:262`) |
| Count-in (Off, 1, 2, 4 bars) | Tempo & click | Global | Before | No (`loop_tempo_page.dart:297`) |
| Loop length (Auto, or 1-64 bars) | Length & quantize | Defaults + track; shared in Multi | During: when the defining take ends | No |
| Record timing (Immediately, Loop start, 1 bar, 1/2 to 1/16 note) | Length & quantize | Defaults + track | Before: when record and overdub engage | No |
| Later tracks (Auto, x1, x2, x3 of the first loop) | Length & quantize, Defaults scope only (`loop_length_page.dart:364`) | Global | During: when a later take ends | No |
| Playback (Loop, Once) | Playback & overdub | Defaults + track | Playback | Yes |
| Overdub decay (Off to 100%) | Playback & overdub | Defaults + track | During: each overdub pass | Yes |
| Follow tempo (Off, On) | Audio & tempo | Defaults + track | Playback, when the tempo changes | Yes |
| Pitch (Unchanged, Follows speed; a readout when Follow is Off) | Audio & tempo | Defaults + track | Playback | Yes |

Loop-related settings that live outside Loop settings:

| Setting | Where | Comment |
|---|---|---|
| Click and backing level and pan | Stage, Backing & click dialog (`screens/63-backing-click-dialog.png`) | A mix control. The loop setup study keeps click gain apart from when the click sounds, and that split is sound. |
| Click output | Audio routing | Routing, correctly placed. |
| Maximum loop length | Device (`max_loop_length_card.dart`) | Memory reservation, correctly placed. The Length page's refusal text sends the player to "Audio setup" (`app_en.arb:3915`), a page that no longer exists. |
| MIDI clock source, which owns tempo when external | MIDI | System setting, correctly placed (accepted behaviour §7.3). |
| Pedal hold behaviour and assignments | Pedals | Accepted behaviour §4.1. |

### What the pages look like

- **Recording** (`21-loop-recording.png`) holds two rows in the middle of an
  otherwise empty page. Its note reads "Starts after the 1-bar count-in", but
  the count-in is edited on another page.
- **Tempo & click** (`22`) is full and well composed. It already holds what
  accepted §2.4 keeps together.
- **Length & quantize** (`23`) is the fullest page. The Later tracks row was
  added under Record timing in #1199 and appears only under Defaults.
- **Playback & overdub** (`24`) and **Audio & tempo** (`25`) each hold two
  settings under the same selector. Both have about 150 px of empty space
  between the selector and the first row.
- **Loop mode** (`20`) is five cards and nothing else. That is right: it is the
  most consequential choice, and the cards are accepted.

## 2. How a player uses these settings

**Before the first take of a song**, a player decides, roughly in this order:
- the mode;
- whether there is a tempo, and the click and count-in;
- how the first take starts: pedal, count-in or sound;
- whether it has a fixed length;
- how later presses line up: record timing.

Those are five of the six pages today, visited one after another, each
through the hub.

**What they change together:**
- **Start, count-in, record timing and length** define one thing: when a take
  begins and ends. The engine treats count-in and Sound as one
  mutually exclusive pair (`lib/looper/model/record_start.dart:7-40`). A
  positive count-in turns Sound off, yet the two are on different pages.
- **Once and decay** are both "what this loop does as it repeats", and the
  Looper X manual pairs them. Follow tempo and pitch are the same kind of
  per-track playback attribute. All four stay editable during playback and
  capture.
- **Tempo, signature, click and count-in** are the song grid. Accepted §2.4
  keeps them together. The owner rejected splitting them in the September loop
  setup study, calling it a layout problem.

**Mid-song**, a player reaches for:
- **tempo**: #1653 adds the footer shortcut and #1654 the readout;
- **Hear click**: one row on Tempo & click;
- **per-track Once and decay**: Settings, Loop settings, Playback & overdub,
  track chip, value is five touches, and Follow tempo for the same track is
  four more.

Mode changes mid-song are rare and need a stop anyway.

**Rarely, as a habit**, a player changes:
- the second pedal press;
- pitch mode;
- later-track multiples.

## 3. Problems found

1. **Per-track settings are split over three pages, with three separate track
   selections.**
   - Length & quantize, Playback & overdub and Audio & tempo each keep their
     own `_scope`, and each starts at Defaults (`loop_length_page.dart:74`,
     `loop_playback_page.dart:31`, `loop_audio_tempo_page.dart:29`).
   - Giving track 3 a 2-bar length, Once, and Follow off means selecting
     track 3 on three pages.
   - Accepted §2.2 asks for "one shared Tracks / Defaults / 1–8 selector".
2. **The start of a take is split over three pages that change each other.**
   - Start is on Recording and Count-in on Tempo & click. A count-in turns
     Sound off without either page saying so.
   - Recording's note reports the count-in it cannot edit
     (`app_en.arb:3787`).
   - Record timing's note says "The first loop follows Recording"
     (`app_en.arb:3956`), pointing at another page for the other half of the
     answer.
3. **Three pages hold two settings each.**
   - Recording, Playback & overdub and Audio & tempo are nearly empty.
     The accepted behaviour's priorities ask to avoid "oversized cards with
     little information".
   - Each of those pages costs a hub tap and a Back to reach.
4. **Names that mislead.**
   - "Tempo & click" and "Audio & tempo" both say tempo.
   - "Audio & tempo" does not say it is about recorded loops following a tempo
     change. Looper X calls the same thing Time Stretch.
   - The hub says "quantize" and the page says "Record timing".
   - The capacity refusal names "Audio setup" for the page now called Device.
5. **Later tracks appears only under Defaults.**
   - It is the same question as Loop length ("how long is this take?"), but
     for every take after the first.
   - It is shown as a separate compact row appended below Record timing, so it
     looks like an afterthought.
6. **The hub order does not follow setup order.** Recording comes before Tempo
   & click, but count-in and the tempo are set before the first take.

The hub itself is not a problem: its summaries are accurate. But most of what
it summarises (mode, BPM, signature) is already on the stage footer, and it
adds a tap to every setting and two to every move between pages.

## 4. How established loopers group these

Sources are the official manuals; details in **Sources** below.

| Product | Tempo, signature, click, count-in | Start, quantize, record order | Length | One-shot, feedback or decay, tempo follow |
|---|---|---|---|---|
| Boss RC-600 / RC-505mkII | Tempo from Tap tempo, stored per memory. Beat (signature) on the RHYTHM page. We found no count-in parameter; the nearest is RHYTHM START TRIG = BEFORE LOOP. | One REC page per memory: REC ACTION (rec-dub or rec-play), QUANTIZE, AUTO REC and sensitivity | PLAY page LOOP LENGTH; per track MEASURE | One TRACK page per track: 1SHOT, REVERSE, DUB MODE, LOOP SYNC, TEMPO SYNC (pitch or XFADE stretch), PLAY MODE. The 505mkII has a TRACK button per track. |
| Sheeran Looper X | Loop Settings, Tempo and Click: tempo, signature, click, count-in | Rec/Dub/Play order is Global Settings, Pedal Logic. Quantize is with Track Length. | Loop Settings, Track Length and Quantize | Loop Settings: One Shot and Feedback (per track). Time Stretch is its own section. |
| Chase Bliss Blooper | No tempo grid; CV clock dip | Play/Dub order is a dip switch | Set by the take | Repeats knob (global fade per pass) |
| EHX 95000 | Count-in (Off, 1-8 bars) on the hold-PAGE global page next to the click; it works only with Quantize on | Quantize is a panel button | Bars/beats page | Feedback per track; the tempo slider changes speed and pitch together |
| Ableton Live 12 | Control Bar: tempo, Tap, metronome; count-in in the metronome menu | Global Quantization in the Control Bar | Push Fixed Length; Looper device Record Length | Per clip: Loop switch, Launch Mode, Warp and Warp Mode |

What they agree on:
- **Count-in sits with the click** wherever it exists (Looper X, EHX, Live).
  That supports keeping it on Tempo & click.
- **Per-track playback attributes are grouped per track.** This covers
  one-shot, feedback or decay, and tempo follow with its pitch or stretch mode.
  Boss puts all of them on one TRACK page. Looper X pairs One Shot and Feedback
  per track. Live puts Loop, Launch Mode and Warp on the clip.
- **The record action sits with how recording starts** on Boss: one REC page
  has REC ACTION, QUANTIZE and AUTO REC (Segno's Sound start). Looper X instead
  makes the order a global pedal habit. Blooper makes it a dip switch.

Where they differ:
- **Quantize.** Boss puts it with recording, Looper X with length, Live in the
  transport bar.
- **Tempo follow.** Boss and Live make it per track. Looper X gives it its own
  section.

Segno's current six pages copy Looper X's Loop Settings sections almost one
for one (Tempo and Click, Looper Mode, Track Length and Quantize, One Shot and
Feedback, Time Stretch), plus a Recording page. Looper X has a small screen
and a deep menu. Segno has a 1920 x 1080 page per section, so the same split
leaves most pages half empty.

## 5. Options considered

**A. Keep six pages, fix the rough edges.**
- Share the track selection across pages.
- Rename Audio & tempo.
- Reorder the hub.
- Move Later tracks next to Loop length.
- Explain the count-in and Sound link on both pages.

Small and safe. It leaves the start of a take on three pages and three
near-empty pages.

**B. Four pages by phase (recommended).** Mode, the song grid, the life of a
take, what a finished loop does.
- It closes problems 1 to 6.
- It keeps §2.4 and the accepted mode cards intact.
- It reuses every existing control as it is. Only the page composition
  changes.
- Each page keeps one lock rule.

**C. Boss-style by scope.**
- Song: mode, tempo, click, count-in, start, second press.
- Tracks: all six per-track fields under one selector.

This gives the fewest selections. But six scoped fields do not fit one page
at the accepted control sizes. It also puts Record timing and Loop length
apart from Start and count-in again. And it merges Loop mode into a page whose
cards alone are 420 px tall.

## 6. Recommended structure

Four pages, in this order. The title row carries four tabs (Loop mode, Tempo &
click, Recording, Playback), and Loop settings opens on the last-used tab.
Tabs are already the pattern on Effects, Audio routing and Pedals. #1653's
footer shortcuts open the Tempo & click and Loop mode tabs directly.

### 1. Loop mode

The five cards, unchanged.

### 2. Tempo & click

Unchanged: tempo, steps, Tap tempo, time signature, Hear click, Count-in, plus
#1653's exact entry and Clear tempo.

One addition: when Start is Sound, the Count-in row says that choosing a
count-in switches Start to Pedal. Today that change happens without notice.

### 3. Recording

Everything about when a take starts and ends. Locked as one page while a take
records, as both source pages are today.

- **Every take** (global, above the selector):
  - Start recording (Pedal, Sound) and Second pedal press (Play, Overdub), side
    by side.
  - Under them, the existing one-line note, which already names the count-in
    in effect.
- **Track selector** (Tracks / Defaults / 1-8), directly above the fields it
  controls.
- **Loop length** (Auto, or bars), with **Later tracks** (Auto, x1, x2, x3)
  directly under it in the Defaults scope.
- **Record timing**: the seven choices across the width.

Height budget at the current control sizes:
- the two global rows side by side: about 150 px;
- the selector: 64 px;
- Loop length and Later tracks: about 220 px;
- Record timing: about 180 px;
- gaps: about 150 px.

That is about 760 px of the 860 px under the title, and about 830 px with the
recording lock banner. A Penpot pass sets the exact geometry.

### 4. Playback

Everything a recorded loop does as it repeats. All of it stays live during
playback and capture, as today.

- **Track selector**, shared with Recording.
- **Playback** (Loop, Once) and its note.
- **Overdub decay**: the slider, Keep layers / Replace layers, and the note.
- **When the tempo changes**: Follow tempo (Off, On) and Pitch (Unchanged,
  Follows speed) side by side, each with its Default/Custom tag and Use
  default. Pitch stays a readout when Follow is Off (accepted §2.6).

Height: about 640 px.

### Track selection

One selection for the visit, shared by Recording and Playback. It opens at
Defaults, as today. Selecting a track on Recording and switching to Playback
keeps it. Back or Stage ends the visit. Unfinished numeric drafts still cancel
on a scope or page change (`loop_edit_scope.dart`).

### Touch counts

Each tap counts as one touch; slider drags are not counted.

| Task | Now | Proposed |
|---|---|---|
| Set the default record timing | 4 | 4 (3 when the Recording tab was last) |
| Track 3: Once and Follow off | 9 | 6 |
| Set up a song: mode, click, count-in, second press, length, timing | 15 | 11 |
| Move between any two Loop pages | 2 | 1 |

## 7. Mapping: current to proposed

| Current page | Setting | Proposed page | Change |
|---|---|---|---|
| Hub | Six rows with summaries | Tabs on the title row | Hub removed (owner question 3) |
| Loop mode | Mode cards | Loop mode | None |
| Recording | Start recording | Recording, Every take | Moves up; sits beside Second pedal press |
| Recording | Second pedal press | Recording, Every take | None, beyond the move |
| Tempo & click | Tempo, steps, Tap tempo | Tempo & click | None (#1653 adds exact entry and Clear) |
| Tempo & click | Time signature page | Tempo & click | None |
| Tempo & click | Hear click | Tempo & click | None |
| Tempo & click | Count-in | Tempo & click | Note when Start is Sound |
| Length & quantize | Loop length | Recording, under the selector | Page merged |
| Length & quantize | Later tracks (Defaults only) | Recording, directly under Loop length | Moves up from below Record timing |
| Length & quantize | Record timing | Recording, under the selector | Page merged |
| Playback & overdub | Playback (Loop, Once) | Playback | Page renamed |
| Playback & overdub | Overdub decay | Playback | None |
| Audio & tempo | Follow tempo | Playback, When the tempo changes | Page merged; "Audio & tempo" retired |
| Audio & tempo | Pitch | Playback, When the tempo changes | Page merged |
| Each scoped page | Its own track selection | One selection shared by Recording and Playback | Accepted §2.2 |
| Device | Maximum loop length | Device | Fix the "Audio setup" wording in the Length refusal |

Unchanged elsewhere:
- Backing & click levels on the stage;
- click output in Audio routing;
- MIDI clock in MIDI;
- pedal behaviour in Pedals.

## 8. Constraints this respects

- Accepted §1.7: Settings keeps its ten destinations. This changes only the
  inside of Loop settings.
- Accepted §2.2: compact mode cards and one shared selector. The proposal
  implements the shared selector, which the current pages do not.
- Accepted §2.4: tempo, time signature, click and count-in stay together.
- September loop setup study:
  - "The Record/Play sequence stays on the existing Recording page": it does.
  - "Output routing and click gain remain separate from when the click
    sounds": they do.
- No new settings, no removed settings, no engine change. Every control, note,
  lock and refusal path is reused as it is; the work is page composition,
  shared scope state and a Penpot writeback.

## 9. Owner questions

1. **Merge Recording with Length & quantize into one Recording page**, with
   Start and Second press above the track selector and Length and Record timing
   below it? Recommendation: yes. It puts everything about when a take starts
   and ends on one page.
2. **Merge Playback & overdub with Audio & tempo into one Playback page**, and
   retire the name "Audio & tempo"? Recommendation: yes. All four settings are
   per track and stay live while playing.
3. **Tabs on the title row instead of the hub?** Recommendation: yes. It saves a
   tap per setting and per page change, and the stage footer already shows
   mode, BPM and signature.
4. **One track selection for the whole visit, opening at Defaults?**
   Recommendation: yes, shared across Recording and Playback. Opening on the
   selected stage track can come later if mid-song per-track edits turn out
   common.
5. **Count-in stays on Tempo & click**, with a note when Sound start is on?
   Recommendation: yes. Accepted §2.4 and Looper X, EHX and Live all keep
   count-in with the click.
6. **Second pedal press stays on Recording** rather than moving to Pedals?
   Recommendation: stay. It decides how a take ends, which is the Recording
   page's job. Looper X files it under global pedal logic, but Segno's Pedals
   page is about assignments.

## 10. Next

After the owner picks a direction, this becomes a plan:
- Penpot frames for the Recording and Playback pages and the tab row
  (design source per `AGENTS.md`);
- one route-level scope owner;
- the page merges;
- the "Audio setup" wording fix.

None of it touches the engine or the settings owners.

## Sources

Repository:
- `lib/looper/view/loop_settings/` (all pages);
- `lib/looper/model/record_start.dart`;
- `docs/handoff/segno-app/accepted-behavior.md` §1.7, §2.2-2.6;
- segno-design `docs/design/2026-09-06-loop-setup-ux.md`;
- the #1590 audit captures.

Manuals:
- Boss RC-600 Parameter Guide v1.3 (pp. 2-7, 31) and Owner's Manual (pp. 12-19):
  <https://static.roland.com/assets/media/pdf/RC-600_Parameter_eng04_W.pdf>,
  <https://static.roland.com/assets/media/pdf/RC-600_eng04_W.pdf>
- Boss RC-505mkII Parameter Guide v1.3:
  <https://static.roland.com/assets/media/pdf/RC-505mk2_Parameter_eng04_W.pdf>
- Sheeran Looper X User Guide v1.0.0, §5.9 Loop Settings (pp. 32-36), §5.10
  Global Settings (pp. 37-40):
  <https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf>
- Chase Bliss Blooper manual and MIDI manual:
  <https://blooper.chasebliss.com/resources/docs/manual.pdf>
- Electro-Harmonix 95000 manual v1.0 (pp. 7, 12-19):
  <https://www.ehx.com/wp-content/uploads/2021/01/95000-manual.pdf>
- Ableton Live 12 Reference Manual, chapters 8, 9, 16, 19 and 29.25:
  <https://www.ableton.com/en/live-manual/12/>
