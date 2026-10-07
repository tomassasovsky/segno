# Segno gap inventory: what is not built, or not as designed

Date: 2026-10-06. Read-only inventory.

**Code basis.** `origin/claude/segno-integration` at `31c4aafad`. This is the integration build (#1174, "do not merge"). It is 206 commits and 1,388 files ahead of `master`.

Everything in it is unmerged. This includes slices 1–3, the slice 4 stack (#1027–#1156), Fade, the foot Mixer and the settings owner Part 1/2a. The settings owner Parts 2b and 2c (#1175, #1176) are **not** in the integration branch. Unless stated otherwise, "built" below means built on the integration branch, not on `master`.

**Design basis.** The authoritative pen is the main-checkout `segno-ui.pen` (107 MB, blob `44abb1a6`), read through the pencil MCP. The integration branch carries an older 11 MB pen (blob `fdeae1b0`, the `master` lineage plus `Native implementation / …` evidence frames). That pen does **not** contain the accepted current UX, so the 107 MB file is the one compared here.

The 107 MB pen has four top-level groups:
- `01 CURRENT UX`: 49 sections and 318 screens, plus 6 `c/ Implementation` notes;
- `02 EARLIER APPLICATION`: 128 screens and the old `c/` per-screen notes. These are superseded surfaces;
- `03 DESIGN SYSTEM`: 18 frames, including the ten "Segno menu" Settings artworks;
- `04 SUPERSEDED`: 18 frames.

Only `01 CURRENT UX` is the conformance target. "411 screens" matches neither count exactly. The total of depth-2 frames is 488.

**Status legend.**
- D = implemented and matching.
- P = partial, or implemented but deviating.
- M = not built.
- G = blocked by an evidence or hardware gate.

**Size legend** (production lines only, excluding tests, generated bindings and docs):
- S < 200;
- M 200–700;
- L 700–2,000;
- XL > 2,000.

**Native** means C engine work in `packages/segno_engine/src/core`. **HW** means the item needs appliance or physical hardware to verify.

---

## A. Milestone summary (M1–M7 = the seven slices of implementation-map.md)

Counts are judged per accepted-behavior numbered item (the "AB" columns) and per `01 CURRENT UX` pen screen (the "Pen" columns). Section-4 performance functions are counted per table row. Pen counts are approximate: a "P" often means that the earlier-application version of the surface exists.

| Milestone | Epic status (#1009) | AB D | AB P | AB M | Pen D | Pen P | Pen M | Notes |
|---|---|---|---|---|---|---|---|---|
| M1 Tracks + visual foundation | [x] (unmerged) | 3 | 5 | 0 | 7 | 2 | 4 | Missing: CPU readout, Mixer FX-edit and Backing & click strip, the ten-tile Settings, touch lock and double Solo |
| M2 Recording, timing, reversible edits | [x] (unmerged) | 6 | 4 | 2 | 27 | 2 | 11 | Missing: Audio & tempo follow, timing handoff UI, held-take recovery, first-take tempo review |
| M3 Inputs, outputs, Mixer, FX | [x] (unmerged) | 9 | 1 | 2 (+1 G) | 48 | 3 | 4 | Missing: Try preset, shared render recipe (Save audio and Bounce), FX-edit Solo, Track Mono |
| M4 Assignments + foot performance | [ ] in progress | 12 | 5 | 8 | 45 | 9 | 29 (+2 proposals) | Assignments are done. Of the 13 performance functions, 7 are missing: Transpose, Reverse, Speed, Multiply/Divide, Peel, Bounce and Backing |
| M5 Library, sessions, backing, recovery | [ ] not started | 0 | 6 | 6 | 2 | 7 | 60 | The Library is still the earlier Sessions dialog. There is no audio library, backing, USB, backup or repair |
| M6 MIDI sync + instruments | [ ] not started | 0 | 1 | 10 | 0 | 0 | 16 | Native MIDI clock **send** exists but is unexposed; receive is rejected. No instrument domain exists |
| M7 Device + appliance | [ ] not started | 0 | 7 | 0 | 8 | 18 | 17 | Earlier-design tray tabs exist. Missing: display calibration, USB storage and eject, restart, USB updates, controller updater |

Cross-cutting: none of slices 1–4 is merged to `master`. The about 70 open stacked PRs (#1011–#1176) are themselves the first deliverable (epic E0).

---

## B. Work items, grouped into deliverable epics

The field order in each row is: id | title | source | current state and evidence | size | native | HW | deps | issue/PR.

### E0. Land the built stack (process; human merge gate)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E0-1 | Merge slice 1–3 stacks to master | #1009 slices 1–3 | Built. Open stacked PRs #1011, #1013–#1015, #1017, #1018 and #1020–#1024 are unmerged | review | – | – | – | #1010, #1012, #1016 |
| E0-2 | Merge slice-4 assignment stack | #1026 4a–4g | Built, reviewed and green per #1026. Unmerged: #1027–#1035, #1039, #1041, #1043–#1045, #1047, #1049, #1093–#1100 | review | – | yes (pedal and LED proof) | E0-1 | #1026 |
| E0-3 | Merge the Fade, foot Mixer, count-in, monitor, reopen and capture-guard stack | #1117–#1161 | In review. #1174 lists the composition fixes (commit 77aca8333) that must accompany them | review | yes | – | E0-2 | #1120, #1122, #1126–#1161 |
| E0-4 | Land settings owner Parts 2b and 2c | plan Part 2b/2c | Built. #1175 and #1176 are **not yet in integration** | review | – | – | E0-3 | #1159 |
| E0-5 | Physical verification of slice 4 on the console (footswitches, Hold timing, LEDs, CTRL jacks, expression) | AB 4.3, 4.4, 4.6, 4.7, 4.12 | Only desktop and CI evidence exists | – | – | **yes** | E0-2 | #1058, #402, #1026 gate |

### E1. Settings-transaction consolidation (#1159 remainder)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E1-1 | Part 2d: Fade on the shared owner, Session JSON validated at decode, Mixer timeout via `SettingsReceipt` | settings plan §3 Part 2d | Not built. `_restore*`, `flush*` and `_Pending*` copies remain | M (net negative) | – | – | E0-4 | #1159 |
| E1-2 | Part 3: control dispatch collapse (`OwnedValueTarget`, one `_writeOwnedValue`, one origin record) plus two #1093 fixes | Part 3 | Not built. Plan estimate +180/−760 | M | – | – | E1-1 | #1159 |
| E1-3 | Part 4: power-off blocks only recording; "Power off anyway" after a failed Retry; Hear-click default rule; unity top for volume mappings | Part 4; owner decisions 2026-10-05 on #1009 | Not built. Plan estimate +130/−30. Decisions were recorded on #1009 | S | – | – | E1-2 | #1159 |
| E1-4 | Released value after a refused External Held (holder priority across all shared value targets) | #1153 | Not built. Needs a short design decision. Best done on E1-2's single write helper | S | – | – | E1-2 | #1153 |

### E2. Engine and render correctness debt (performance stems, capture guard)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E2-1 | Stem history replay Part 2: staging gaps G1–G4 and log-overrun reporting | #1143 plan | Part 1 is in integration (#1173). Part 2 is not built (about 90 lines) | S | yes | – | E0-3 | #1143 |
| E2-2 | Stem history replay Part 3: native-backed repository handoff test | #1143 plan | Not built (test only) | S | yes | – | E2-1 | #1143 |
| E2-3 | Overdubbed stems omit the pass (renderer activates a pre-pass image) | #1169 | Not built. A failing real-engine test comes first | M | yes | – | E2-1 | #1169 |
| E2-4 | Dry render ignores Stop for snapshot-provenance tracks; restore admitted in the same block as PERF_ARM | #1170 | Not built | S–M | yes | – | E2-1 | #1170 |
| E2-5 | Punch-out drain walks Sync-division tracks with the master clock length | #1157 | Uninvestigated. A failing native test comes first | S | yes | – | E0-3 | #1157 |
| E2-6 | Capture-prep guard gaps: cross-channel launch-grace emptying; ring-full grid clear | #1160 | Not built. Native repro tests come first | S–M | yes | – | E0-3 | #1160 |
| E2-7 | Large-capture recovery without loading the whole PCM; crash durability of the capture bundle | #1078, #727 | Not built | M | yes | yes | – | #1078, #727 |

### E3. Design conformance: Tracks, Mixer, header, Settings (M1 residue)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E3-1 | Compact CPU and clock status in the header, from the real owner | AB 1.5; pen 25 Track tile header | Missing. No CPU readout in `stage_top_bar.dart`. The c/ note (B9Qoq4) says "No invented CPU telemetry". `le_engine_get_callback_telemetry` exists to supply it | S–M | maybe (expose load) | yes (real load) | – | – |
| E3-2 | Mixer strip **FX edit** button beside bypass, opening the FX editor at the track | AB 1.6; pen `Mixer / Tile` | Deviation. `mixer_column.dart:494-500` still says the edit button waits for slice 3f, which has since landed; only `mixer_fx_*` bypass exists | S | – | – | – | – |
| E3-3 | Mixer "Backing & click" auxiliary strip (shared level and pan) | AB 1.6; pen `Mixer · Backing & click / Tile` | Missing. No click or backing strip in Mixer. The click half can ship now | M | – | – | backing half after E7-8 | – |
| E3-4 | Settings as **ten direct illustrated destinations**: Effects, Loop settings, Pedals, MIDI, Audio routing, Device, Network, Displays, Storage, Updates. Use the Segno menu artwork | AB 1.7; pen `05 Loop setup / 01 Settings`; DS `Original Segno Settings artwork` | Deviation. The header Settings icon opens `SettingsTrayCubit` (rail: control/tracks/audio/tuner/network/system). `SettingsPage` is a text left rail (View, Audio, Loop, Routing, FX, Pedals, MIDI, Tracks, Updates). There are no illustrated tiles | L | – | – | – | #494 (superseded direction), #663 |
| E3-5 | Retire the tray and earlier-application surfaces once E3-4 lands: tray rail and panels, `SettingsPage` sections, `sessions_manager_dialog` (after E7-1), `lib/pedal/view/pedal_assignment_page.dart` and `pedal_plate.dart`, Signal-era `signal_graph/`, `fx_editor/fx_block_chip.dart`. Verify each is unused | AB "retire obsolete paths" | Obsolete paths are still reachable | M (deletion) | – | – | E3-4, E7-1 | #768 |
| E3-6 | Optional touch lock (Off by default; pedals, MIDI and encoder keep working; accessible unlock and hold gesture) | AB 4.12; pen 52 `Touch locked · Pedals available` | Missing. No touch-lock code | M | – | yes (gesture) | – | – |
| E3-7 | Optional double-press Solo (Tracks mode only; Hold wins) | AB 4.12; pen 52 `Optional double-press Solo`, `Solo after second press` | Missing | M | – | yes (thresholds) | E0-2 | – |
| E3-8 | Encoder grammar on the physical UART console: press for draft, turn, press to commit, Back to cancel; focus trap and return | AB 1.8; c/ note OaX2R ("Physical UART encoder routing remains a later implementation task") | Partial. Touch and keyboard drafts exist; the UART encoder is not routed | M | – | **yes** | E0-2 | #1058 |
| E3-9 | Cross-cutting design-system debt: geometry tokens, component reconciliation, mode-colour duplication, a11y focus audit | AB 1.7, 1.8 | Partial | M | – | – | – | #504, #506, #507, #768, #198, #1033 |

### E4. Timing completion (M2 residue)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E4-1 | **Pitch/time DSP core** (per-track resample plus pitch-preserving stretch and shift on loop playback). This is shared by E4-2, E6-4, E6-5 and E7-9 | AB 2.6, 4 (Speed, Transpose), 6.5 | Missing. No native entry point. The Octaver's semitone DSP is an insert, not a playback transform | XL | yes | yes (CPU) | E0-3 | – |
| E4-2 | Audio & tempo: Follow tempo On/Off; Unchanged pitch or Follows speed; stored preference returns | AB 2.6; pen 07/04 `Audio tempo defaults`, 07/05 `Pitch follows speed`, 07/06 `Keep recorded speed` | Missing. `loop_audio_tempo_page.dart` is a disabled readout (`loop_audio_unavailable`) | L | yes | – | E4-1 | – |
| E4-3 | Timing-track handoff: Choose timing track, Confirm handoff, and clearing a Sync/Band primary with a compatible successor | AB 1.5, 2.9; pen 45 (2 screens), 51 `Clear timing source · Review` | Partial. Native `le_engine_crown_primary` and `LooperCrownPrimaryPressed` exist, but no UI dispatches the event (only tests). No successor review exists | M | small | – | E0-1 | – |
| E4-4 | First-Auto-take tempo estimate with an optional, non-interrupting half/current/double review | AB 2.8; pen 38/02 `First-take tempo`, 51/01 | Missing. Derived tempo exists (D7), but the measured-seconds estimate and review do not | M | yes | yes (timing) | E0-1 | – |
| E4-5 | Failed capture publication: freeze the measured take; "Save held take" or "Stop retry"; New Loop, recall, restart and restore cannot discard it | AB 2.12 | Missing. No held-take state or copy in l10n | L | yes | – | E0-3, E2-7 | #730 related |

### E5. FX and routing completion (M3 residue)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E5-1 | **Shared render recipe**: finite common cycle or chosen length; include selected recorded material regardless of Stop, Mute or Solo; runnable Post FX; never re-apply printed Pre; Once once; Wrap/Cut; reset destination processing | AB 3.11; pen 49 `Save audio · Shared cycle`, `Bounce · Shared cycle and Mix FX` | Missing. The only renders are the performance-capture offline stems (`perf_render.c`) and the legacy `exportMixdown/exportStems` (`session_repository.dart:593-610`) | XL | yes | – | E0-3 | #926 |
| E5-2 | Try preset (audition a compatible same-layout preset; Keep or Cancel restores the exact baseline; navigation or capture ends the trial) | AB 3.12; pen 46 `Preview and compare` | Missing. No trial state in `fx_cubit.dart` | M | – | – | E0-1 | – |
| E5-3 | Track Solo while editing FX | pen 02 `Track Solo while editing FX / Tile` | Missing in `fx_page.dart` | S | – | – | – | – |
| E5-4 | Track Mono (average recorded stereo before downstream processing; source channels recoverable) | AB 3.7 | Not found in the `Track` and `Lane` models or the engine API | M | yes | – | E0-1 | – |
| E5-5 | Preset export and import to and from USB (Internal or USB; choose a package) | pen 03 `Export presets · Internal or USB`, `Import presets · choose package` | Partial. `fx_presets_import` and `fx_presets_export_all` exist; there is no USB target | S | – | yes | E9-5 | – |
| E5-6 | Backing in Audio routing "Backing & click" | AB 3.1; pen 21/04 | Partial. Click only; `output_routing_tab.dart:329` says backing has no seam | S | – | – | E7-8 | – |
| E5-7 | Exact Looper X parameter parity (239 rack keys, 300 defaults, 26 Single FX schemas); remove "Scale unverified" from shipping UI | AB 3.13, §8 gate | **G**. Evidence blocker; `fxScaleUnverified` ships today | – | – | – | evidence | #887, #891, #911 |
| E5-8 | FX-mode pedal binding fixes (blank cell; 0-based label) | AB 4 FX row; pen 04 `Rack activation`, `Pedal banks` | Partial | S | – | yes | E0-2 | #884, #873, #601 |

### E6. Foot performance operations (M4 remainder; each is native, repository and foot surface, plus Tracks marker and LEDs)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E6-1 | **Reverse** (P1 native about 500; P2 session and reopen about 300; P3 surface about 600) | AB 4 Reverse; pen 13 (4) | Plan only. No `InteractionMode.reverse`; no native entry | L | yes | yes (LED) | E0-3 (#1158, #1161 merged) | #1162, plan PR #1163 |
| E6-2 | **Peel** (P1 about 450; P2 history persistence about 350; P3 surface about 600) | AB 2.10, 4 Peel | Plan only. Peel today is one meaning of `le_engine_undo` | L | yes | yes | E0-3; shares fact and schema numbering with E6-1 | #1164, plan PR #1166 |
| E6-3 | **Multiply / Divide** (P1 about 680; P2 about 350; P3 about 650) | AB 4 Multiply/Divide; pen 16 (8) | Plan only | L | yes | yes | E6-2 P1/P2 (kinds 2–3, history export); E6-1 factoring | #1168, plan PR #1171 |
| E6-4 | **Speed** (absolute ½, 1, 2, 4 and 8× whole loop, pitch coupled; Normal restores only that factor; Speed marker on Tracks) | AB 4 Speed; pen 15 (5) | Missing. No plan, no native entry | L | yes | yes | E4-1 (resampler half), E6-1 (transform reset and origin helper) | #1026 4i |
| E6-5 | **Transpose** (±12 semitones across banks, timing unchanged, global bypass keeps pitches) | AB 4 Transpose; pen 11 (5) | Missing | L | yes | yes (CPU) | E4-1 | #1026 4k |
| E6-6 | **Bounce** (sources across banks, destination, Bounce or Replace & bounce, Keep or Clear sources, tail choice; one grouped Undo) | AB 2.11, 3.11, 4 Bounce; pen 17 (6) | Missing | L | yes | yes | E5-1, E6-2 (history kinds) | #1026 4m |
| E6-7 | Foot **Tuner** as a performance function (inputs by bank; temporary mute of the selected input or pair; A4 420–460 Hz, reset 440; Exit). Align the tuner face | AB 4 Tuner; pen 23 (5) | Deviation. `tuner_tray_panel.dart` is a tray face that by design does **not** mute (earlier pen). No foot mode, no A4, no 18-input paging | M | small | yes | E0-2 | – |
| E6-8 | Foot **Backing** (select prepared files without interrupting; Play/Pause, Stop, seek/jump, page, Exit) | AB 4 Backing, 6.4 | Missing. `ControlActionGroup.backing` is empty ("Empty until the audio library part") | M | – | yes | E7-8 | – |
| E6-9 | Foot **New Loop** plus Record-performance retry by foot | AB 4 New Loop | Partial. `recordPerformance` command exists; New Loop does not | S | – | yes | E7-4 | – |
| E6-10 | **Custom** performance face on screen | pen 10/02 `Performance / Custom`; c/ MV9wz ("The face is a separate piece of work") | Missing. The Tracks face shows while in Custom | M | – | – | E0-2 | #1026 4d |
| E6-11 | Performance feedback on both displays for the new modes; Tracks markers (REV, Speed) | AB 1.4, 4.5 | Missing for the new modes | S per op | – | yes | E6-1..E6-6 | #1026 4n |
| E6-12 | Shared value targets for backing, click level and pan, and instrument parameters in the action and target catalogue | AB 4.11 | Partial. Mix, Click, loop-field and Fade targets exist; backing, instrument and session actions do not | S each | – | – | E7-8, E8-x | – |

### E7. Library, sessions, backing, durable recovery (M5)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E7-1 | **Library shell**: full-screen Library with Sessions and Audio tabs, Internal/USB, search, one-level folders, Return to tracks. Replaces the Sessions dialog | AB 6.1, 6.2; pen 19/01 `Session library`, 18/01 | Deviation. `stage_library` opens `showSessionsManager` (a 744-wide dialog with Rename, Duplicate, Delete, Save as and Save) | L | – | – | E0-1 | #682 (old plan) |
| E7-2 | Session preview plus **Listen** audition: populated tracks only; real waveform, length, layers, mute and FX; isolated from the rig; ends on navigation or capture | AB 6.3 | Missing. No audition player and no bundle waveform reader | L | yes (isolated player) | – | E7-1 | – |
| E7-3 | Explicit Open: preserve outgoing work, confirm a playback interruption, restore stopped | AB 6.1; pen 19/03 | Partial. Stopped recall exists (#1134). Preview-then-Open and outgoing preservation do not | M | – | – | E7-1 | #1134 |
| E7-4 | **New Loop**: auto-preserve, clear tracks and history, keep sound, tempo, pedal and instrument setup, reset performance transforms, leave backing stopped | AB 6.1; pen 19/02, 19/06 | Missing | M | small | – | E7-5; transform resets from E6-1, E6-4, E6-5 | – |
| E7-5 | Session identity: automatic names; Save/checkpoint vs Save as vs Duplicate; delete protection for the current session; shared-audio references with stable file identities | AB 6.2, 6.9 | Partial. Rename, duplicate, delete and save exist in `session_repository.dart:367-451`; no automatic names, references or protection | L | – | – | E7-1 | – |
| E7-6 | Recall field ownership audit (musical vs appliance) | AB 6.9 | Partial. `session_mapping.dart` and the settings coordinator exist; instruments, pedal colours and actions, expression ranges and prepared backing need confirming | M | – | – | E1-1, E8-7 | – |
| E7-7 | **Audio library**: browse Internal/USB, select, preview, managed internal copy, Add to prepared, Export to USB, Use as backing, Use in loop | AB 6.4; pen 18/01–06 | Missing | L | – | yes (USB) | E7-1, E9-5 | – |
| E7-8 | **Backing player**: an independent routed source; prepared numbered list with Move Up/Down; Play/Pause/Stop rewind; seek the loaded file; End = Stop, Repeat or Next (no wrap); Clear backing; level and pan; excluded from renders | AB 6.4, 3.1, 3.11; pen 18/05, 18/07–11 | Missing. No engine, repository or bloc seam (`output_routing_tab.dart:329`) | XL | yes | – | E0-3 | – |
| E7-9 | **Track import** from audio: into an empty track; Use file tempo, Adapt or Leave; unknown tempo needs confirmed bars; external clock needs Adapt; final check of source, destination, storage and clock; starts stopped | AB 6.5; pen 18/12–15 | Missing as a user flow. Native `le_engine_import_track` exists (session restore only). Adapt needs the stretch core | L | yes (Adapt) | yes (USB) | E7-7, E4-1 | – |
| E7-10 | **Save selected audio** (tracks, destination, name) on the shared render | AB 6.6; pen 18/03–04 | Missing | M | – | – | E5-1, E7-7 | #926 |
| E7-11 | Record performance: Internal or **direct USB** chosen before Start; same-drive and exact-part recovery; the indicator persists elsewhere | AB 6.6, 7.7; pen 20/01, 48 (4) | Partial. Arm, finalize, recover and Follow-output (`followOutput` in the manifest) exist. No destination choice, no USB | L | yes (drain target) | **yes** | E9-5 | – |
| E7-12 | **Long recordings**: ordered 2 GB parts, 1 GB reserve, 60-second warning from actual capacity; stop at complete frames when space is low or writes are slow; exact allocation accounting | AB 6.7; pen 47 (3) | Missing | L | yes | **yes** | E7-11, E2-7 | #1078, #727 |
| E7-13 | Export finished audio and presets to USB (Keep both/Replace; cancel, absent or wrong drive and full-disk errors preserve content) | AB 6.8; pen 20/07–12 | Missing. `reExport` re-renders locally only | M | – | yes | E9-5 | – |
| E7-14 | Session backup to USB and restore as independent copies (compact Library action) | AB 6.8; pen 34 (6) | Missing | L | – | yes | E7-5, E9-5, E7-19 | – |
| E7-15 | Complete **appliance backup** (review sessions, recordings, backing, presets and settings) plus Restore and restart | AB 6.8; pen 44 (3) | Missing | L | – | **yes** | E7-14, E9-6, E9-7 | – |
| E7-16 | Recovery from a pending Library transaction: missing or damaged recorded audio by exact identity, integrity, format and duration, including Undo/Redo dependencies | AB 6.10; pen 36 (5), 42 (3) | Missing | L | yes | – | E7-19 | – |
| E7-17 | Repair connections: physical input and output ports, CTRL and MIDI connections; stereo roles kept; occupied or incompatible ports refused | AB 6.10, 6.11; pen 40 (4), 43 (3) | Missing | L | – | yes | E7-16 | – |
| E7-18 | Repair control targets at session open (From/To review, assignment count) | AB 6.11; pen 41 (5) | Partial. Per-editor target repair exists in the External and MIDI editors; the session-open flow does not | M | – | – | E7-16 | – |
| E7-19 | **Native atomic publication plus cross-guards**: audio, files, metadata, history and allocation in one recoverable operation; capture, transfer, eject, device change, calibration and restart honour each other's guards at commit | AB 6.12 | Partial. Capture recovery exists; there is no transaction spanning the Library | XL | yes | yes (power-cut) | E0-3, E2-7 | #727 |
| E7-20 | Decide and then retire or rehome the legacy mixdown, stems and `.als` export | #926; `session_repository.exportMixdown/exportStems`; `daw_export` | Not in the accepted design; see D3 | S | – | – | D3 | #926, #279 |

### E8. MIDI sync and virtual instruments (M6)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E8-1 | MIDI clock **receive**: external source owns tempo; Waiting, Synced and Clock lost; local tempo and Tap locked out | AB 7.3; pen 27 (6) | Missing. `LE_CMD_SET_CLOCK_MODE` rejects `receive` (header line 147ff) | L | yes | **yes** | E0-3 | – |
| E8-2 | Follow Play/Stop (default Off), Start/Stop/Continue semantics, Song Position (stopped only) | AB 7.3 | Missing | M | yes | yes | E8-1 | – |
| E8-3 | Clock loss: close the measured partial take, cancel queued starts, Keep playing or Stop loops; reconnect follows clock without starting | AB 2.12, 7.3; pen 27/04–05, 51/03 | Missing | M | yes | yes | E8-1 | – |
| E8-4 | Send Clock and Play/Stop per output, no echo, sender offset −10…+10 ms, external relay, DIN Thru | AB 7.4; pen PARITY `Clock / Sender offset`, `Clock / DIN Thru` | Partial. A native 24-PPQN **send** exists for Multi/Sync/Band, with no app exposure, offset, relay or Thru. DIN does not reach the app on the appliance | L | yes | **yes** | E8-1, #1069 | #1069 |
| E8-5 | MIDI Sync settings page plus main-view sync status; "under MIDI clock" variants of Loop settings | pen 27/01, 27/06, 05/08, 06/04, 06/09, 07/07 | Missing | M | – | – | E8-1 | – |
| E8-6 | Multi-device MIDI input (the pedal path reads whichever single input was captured) | AB 4.9, 5.3 | Partial | M | yes | yes | – | #1040 |
| E8-7 | **Instrument domain**: persistent identities, own voices and buses, fixed controller routes, routable audio inputs; sound-armed recording with Hear live Off | AB 5.1, 5.2, 3.8 | Missing. No instrument code anywhere | XL | yes | – | E0-3 | – |
| E8-8 | Synthesis engine: 19 Segno patches in Keys, Organs, Synths, Bass, Strings, Drums and Percussion, each with three family parameters; polyphony and CPU budget | AB 5.7, §8 gate | Missing | XL | yes | **yes** (CPU) | E8-7 | – |
| E8-9 | Instrument MIDI input: device, channel and range; 128 notes; pad remaps; layers and splits; independent of Remote control enable; reconnect never resumes held notes | AB 5.3, 4.9; pen 54 `MIDI input and keyboard range` | Missing | L | yes | yes | E8-7, E8-6 | – |
| E8-10 | Sustain Held/Latch from several contributors; CC64 remap rules; pitch bend, modulation and pressure; release on loss, disable or Cut | AB 5.6 | Missing | L | yes | yes | E8-9 | – |
| E8-11 | Computer key mappings plus Learn notes and chords (separate editors, nested Cancel) | AB 5.4; pen 54 `Computer key mappings`, `Learn notes and chords` | Missing | M | – | – | E8-7 | – |
| E8-12 | Instruments UI under Settings → Audio routing → Instruments: sound library and audition (Apply/Cancel), unavailable-sound recovery, live-monitoring feedback, remove with capture guard, art | AB 5.1, 5.7–5.9; pen 54 (8) | Missing | L | – | – | E8-7, E8-8 | – |
| E8-13 | Instrument note, chord and sustain actions plus family parameters through shared assignments (External, MIDI, pedals) | AB 5.5, 4.8 | Missing | M | – | yes | E8-12, E0-2 | – |
| E8-14 | Instruments in Recording inputs and Tuner exclusion | AB 3.8, 5.1 | Missing | S | – | – | E8-7 | – |

### E9. Device and appliance (M7)

| id | title | source | state / evidence | size | native | HW | deps | issue/PR |
|---|---|---|---|---|---|---|---|---|
| E9-1 | Device page to the accepted design: identity and capabilities, rate, buffer, measured latency and health first; Apply as a draft with stop confirmation and a capture guard | AB 7.1; pen 28 `Audio settings`, `Apply during playback` | Deviation. `device_audio_tab.dart` is the earlier tray tab: device, rate and inputs rows plus an in-flight banner | M | – | yes | E3-4 | – |
| E9-2 | Latency: automatic isolated path first, cable-fallback instructions, previous result kept, invalidated on config change | AB 7.2; pen 28 `Measure latency`, `Automatic measurement` | Partial. A single loopback `le_engine_measure_latency` with a Measure button exists | M | yes | **yes** | E9-1 | #893 |
| E9-3 | Interface loss and explicit reconnect; Repair from Stage | AB 7.2; pen 28 `Interface disconnected`, `Reconnect audio`, `Repair from Stage` | Partial. A device-lost banner exists and the reopen keeping loops is in review (#1140). Repair from Stage is missing | M | – | yes | E0-3 | #1140 |
| E9-4 | **Displays**: left Track display first; per-display brightness; touch calibration (gather, test before Keep; cancel, timeout or disconnect keeps the old profile); idle dimming that never blanks during performance | AB 7.6; pen 30 (6) | Partial. One software brightness (`display_brightness_cubit.dart`, tray capsule); `display_system_tab.dart` holds waveform, high contrast and refresh rate. No calibration, no idle dimming | L | – | **yes** | E3-4 | #1072 |
| E9-5 | **Storage and USB service**: Internal and USB capacity, shared transfer state, Eject through OS unmount, Safe to remove, Eject failed, Low internal space; reconnect not consumed by stale callbacks | AB 7.7; pen 31 (6) | Partial. Internal breakdown and free space only (`storage_system_tab.dart`); no removable-drive service. **Prerequisite for every USB item** | L | – | **yes** | – | – |
| E9-6 | Power: Restart path ("Restarting" with no ellipsis, reopens stopped); transfer and eject guards | AB 7.8; pen 32 `Power options`, `Restarting` | Partial. Shutdown with save, failure and Keep playing exists (`power_off_*`); no Restart | S–M | – | yes | E1-3 | – |
| E9-7 | Updates: load a USB package (invalid or removed stays invalid; drive unnecessary after staging); Update interrupted; boot-health rollback | AB 7.9; pen 33 | Partial. Check, download and stage exist (`UpdatePhase`); no USB package; the mark-good safety net is broken | M | – | **yes** | E9-5 | #976, #883 |
| E9-8 | About and controller identity; controller updater Unsupported, Updating and Recovery | AB 7.9, §8 gate; pen PARITY `Controller / …` | Partial. About and licences exist; the controller updater is **G** (RP2350 capability unverified) | M | – | **yes** | evidence | #670 |
| E9-9 | Network to the accepted design: one compact connected row with IP; full-width list; Wi-Fi association vs internet reachability; saved profiles, change password, forget; failed joins keep the prior link | AB 7.5; pen 29 (8) | Deviation and partial. The earlier-design `wifi_page.dart` strip exists; no "Connected without internet" | M | – | yes | E3-4 | #467, #432 |

E9-5 (the removable-storage service) is the shared prerequisite for every USB item. E9-6 and E9-7 provide restart and restore plumbing for E7-15.

---

## Pen section → status (01 CURRENT UX)

| # | Section | Screens | D | P | M | Main evidence |
|---|---|---|---|---|---|---|
| 01 | Effects · destinations | 12 | 12 | 0 | 0 | `fx_page.dart` kinds and strips, Pre/Post, outputs |
| 02 | Effects · chains & controls | 7 | 6 | 0 | 1 | Track Solo while editing FX is missing |
| 03 | Sound library & presets | 8 | 6 | 2 | 0 | USB export and import missing |
| 04 | FX activation & pedal banks | 2 | 0 | 2 | 0 | #884, #873 |
| 05 | Loop setup | 11 | 9 | 1 | 1 | Settings tile grid deviates; Tempo from MIDI clock missing |
| 06 | Loop length & track defaults | 9 | 7 | 0 | 2 | MIDI-clock variants missing |
| 07 | Playback, decay & audio tempo | 7 | 3 | 1 | 3 | Audio & tempo is a readout only |
| 08 | Pedal setup & LEDs | 7 | 7 | 0 | 0 | PRs #1028–#1034 |
| 09 | External pedals | 14 | 14 | 0 | 0 | #1035 stack |
| 10 | Performance · Tracks, Custom, FX & Mute | 5 | 1 | 1 | 1 | Custom face missing; 2 proposals undecided |
| 11 | Performance · Transpose | 5 | 0 | 0 | 5 | – |
| 12 | Performance · Mixer | 4 | 4 | 0 | 0 | `foot_mixer_view.dart` (#1123) |
| 13 | Performance · Reverse | 4 | 0 | 0 | 4 | plan #1163 |
| 14 | Performance · Fade | 4 | 4 | 0 | 0 | `foot_fade_view.dart` (#1131, #1147) |
| 15 | Performance · Speed | 5 | 0 | 0 | 5 | – |
| 16 | Performance · Multiply & Divide | 8 | 0 | 0 | 8 | plan #1171 |
| 17 | Performance · Bounce | 6 | 0 | 0 | 6 | – |
| 18 | Audio library, backing & import | 15 | 0 | 0 | 15 | – |
| 19 | Sessions · New loop & recall | 6 | 0 | 3 | 3 | Sessions dialog |
| 20 | Record performance & USB export | 12 | 2 | 4 | 6 | `performance_recorder_cubit.dart` |
| 21 | Audio routing | 16 | 15 | 1 | 0 | `audio_routing/*` (#1020); backing missing |
| 22 | Output setup | 6 | 6 | 0 | 0 | `output_setup_tab.dart` |
| 23 | Performance · Tuner | 5 | 0 | 5 | 0 | Tray tuner only |
| 24 | External pedals · Function assignments | 4 | 3 | 1 | 0 | Hold Tuner needs E6-7 |
| 25 | Main views and selected-track display | 10 | 7 | 1 | 2 | Mixer FX edit missing; Backing & click missing |
| 26 | MIDI controls and Learn | 8 | 8 | 0 | 0 | #1047 |
| 27 | MIDI clock and external sync | 6 | 0 | 0 | 6 | – |
| 28 | Audio interface & recovery | 7 | 0 | 5 | 2 | – |
| 29 | Wi-Fi connectivity | 8 | 0 | 7 | 1 | – |
| 30 | Displays & touch calibration | 6 | 0 | 1 | 5 | – |
| 31 | Storage & safe eject | 6 | 0 | 2 | 4 | – |
| 32 | Safe shutdown & restart | 5 | 3 | 1 | 1 | – |
| 33 | Software updates | 6 | 3 | 2 | 1 | – |
| 34 | Session backup & restore | 6 | 0 | 0 | 6 | – |
| PAR | About, controller and MIDI sync | 7 | 2 | 0 | 5 | – |
| 36 | Session recovery | 5 | 0 | 0 | 5 | – |
| 37 | Recording recovery · Multi and Clear All | 5 | 5 | 0 | 0 | slice 2 (#1060) |
| 38 | Recording timing | 4 | 3 | 0 | 1 | first-take tempo missing |
| 40 | Session connection repair | 4 | 0 | 0 | 4 | – |
| 41 | Session control repair | 5 | 0 | 0 | 5 | – |
| 42 | Recover recorded audio | 3 | 0 | 0 | 3 | – |
| 43 | Repair audio connections | 3 | 0 | 0 | 3 | – |
| 44 | Appliance backup | 3 | 0 | 0 | 3 | – |
| 45 | Timing track | 2 | 0 | 0 | 2 | native crown exists, no UI |
| 46 | Try a preset | 1 | 0 | 0 | 1 | – |
| 47 | Long recordings | 3 | 0 | 0 | 3 | – |
| 48 | Recording destinations | 4 | 0 | 0 | 4 | – |
| 49 | Save audio and Bounce | 2 | 0 | 0 | 2 | – |
| 50 | Audible processing behavior | 3 | 3 | 0 | 0 | slice 3, `followOutput` |
| 51 | Timing boundaries | 3 | 0 | 1 | 2 | – |
| 52 | Touch lock and Solo | 3 | 0 | 0 | 3 | – |
| 53 | Expanded MIDI Learn | 4 | 4 | 0 | 0 | `midi_protocol.dart` (NRPN, relative) |
| 54 | Virtual instruments | 8 | 0 | 0 | 8 | – |

The six current `c/ Implementation` notes are:
- OaX2R: Loop settings;
- po4RZ: Pedal setup;
- MV9wz: Custom controls;
- U9K9lZ: routing surfaces;
- whoPA: shared mix recovery;
- B9Qoq4: Tracks and Mixer.

All of them record the gaps listed above: the UART encoder, Audio & tempo, the Custom face, backing routing, CPU telemetry, touch lock, and the Mixer FX edit button. The about 130 `c/<screen>` notes in `02 EARLIER APPLICATION` describe superseded surfaces. They are not conformance targets, except that several shipped surfaces (Device, Wi-Fi, Tuner, Storage and Sessions) still follow them.

---

## C. Dependency tree

```
E0 land stack (E0-1 → E0-2 → E0-3 → E0-4)        [gate for everything below]
│
├── E1 settings owner: E1-1 → E1-2 → E1-3, E1-4            (sequential, small)
├── E2 render debt:   E2-1 → E2-2 ; E2-1 → E2-3, E2-4 ; E2-5, E2-6, E2-7 (parallel)
├── E3 M1 conformance: E3-1, E3-2, E3-3(click), E3-6, E3-7, E3-8 (parallel)
│                      E3-4 Settings tiles → E9-1, E9-4, E9-9 (pages hang off it) → E3-5 retire
├── E6 foot ops (native lane, sequential by shared history/fact numbering):
│     E6-1 Reverse ─┐
│     E6-2 Peel ────┴→ E6-3 Multiply/Divide
│     E4-1 pitch/time core → E6-4 Speed, E6-5 Transpose, E4-2 Audio&tempo, E7-9 Adapt import
│     E5-1 render recipe → E6-6 Bounce (also after E6-2), E7-10 Save audio
│     E6-7 Tuner, E6-10 Custom face (independent)
├── E4 timing: E4-3, E4-4 (parallel); E4-5 after E2-7
├── E5 FX: E5-2, E5-3, E5-4 (parallel); E5-5 after E9-5
├── E9-5 USB storage service ──→ E7-7, E7-11 → E7-12, E7-13, E5-5, E9-7, E7-14
├── E7 Library: E7-1 → E7-2, E7-3, E7-5 → E7-4 (also after E6-1/4/5 resets)
│     E7-8 backing player → E6-8, E3-3(backing), E5-6, E7-7 "Use as backing"
│     E7-19 atomic publication → E7-16 → E7-17, E7-18 ; E7-14 → E7-15
└── E8 MIDI/instruments (independent of E6/E7 until recall):
      E8-1 → E8-2, E8-3, E8-5 ; E8-1 + #1069 → E8-4
      E8-7 → E8-8 → E8-12 → E8-13 ; E8-7 + E8-6 → E8-9 → E8-10 ; E8-11, E8-14
      E8-7 → E7-6 (recall ownership)
```

**Parallel lanes after E0** (independent owners, little file overlap):
1. Native transport ops (E6-1 → E6-2 → E6-3).
2. Pitch/time DSP (E4-1 → E6-4, E6-5, E4-2).
3. Render (E5-1 → E6-6, E7-10).
4. Library and backing (E7-1…, E7-8).
5. Appliance services (E9-5, E9-4, E9-6, E9-7).
6. MIDI sync (E8-1…).
7. Instruments (E8-7…).
8. App-only conformance (E3, E1, E5-2/3).

**Sequential constraints:**
- Reverse, Peel and Multiply/Divide share fact codes 324–326, the Session schema and `le_request_admit`, so their Part 1s land one at a time.
- Everything USB waits for E9-5.
- Everything audible in Library waits for E7-19 if it must be crash-consistent.

**Critical path** (the longest chain of L/XL items, mostly native and hardware-verified):

E0 → E9-5 USB storage service (L, HW) → E7-11 direct-USB recording (L, HW) → E7-12 long ordered parts (L, HW) → E7-19 atomic publication and guards (XL, HW) → E7-16 recovery (L) → E7-17 connection repair (L) → E7-14 session backup (L) → E7-15 appliance backup and restore (L, HW).

The next-longest chain is instruments: E8-7 (XL) → E8-8 (XL, CPU on HW) → E8-12 (L) → E8-13 (M) → E7-6 recall. It should start as soon as E0 lands, because it shares nothing with the Library lane.

---

## D. Genuine product-direction questions

Only items that neither accepted-behavior.md nor the current pen decides.

1. **The settings tray and Bluetooth.** The accepted design has no settings tray: Settings is ten tiles and Tuner is a performance function. It also has no Bluetooth screen; Network is Wi-Fi only. The app ships both:
   - the tray (rail, brightness capsule, tray tuner);
   - a Bluetooth page.

   Should both be retired when the Settings tiles land, or should a quick-access surface (brightness, tuner) and Bluetooth survive somewhere?
2. **The gesture-feedback proposals.** Pen section 10 carries "Pending Hold · proposal" and "FX held contact · proposal" beside the accepted views. Should they be accepted, or dropped?
3. **Legacy mixdown, stems and `.als` export** (#926, #279, `daw_export`). The accepted design has Save selected audio, Record performance and USB export, but no DAW-project export. Should it be retired, or given a home, and where?
4. **Defaults the operation plans flagged.** Confirm these, or override them:
   - **Reverse.** Undo of Clear does not restore direction. Undo and Clear do nothing in Reverse mode. Recall starts at the end.
   - **Peel.** Peel is its own history entry. Undo does nothing in Peel mode. A Peel inside the drain window is refused rather than queued.
   - **Multiply/Divide.** Rec/Play is Double. A sole track's halving re-clocks the rig. A crowned primary with dependents is refused. An odd-length halving shares the middle frame.
5. **Computer-facing USB audio and mass-storage Transfer** (§8 gate). The accepted behavior names it but leaves open whether the product wants it at all. Is it in scope for "everything built", or explicitly out?
