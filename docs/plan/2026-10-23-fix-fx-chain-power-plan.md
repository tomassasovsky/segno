# Effects power on screen: show an off chain and turn it on where its effects are

<!-- cspell:ignore stsxl iixR7 NbMML desaturated -->

Tracking: #1452, `autonomy:plan-gate`. The owner approves the direction by
merging this plan.
Status: plan.
Base: `origin/claude/segno-integration` at `708fa7edc`. Every `file:line` below
is on that head.

Scope: items 1, 2 and 4 of #1452. Item 3 (an added factory rack keeps the
preset's pedal states) was decided by the owner and is built in PR #1453.

Design source: the 107 MB main-checkout `segno-ui.pen`, group `01 CURRENT UX`,
read through the pencil MCP (not saved). Sections used: `01  Effects ·
destinations` (`X1LTP`), `02  Effects · chains & controls` (`CnUFF`) and
`04  FX activation & pedal banks` (`LXtIM`). The retired Signal design is in
group `02   EARLIER APPLICATION` of the same file. Written rationale for the
current FX UX: `docs/design/2026-09-06-fx-ux-design.md`.

## 1. What happened (owner report, build .195)

The live inputs sounded dry with racks loaded. Both inputs' monitor chains were
saved off (`monitor_fx.0/1 chainEnabled=false`). The owner read the FX page as
on, and the only way to turn the chains back on was the foot FX mode (Custom
mode > FX > 2nd pedal, a switch bound to an input `FxChainTarget`).

## 2. Current boundary (verified)

### 2.1 Three switches, one of them invisible

An effect is heard only when three switches are all on:

- **Pedal power.** `TrackEffect.enabled`. Drawn on every pedal
  (`fx_pedal_power_<slotId>`, `fx_rack_editor.dart:295`) and in the effect
  editor (`fx_editor_bypass`, `fx_effect_editor.dart:148`).
- **Rack activation.** All of a rack's pedals at once, through
  `FxCubit.setGroupEnabled` (`fx_cubit.dart:462`). Drawn on each rack card
  (`fx_power_<groupId>`, `fx_chain_strip.dart:241`) and in the rack editor
  header (`fx_rack_bypass`, `fx_rack_editor.dart:199`).
- **Chain power.** `chainEnabled` on the destination's chain: an input monitor,
  a take (lane), a track, All tracks or an output. It switches the whole chain
  in or out and leaves the pedal states alone.

Chain power has no on-screen control on the FX page, the rack editor or the
effect editor:

- The FX page reads it (`_DestinationChain`, `fx_page.dart:1263-1288`) and
  passes it only to `FxChainStrip(chainEnabled:)`. The strip gives every card
  `dimmed: !chainEnabled` (`fx_chain_strip.dart:107`), which is the same
  `disabledOpacity` an inactive rack card gets. An off chain therefore looks
  like a row of inactive racks, and nothing on the page says why or offers a
  way back.
- Neither editor reads `chainEnabled`.
- `FxCubit` has no chain-power method. The per-stage writers all exist, but
  only pedal bindings and the Track stage's mixer button use them:
  - `MonitorCubit.setChainEnabled` (`monitor_cubit.dart:831-855`): no caller
    in `lib`.
  - `LooperLaneChainEnabledToggled` (`looper_bloc.dart:313`),
    `LooperTrackChainEnabledToggled` (`:525`),
    `LooperAllTracksChainEnabledToggled` (`:620`) and
    `LooperOutputChainEnabledToggled` (`:662`): no caller in `lib`.
  - `LooperTrackChainToggled` (`:537`): used by the mixer's `mixer_fx_<ch>`
    button (`mixer_column.dart:631-637`) and the Tracks number keys
    (`tracks_commands.dart:331`). These are the only on-screen chain toggles,
    and they cover the Track stage only.
  - Pedal bindings write through the repository directly
    (`fx_binding_resolver.dart:98,125-141`).
- Every writer above reports the screen write to
  `FxChainPersistence.ordinaryChain` (`fx_chain_persistence.dart:640`). That
  call makes the on-screen write replace a held pedal binding's substitution
  for the same target (`ordinaryWrite`, `:666-671`), and it tells the
  controller ledger (`control_cubit.dart:245`), so the pedal LED follows.

