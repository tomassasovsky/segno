Model: Claude Opus (subagent), in-session

# Review of `claude/backing-1200-p6` (f3343dc04, no PR yet): feat(backing): route the backing track, add the Backing & click dialog and its value targets (#1200 Part 6)

## Scope

**Head and size.** `f3343dc04`, one commit on P5 `851f55374` (rebased onto trunk `890f04936`). 23 files, +1,369 / −16.

**What it adds:**
- **Audio routing 21/04.** The `Backing & click` kind now has two source cards, `Backing track` and `Click`. The click card is selected by default, and each player has its own `Send to` mask.
- **The Mixer `Backing & click` dialog** (`backing_click_dialog.dart`, pen 25 `bZDIR`), opened from a `stage-aux` button that appears beside Reset mixer in the Mixer view only.
- **`BackingMixCubit`.**
- **Value targets.** `BackingLevelTarget` (on the Mixer gain axis) and `BackingPanTarget` / `ClickPanTarget` (`OwnedPanTarget`). Each has a canonical key, parse, readout, label and catalogue placement, and `OwnedValuePort` wires each one: origin, controller write with release, ordinary changes and supersession. `controlAvailability` uses them.
- **l10n** in English and Spanish.

**Reviewed against:**
- the plan at `e4badf877`: section 2 deviations, Part 6 and its build record;
- the pen `segno-ui.pen`, group `01 CURRENT UX`, read through the pencil MCP and not saved:
  - 25 `bZDIR`: `PsnXb` is the dialog, `IwBG4` / `p3a9cF` the top-bar actions;
  - 21/04 `Z3tJMK`: `w1xOoW` holds the source cards `eqHve` and `EkLy9`;
- AGENTS.md;
- the owner rules.

## Runs

**Dart, on `f3343dc04`:**

| Suite | Result |
|---|---|
| App suite | 3,517 passed, 56 skipped, 0 failed |
| `backing_repository` | 41 passed |
| `session_repository` | 250 passed |
| `segno_engine` | 409 passed |
| `settings_repository` | 204 passed |
| `looper_repository` | 814 passed |
| `dart analyze --fatal-infos lib test packages` | clean |
| `bloc lint lib test packages` | 0 issues |

**Native, on `f3343dc04`:**
- plain: ALL PASSED;
- ASan: ALL PASSED;
- TSAN races: ALL PASSED. The handoff stress test ran 7,725-7,992 handoffs with no report;
- the in-repo decoder fuzz: 3,000 inputs, 0 violations.

**My own mutations,** one at a time, against the relevant tests:

| Mutation | Result |
|---|---|
| `backingPan` parsing as the level target | Caught |
| The dialog's click pan writing the backing pan | Caught |
| 21/04 defaulting to the backing card | Caught |
| Availability ignoring the click-pan owner's readiness | Caught |
| The pan target dropped from the backing lifetime's supersession list | **Survived** (L3) |

**Merge.** `git merge-tree` against the current trunk `787d51db6` conflicts (see the reply).

## Verified correct (traced)

### Pen 21/04

- The two cards are 264 × 64, 16 apart: the pen has `eqHve` at x 0 and `EkLy9` at x 280.
- The selected card at load is **Click**. In the pen, `EkLy9` is the filled and stroked card and `eqHve` is outlined only.
- The labels are `Backing track` and `Click`.
- `_mask` and `_send` route the backing through `BackingMixCubit.setOutput` (the `BackingMixFamily` owner) and the click through `TempoCubit`, as before.
- The test "each source kind carries its own destinations" covers both.

### Pen 25 `bZDIR`

- **Top bar.** The `stage-aux` button is 173 × 54, radius 8 and raised (`p3a9cF`), placed first and then Reset mixer, Bank, View and Settings, as in `IwBG4`. It appears in the Mixer view only (`tracks_view_test`).
- **Dialog frame.** It is 1,260 wide with radius 12 (`PsnXb`) and a 41 px pad.
- **Rows.** There are two `stage-aux-channel` rows, each 147 tall and 24 apart. In each:
  - the label column is 280 wide; the name is 28 px bold and the subtitle 21 px;
  - the controls start at 320 and are each 409 wide, 40 apart;
  - the Volume and Pan labels and their readouts sit above the sliders.
- **Done** is accent-toned, 110 × 64, at the right.
- **Click row.** The subtitle is the Hear click mode (`clickModeReadout`; the pen shows "First recording").

### `BackingMixCubit`

- It borrows the two owners and emits their **live** values (a held controller value included) and their readiness.
- Every method returns `void`, as Bloc lint requires.
- Its inputs are clamped before they reach the owners, whose `_edit` would otherwise throw a `RangeError`.
- Closing it cancels its subscriptions and never closes the owners.

### Dialog behaviour

