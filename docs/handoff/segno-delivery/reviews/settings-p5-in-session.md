Model: Claude Opus (subagent), in-session

# Review of PR #1251: refactor(settings): the tray holds only the tuner; FX pedal assignments move to the FX page (#1199 Part 5)

## Scope

- Branch `claude/settings-1199-p5` at `cd56b89da`, one commit on
  `0d04844b2` (a merge of Parts 3 and 4). Reviewed as
  `0d04844b2..cd56b89da` (100 files, +649 / -4044).
- **Deleted:**
  - the tray's navigation rail, brightness capsule and popover;
  - the Control, Tracks, Audio, Network and System faces, and the enums
    `ControlTab`, `AudioTab` and `SystemTab`;
  - `RecordingAudioTab`, so the Device page has no tabs;
  - `SettingsTrayDestination` and every tray tab field.
- **Moved:** `PedalTrayBody` becomes `FxPedalAssignmentsBody` behind the FX
  page's Pedal assignments button (`segno/fx/pedal-assignments`, crumb
  `EFFECTS / PEDAL ASSIGNMENTS`). The default multiple moves to Length &
  quantize, in the Defaults scope.
- **Tuner:** the tray now holds only the tuner, which arms only while the
  sheet is open.
- Against plan Part 5 (as amended in review round 1), AGENTS.md and the owner
  rules.

## Runs

- Full app suite with `SEGNO_ENGINE_LIB`: `+3316 ~56: All tests passed!`
  (`app_exit=0`).
- `dart analyze --fatal-infos lib test`: no issues. `bloc lint lib test
  packages` from a scratchpad worktree: 0 issues, 838 files.
- Plan symbol check:
  - none of `TrayNavigationRail|TrayRailEntry|BrightnessCapsule|TrayBrightnessPopover|ControlTrayPanel|ControllersTrayBody|TracksTrayPanel|NamesTracksTab|AudioTrayPanel|NetworkTrayPanel|SystemTrayPanel|SettingsTrayDestination|RecordingAudioTab|PedalTrayBody`
    remains in `lib` or `test`;
  - `AudioTab` survives only inside the name `DeviceAudioTab`.
- String sweep (script over `lib`, `test`, `packages`, `integration_test`,
  `apps`):
  - the 30 removed ARB keys have no reader;
  - no key is left without a reader by the deleted files;
  - `app_es` has no key missing from `app_en`.
  - Three keys were added: `loopDefaultMultipleLabel`,
    `fxPedalAssignmentsTitle` and `fxPedalAssignmentsCrumb`.
- Mutations (each reverted):
  - Killed:
    - the tuner never disarms;
    - the tuner is built while the tray is shut;
    - the FX Pedal assignments button does nothing;
    - the default-multiple row does nothing;
    - the row shows in a track scope;
    - the assignments page loses its crumb.
  - Survived: the row stays enabled while a capture locks the page (L1).
- Pen: `06 / 01 Length and quantization` (`rmQ4f`) exported through the
  pencil MCP and compared with `loop_settings_length_defaults.png`. The new
  row sits under Record timing ("Later tracks", Auto / ×1 / ×2 / ×3, 60 high
  instead of the pen's 96); the rest of the page is unchanged.
- `git merge-tree`:
  - with the current trunk `787d51db6`: conflicts in both ARB files and
    `test/looper/view/settings_tray_test.dart`. The trunk side is one
    `GuardRegistry()` argument in a test and two doc-comment edits in
    `settings_tray_state.dart`;
  - with P7 (`1796d67c9`): the same files plus two golden binaries (see
    Notes).

## Verified correct (traced)

- **Every former tray control is still reachable:**
  - FX-mode pedal bindings: FX page > Pedal assignments, with the same body
    and the same `ControlCubit.setGlobalBindings`. Its "Open setup" row is
    gone; the Pedals tile covers it.
  - MIDI controllers: the MIDI tile.
  - Track names: the track column's rename dialog
    (`lib/looper/view/rename_track_dialog.dart`, `track_column.dart`).
  - Device, rate, buffer, inputs and maximum loop length: the Device page.
  - Default multiple: Length & quantize, Defaults scope, offering the same
    choices the old tab and the old page did (Auto, ×1, ×2, ×3), through the
    same `RecordOptionsCubit.setDefaultMultiple`.
  - Wi-Fi: the Network page.
  - Display, Updates, Storage, About and licences: their pages.
  - Brightness: Displays, adjustable by keyboard, encoder and screen reader
    since P1.
- No trunk code added since P5's base calls the deleted tray API.
- **Tuner lifecycle** (`tray_panel.dart:46`, `:67`; `tuner_tray_panel.dart`):
  - the panel is built from the first frame the sheet shows and unbuilt
    when a close finishes sliding;
  - `TunerTrayPanel.active` follows `dragProgress > 0`, so the tuner arms
    on open (including mid-drag) and disarms the moment the tray reaches 0;
  - arming is tracked by `_armed`, so no double arm or disarm;
  - a stage that never opens the tray never builds or arms it.
  - All of this is tested and the mutations are killed.
- **Tray state:** `SettingsTrayCubit` keeps only `dragProgress`, as the plan
  says. The tray no longer creates a `WifiCubit`.
- **Accessibility:** `FxPedalAssignmentsPage` uses `SettingsDestinationPage`
  with an override crumb, so Back and Stage behave like the other
  destinations.

## Findings

### Low

**L1. The default-multiple row stays live while the page is locked by a
capture in its test.** `loop_length_page.dart:361` passes
`enabled: !locked`, but forcing `enabled: true` passes
`test/looper/view/loop_settings`. The code is right; the locked state of
the new row is just not asserted. Fix: add the row to the existing
"locked while recording" case.

**L2. "Later tracks" says less than the old row did.** The removed row
carried the subtitle "Auto rounds up to whole base loops; a fixed multiple
records that many." The new row is a bare label and four chips, and
nothing on the page says what ×2 is a multiple of. Fix: one note line under
the row, as Record timing has, or move the existing ARB subtitle there.

## Notes

- **The branch needs a trunk merge before landing.** Its base predates
  `787d51db6`; the conflicts are small (above).
- **If P7 lands first,** every golden this part adds or regenerates for a
  framed page was drawn with the old frame and must be regenerated, not
  just the two that conflict textually:
  - `fx_pedal_assignments*`, `settings_about*` and `settings_device*`;
  - `settings_displays_waveform_failed`, `settings_network_wifi*` and
    `settings_updates_*`;
  - `loop_settings_length_defaults`.
- **Pen write-back:** the new row departs from pen `06 / 01`. The plan
  already lists it.
- The Device page losing its tabs matches the plan (Part 5 removes
  `AudioTab`).

Verdict: Approve.