### 2.2 The strings for this were orphaned

The ARB still has the chain-power wording, but no Dart outside
`lib/l10n/gen` uses it: `fxChainPowerOnTooltip`/`fxChainPowerOffTooltip`
(`app_en.arb:660-661`), `fxChainOff{Input,Loop,Track,Master}Consequence`
(`:687-690`), `fxChainOffHere` (`:2244`), `signalChainOn`/`signalChainOff`
(`:643`/`:633`), `a11yFxChainOn`/`a11yFxChainOff` (`:664-665`),
`signalPanelChainInputExplain` (`:2380`) and `signalPanelChainExplain`
(`:2384`).

Their last users were removed when the Signal surface was retired:

- `289b61263` "refactor(console): the old Signal surface goes (#594)" removed
  the header power button of `fx_dock.dart`.
- `4219c3fbb` "refactor(console): the Signal tray domain retires" removed
  three things:
  - `FxScope.setChainEnabled`, the per-stage dispatch.
  - `signal_detail_panel.dart`'s `_ChainCaption`: the "Chain on/off" pill plus
    a warning consequence line. Its comment said that without it, a chain
    switched off by a pedal could be seen to be off and never turned back on.
  - `signal_fx_editor.dart`'s `fxChainOffHere` line.

The FX page that replaced Signal (`01 CURRENT UX`, built under #442/#535) did
not carry the control over. This regression is what #1452 reports.

### 2.3 What the pen says

- **Earlier design.** `SIGNAL / signal-detail`, note `c/signal-detail`
  (`H4NXZs`), required the chain caption to carry the chain's own power
  ("Chain on" / "Chain off"), with the consequence sentence in warning colour
  beside it while off. The reason it gives: without the pill, a chain switched
  off by a pedal could never be switched back on. `c/signal-loop` (`qRbCe`)
  showed an off chain on its card as "Chain off · <run>".
- **Current design.** `01  Effects · destinations` (12 screens) and `02  Effects
  · chains & controls` (6 screens) draw only rack activation (`rack-power` on
  every card) and pedal power (`Bypass <effect>` on every pedal, `Bypass rack`
  in the editor's `chain-actions`). Neither draws chain power, an off chain, or
  a consequence line.
  - The Live inputs screen (`FX UX 2026 / 03 Live inputs`, `SC3Q1`) has a
    context row (`sound-context`, `NbMML`): `Hear live` Off/Auto/On (`stsxl`)
    on the left, Reorder and Add effects on the right.
  - The pedal editor (`FX UX 2026 / Connected pedal editor`, `o0RK7c`) has
    this header row (`chain-actions`, `GEW2L`): activation (`A3 · HELD`),
    `Bypass rack`, `Rack options`, `Save preset`, `Add effect`.
  - The single-effect editor (`WD0tY`) has the same row (`iixR7`).
- `docs/design/2026-09-06-fx-ux-design.md:226-235` says the dim, desaturated
  card means an *inactive rack*, and that activation states are "not an
  assertion that sound reaches an output". The current design has no state at
  all for "every rack here is cut off upstream of the output".

So this plan restores a requirement the pen already recorded. It moves the
control to the current FX surfaces, so the current pen screens need a
write-back (section 5).

## 3. Direction

1. **One control, the same everywhere.** A segmented **Effects Off | On**
   control, built on the `Hear live` row's own segmented style (`_HearLive`,
   `fx_page.dart:1116`), goes in three places:
   - the FX page's context row,
   - the rack editor's header,
   - the effect editor's header.

   The selected segment says the state in words, so it never depends on tint
   alone. The pen's boolean rule in `c/signal-detail` says a boolean inside a
   row of segmented controls stays segmented, and the FX page row already holds
   one.
2. **An off chain gets its own state.** While the chain is off:
   - Every rack card (or every pedal column, in the editors) dims under the
     existing `disabledOpacity`.
   - One persistent notice band in warning colour sits directly above the
     racks. It names the consequence for this stage and carries a **Turn
     effects on** button. The band is the only notice for this cause: no toast
     goes with it (the popup-severity rule from #860).
   - The rack and pedal switches stay operable and keep their own on/off
     looks, so the player can prepare a sound while the chain is off. The band
     says why none of it is heard yet.
3. **Off is visible before the player selects the source.** Each source card
   in the strip (`fx_input_card_<i>`, `fx_track_card_<i>`, `fx_all_tracks`,
   `fx_output_card_<i>`) adds "Effects off" in warning colour to its ordinal
   line while that source's chain is off. Input 2 being off is then visible
   while Input 1 is selected.
4. **The words.** The current UX never uses "chain": the page is "Effects", the
   cards are racks, the switches are pedals. The control, band and card line
   say "Effects". The orphaned strings are reworded or deleted (section 4,
   Strings).

**Reachability (item 2).** The player noticed the silence on the FX page while
looking at the input's racks. With this change, the chain turns on from that
page, from the rack editor and from the effect editor: wherever an input's,
take's, track's, All tracks' or output's effects are shown. The mixer's
Track-stage button stays as it is. The foot binding keeps working, and the
screen and the pedal agree through `ordinaryChain`.

## 4. The change (one PR, about 350 production lines)

### Cubit

- Add `FxCubit.setChainEnabled(FxAddress address, {required bool enabled})`,
  returning `FxEditResult` like `setEffectEnabled` (`fx_cubit.dart:414-458`)
  and with the same shape:
  - Call the stage's repository writer: `setMonitorChainEnabled`,
    `setLaneChainEnabled`, `setTrackChainEnabled`, `setAllTracksChainEnabled`
    or `setOutputChainEnabled`. These are the same writers
    `FxBindingResolver` uses.
  - On success, call `_persistence.ordinaryChain(address, enabled:)` and
    `_persistence.scheduleSave(address, _settings)`.
  - Return `unchanged` when the chain is already in that state and `refused`
    when the write fails.

  `FxCubit` is already the FX page's single writer for every stage. A chain
  write going through it keeps the page off the bloc and off `MonitorCubit`,
  as the pedal and rack writes already are.
- Add `FxCubit.chainEnabled(FxAddress)`, which reads the same repository
  getters. `_DestinationChain`'s per-stage switch (`fx_page.dart:1263-1288`)
  moves into a selector, so that the page, both editors and the source cards
  all read the state from one place.
- Build-time check: the input stage must refresh `MonitorCubit` through
  `monitorChanges` (`monitor_cubit.dart:69`) after `setMonitorChainEnabled`, as
  it already does for a binding's write. If it does not, the repository fires
  `monitorChanges` in that writer. The fix is not a second write path.
- Delete the paths this makes obsolete, along with their tests:
  - `MonitorCubit.setChainEnabled`,
  - the bloc events and handlers `LooperLaneChainEnabledToggled`,
    `LooperTrackChainEnabledToggled`, `LooperAllTracksChainEnabledToggled` and
    `LooperOutputChainEnabledToggled`.

  None has a caller in `lib`. `LooperTrackChainToggled` stays: the mixer and
  the number keys use it.

### Widgets (`lib/looper/view/fx/`)

- New file `fx_chain_power.dart`, with two widgets:
  - `FxChainPower`: the segmented Effects Off | On, with keys
    `fx_chain_power_off` and `fx_chain_power_on`. It takes the address, reads
    `chainEnabled`, writes through `FxCubit.setChainEnabled`, and reports the
    result through the page's existing `_notifyEditResult`.
  - `FxChainOffNotice`: the warning band, key `fx_chain_off_notice`. It holds
    the stage's consequence sentence and a `fx_chain_turn_on` button.
- FX page:
  - `FxChainPower` goes in the context row (`fx_page.dart:1071-1092`), after
    `_HearLive` on an input and after `_PartPicker` on a track. On All tracks
    and outputs it is the row's only control.
  - `FxChainOffNotice` goes above `_DestinationChain`.
  - The source cards gain the "Effects off" line through a new optional
    `status` on `RoutingSourceCard` (`audio_routing_widgets.dart:15`). That is
    the one shared widget; Audio routing passes nothing and does not change.
- Rack editor: `FxChainPower` goes first in the header row
  (`fx_rack_editor.dart:196`), before `fx_rack_bypass`. While off,
  `FxChainOffNotice` sits above the pedal strip and the strip dims under
  `disabledOpacity`. Each pedal keeps its own power look under the dim.
- Effect editor: the same, placed in `_ChainActions`
  (`fx_effect_editor.dart:129`).
- `FxChainStrip` keeps `dimmed: !chainEnabled`. The notice band is what tells
  that dim apart from inactive racks.

### Strings (`app_en.arb` and `app_es.arb`)

- **Add** `fxChainPowerLabel` ("Effects") and `fxChainOffCard` ("Effects off").
- **Reword** the following. Each `@` description records #1452.
  - `fxChainPowerOnTooltip` becomes the band's button: "Turn effects on".
  - `fxChainPowerOffTooltip`: "Turn effects off".
  - `fxChainOffInputConsequence`: "Effects are off for this input: you hear
    it dry." The old string also said "new takes print dry". Its `@`
    description cites `_snapshotMonitorChainsOntoLanes`, which no longer
    exists. The build traces how a take inherits the input chain today and
    adds "and new takes record dry" only if that holds.
  - `fxChainOffLoopConsequence`: "Effects are off for this take: it plays
    dry."
  - `fxChainOffTrackConsequence`: "Effects are off for this track: it plays
    dry."
  - `fxChainOffMasterConsequence` is renamed `fxChainOffAllTracksConsequence`:
    "Effects are off for all tracks: the track mix plays dry."
  - Add `fxChainOffOutputConsequence`: "Effects are off for this output: it
    plays dry."
  - `fxChainOffHere`: "Effects are off here, so nothing you change on this page
    is heard until you turn them on."
- **Delete** the rest of the orphans: `signalChainOn`, `signalChainOff`,
  `a11yFxChainOn`, `a11yFxChainOff`, `signalPanelChainInputExplain` and
  `signalPanelChainExplain`.

## 5. Pen write-back (in the build PR, saved and blob-hash checked)

All in the main-checkout `segno-ui.pen`, group `01 CURRENT UX`:

1. `01  Effects · destinations`:
   - Add the Effects Off | On segmented control to `sound-context` on `03 Live
     inputs` (`SC3Q1`, after `stsxl`). Do the same on the input, track, All
     tracks and output screens that share the row (`03d`, `03e`, `03g`, `03b`,
     `03c`, `03f`, `Output effects`, `Reverb on main output`, `Separate monitor
     output`).
   - Add one new screen, "Live input, effects off", copied from `SC3Q1`. It
     shows the Off segment selected, the warning band with Turn effects on, the
     dimmed rack cards, and "Effects off" on the selected input card and on one
     unselected card.
2. `02  Effects · chains & controls`:
   - Add the control at the start of `chain-actions` on `Connected pedal
     editor` (`GEW2L`) and `Single effect` (`iixR7`).
   - Add one new screen, "Connected pedal editor, effects off", with the band
     and the dimmed pedal strip.
3. Add a `c/` note to `01  Effects · destinations` that records:
   - that effects power is separate from rack activation and pedal power;
   - that an off chain dims everything inside it and is named once by a band
     with its own Turn on;
   - that the card line shows it before selection;
   - that it is reachable from all three FX surfaces;
   - why: #1452, and `c/signal-detail`'s reason carried over from the
     retired Signal design.

The build agent saves the file and verifies the save by comparing blob hashes,
not by `git status`.

## 6. Tests

- `test/looper/cubit/fx_cubit_test.dart`, for each of the five stages:
  - `setChainEnabled` calls that stage's repository writer, then
    `ordinaryChain` and `scheduleSave`;
  - it returns `unchanged` for the current state and `refused` on an
    `EngineResult` failure.
- `test/looper/view/fx/fx_page_test.dart`:
  - With the input 0 monitor chain off: `fx_chain_power_off` is selected,
    `fx_chain_off_notice` shows the input consequence, and the strip is still
    dimmed.
  - Tapping `fx_chain_turn_on` (and, in a second test, `fx_chain_power_on`)
    calls `setMonitorChainEnabled(input: 0, enabled: true)`, and the band goes
    away once `MonitorCubit` publishes the change.
  - With input 1 off and input 0 selected: `fx_input_card_1` shows "Effects
    off" and `fx_input_card_0` does not.
  - The track, All tracks and output variants each show their own consequence
    sentence and call their own writer.
  - With the chain on: no band and no card line.
  - Rack editor and effect editor:
    - with the chain off, the band and the `fx_chain_power` control are in
      the header, and the pedal strip is under `Opacity(disabledOpacity)`;
    - `fx_pedal_power_<slot>` still calls `setEffectEnabled`;
    - turning the chain on from the editor clears the band.
- `test/audio_setup/cubit/monitor_cubit_test.dart` (`:1871`, `:1905`) and
  `test/looper/bloc/looper_bloc_test.dart`: delete the tests of the removed
  writers. Add one test that a repository chain write refreshes
  `MonitorCubit` through `monitorChanges`.
- `test/control/control_cubit_test.dart`: a screen write through
  `FxCubit.setChainEnabled` on a target bound to a pedal updates the pedal's
  lit state (the `ordinaryChain` → `_onOrdinaryFxWrite` path).
- Screenshot goldens (`test/screenshots/fx_screenshots_test.dart`) are
  author-only. The build regenerates them on the author's machine and checks
  them by eye.
- Verify loop: the FX view and cubit tests, plus `test/audio_setup`,
  `test/control` and `test/looper`, run through
  `/Users/Tomas/development/flutter/bin/flutter test`; then `dart analyze` and
  `bloc lint lib test packages`, run from a copy outside the worktree because
  the worktree gitignore makes `bloc lint` see no files.

## 7. Decisions under the owner rules

- **Segmented control, not a toggle button.** It matches `Hear live` in the
  same row and the pen's segmented-boolean rule, and its words state the
  state.
- **"Effects", not "chain".** The current UX never uses "chain".
- **Switches inside an off chain stay live.** Locking them would stop the
  player preparing a sound with the chain off. The band explains why nothing
  is heard yet.
- **One band per cause, no toast** (#860).
- **Remove the dead writers**, rather than keeping a second path beside
  `FxCubit` (AGENTS: no compatibility layers).

## 8. Questions for the owner

1. Should the Stage also show an input whose effects are off, for example a
   cue on the input meter in the readout? The default is no: the Stage has no
   input FX display today, and this plan covers every surface that shows
   effects. Say if you want it, and it becomes a follow-up issue.

## 9. Build record (branch `claude/fx-chain-power-1452`)

- Built as section 4 describes, with these differences:
  - The Off / On labels reuse `toggleOff` / `toggleOn`.
  - The power control in the editors sits at the right end of the title
    row, just before Track Solo (the pen has the rack's pedal-assignment
    chip there, which the app does not draw).
  - `FxCubit.setChainEnabled` reads and writes through the per-stage
    dispatch pedal bindings already used (`chainEnabledAt` /
    `setChainEnabledAt` on `FxBindingResolver`, made public), so there is
    one switch per stage, not two.
  - Switching off a chain with no effects changes nothing. On an input this
    also keeps the phantom-monitor guard that `MonitorCubit.setChainEnabled`
    carried.
  - The editors' titles end before the power control
    (`LoopSettingsFrame.titleRight`) and ellipsize, so a long rack name
    never runs under it.
  - `setAllTracksChainEnabled` and `setAllTracksEffects` now republish the
    projected state, as `setOutputEffects` already did, so the All tracks
    flag reaches the page without waiting for the next poll.
- Strings: the orphans are reused or deleted as section 4 lists. The
  input sentence keeps "new takes record dry", because
  `_inheritableChain` returns nothing for a disabled input chain.
- Pen: the write-back in section 5 was made through the pencil MCP. It
  covers:
  - the Effects Off | On control on the ten `sound-context` rows of
    `01  Effects · destinations`, and in the `chain-actions` title rows of
    `Connected pedal editor` and `Single effect`;
  - `13 / Live input, effects off`;
  - `07 / Connected pedal editor, effects off`;
  - the note `c/ Effects power and new racks (#1452)`.

  They are not on disk: the file's hash is unchanged, because a pencil
  MCP edit is saved only from the Pencil app, which this session could not
  drive. The PR lists them so they can be saved from Pencil or redone.