- A drag keeps a draft and commits once on release.
- Volume commits through `mixerGainAt`, so unity sits at the Mixer fader's 0 dB travel.
- A double tap restores unity or centre, and Cancel drops the draft.
- Each slider is disabled until its owner is ready. The click's volume follows `TempoCubit.clickReady` and its pan follows `clickPanReady`, separately.

### Value targets

- Canonical keys are `{"ctl":"backingLevel"|"backingPan"|"clickPan"}`. Parsing is strict (`raw.length == 1`).
- Level uses the Mixer axis and its top sits at unity travel (`mappingTop`). Pan is 0..1 for −1..1.
- `OwnedValuePort` gives each target the owner's lifetime and a per-field revision. Writes go through `updateController` / `setController` with a release.
- Ordinary changes map `BackingMixField.level`/`pan` to the right target and ignore `output`/`end`.
- With no backing owners (a host without them), all three targets stay unresolved.
- The catalogue places the backing targets under a `Backing` destination, ordered just before Click, and the click pan beside click volume.

## Findings

### Medium

**M1. Four pen departures are recorded only in the plan, and section 2 contradicts one of them.**
- **What the build record (plan `:1446-1452`) declares:**
  1. The Backing subtitle reads "Nothing loaded" with no file. The pen's `hlUwF` says "Prepared audio".
  2. Unity on the Volume bar is at 91 % of travel. The pen draws a full bar.
  3. The `LoopSlider` is 56 px. The pen's track is 64.
  4. The top-bar gap before Reset mixer is 24 px. The pen has 14 between every action in `IwBG4`.
- **The contradiction:** section 2's deviation 1 still says the subtitle is "`Prepared audio` otherwise".
- **The rule:** a shipped departure is written back into the pen, as geometry plus a `c/` note, never left only in the plan or the code. Section 2 says the build does this. None of the four is in the pen: `bZDIR` still draws "Prepared audio", a full Volume bar, a 64 px track and the 14 px gap. 21/04 has no note either.
- **Fix:**
  - Before P6 merges, write the four into `bZDIR`, each as a `c/` note with the new geometry.
  - Make section 2's deviation 1 say "Nothing loaded", or change the code to "Prepared audio". "Nothing loaded" is the more honest text when nothing is loaded; it is a taste call, but the plan and the pen must agree.

### Low

**L1. The dialog is 544 px tall; the pen's is 549.**
- **Where:** the title is a bare 32 px `AppText`. The pen's `h2` (`va6Jk`) is a 37 px box, and the first channel starts at y 102, not 97.
- **Missing test:** no test pins the panel's geometry. The Part 6 criterion says "21/04 and 25 render to their pen geometry", and only one slider rectangle is checked.
- **Fix:** give the title a 37 px box, and add one geometry assertion for the panel (1,260 × 549) and the row origins (102, 273, 444).

**L2. Structural nits.**
- `_BackingClickButton` was inserted between `_ResetMixerButton`'s doc comment and its class. Reset mixer's "Only in the Mixer view…" paragraph now heads the new button's doc, and `_ResetMixerButton` has none (`stage_top_bar.dart:161-167`).
- `_AuxChannelState._control` is a widget-building method. The repo's VGV standard is to extract widget classes, not `_build` helpers.
- `controlAvailability` probes for `BackingMixCubit` with `try … on ProviderNotFoundException`. That works, but an optional read (`context.read<BackingMixCubit?>` through a nullable provider, or passing it in) states the intent without using an exception for control flow.
- The new ARB keys were inserted between `routingSourceClick` and its `@routingSourceClick` metadata.

**L3. One supersession is untested.** Removing `BackingPanTarget` from the targets superseded when the backing mix owner's lifetime moves (`owned_value_port.dart:484-487`) passes every test. A MIDI controller held on backing pan through an Open or an engine restart would then keep its pickup state. Add a pan case beside the level one in `owned_value_port_backing_test.dart`.

**L4. The routing tab offers backing destinations before the mix owner is ready.** 21/04 draws the backing's `Send to` checks from `BackingMixCubit.state.mix.outputMask` whether or not `mixReady` is set. A tap before the owner loads, or while it needs recovery, goes to `BackingSettings.setOutput`, whose outcome is dropped (`unawaited`). The tap appears to do nothing. Disable the checks while `!mixReady`, as the dialog already does for its sliders.

## Notes

- **Still owed on the console** (Part 6 [HARDWARE]): Monitor-only routing on outputs 3-4, hard-left pan, and Output FX on Main processing the backing.
- **Goldens.** `tracks_mixer_window.png` and the compact-window golden were regenerated for the new button and ran here. In the 800 px window the button narrows the session name to its first letter, which the build record declares.

Verdict: Request changes (M1: the pen write-back and the plan's subtitle contradiction).
