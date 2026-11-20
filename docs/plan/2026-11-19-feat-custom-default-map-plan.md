---
title: "Custom controls start with a default map"
type: feat
date: 2026-11-19
issue: 1908
---

# Custom controls start with a default map

<!-- cspell:words Penpot titlebar writeback -->

Tracking: [#1908](https://github.com/tomassasovsky/segno/issues/1908),
`autonomy:plan-gate`. This plan stops for the owner's answers to the four
decisions below. Nothing is built until they are answered.

## Where it stands

- `PedalSetup()` has an empty Custom map
  (`lib/control/binding/pedal_setup.dart`). A fresh install loads it
  (`ControlCubit.load`, `encodedSetup == null ? const PedalSetup() : ...`).
- The one assignment the app makes is `Hold · Tuner` on Custom pedal 2,
  bank A. `ControlCubit._seedTunerDefault` writes it once, guarded by the
  settings flag `pedal.tuner_default_seeded` (#1229, D11), and the app shows
  a notice when it does.
- The catalogue (`lib/control/binding/control_action.dart`) holds eleven
  modes, eleven commands, eleven track operations in three scopes, and the
  track pedals. None of it is on a Custom switch until the player assigns
  it in Settings > Pedals.
- The design draws a full map. Penpot page 10, `02 / Performance / Custom`,
  shows bank A. `docs/design/pedal-ux-study.js` in segno-design starts from
  the same map and adds bank B. No `c/` note says the drawn map is the
  default. The `c/` note on page 10 says an unassigned switch does nothing.

The drawn map:

| Switch | Bank A, Press / Hold | Bank B, Press / Hold |
|---|---|---|
| Rec/Play | Record / Play / Peel | shared |
| Stop | Stop | shared |
| Undo | Undo / Redo | shared |
| Clear | Mute | shared |
| Track 1 | Transpose / Reverse | Reverse / Transpose |
| Track 2 | FX / Tuner | FX / Fade |
| Track 3 | Fade / Peel | Multiply / Divide |
| Track 4 | Mixer / Speed | Peel / Undo |

MODE is Exit and Bank pages the four track switches. Neither can carry an
assignment.

## Two facts that constrain the map

**Transpose and Speed are not built.** They are modes in the design's
catalogue and are not in `InteractionMode` (#1179 holds the pitch and time
core). Three gestures of the drawn map name them: Track 1 A Press, Track 4 A
Hold, Track 1 B Hold.

**A Hold delays the Press.** In Custom, a switch with only a Press acts on
contact. A switch with a Press and a Hold fires the Press on release
(`ControlCubit._armCustom`). The drawn `Record / Play` + `Hold · Peel` would
start and end every take one tap late. On the Tracks plate, Record / Play
acts on contact and its hold is an addition; Custom has no such rule.

## Decisions for the owner

### D1. The default map

Recommended: the drawn map, with the unbuilt actions dropped and a gesture
left empty where nothing built belongs there.

| Switch | Bank A, Press / Hold | Bank B, Press / Hold |
|---|---|---|
| Rec/Play | Record / Play | shared |
| Stop | Stop | shared |
| Undo | Undo / Redo | shared |
| Clear | Mute / Clear all tracks | shared |
| Track 1 | Reverse | Tap tempo |
| Track 2 | FX / Tuner | FX / Fade |
| Track 3 | Fade / Peel | Multiply / Divide |
| Track 4 | Mixer / Record performance | Peel / Undo |

Departures from the drawn map, each one the owner can refuse:

- Track 1 A: `Reverse` on the Press, since `Transpose` is not built. When
  Transpose ships, the default returns to `Transpose / Reverse`.
- Track 4 A Hold: `Record performance` in place of `Speed`. On the Tracks,
  Mute and FX plates it is a Hold on Bank; in Custom, Bank only pages, so
  an assignment is the one way to it from there.
- Track 1 B: `Tap tempo` in place of `Reverse / Transpose`. Reverse is
  already on Track 1 A. Tap tempo needs repeated contacts, so it carries no
  Hold.
- Clear Hold: `Clear all tracks`. The hold fill for a clearing Hold (#1534)
  already covers it.
- Rec/Play: no Hold (D2).

The alternative is the drawn map with only the unbuilt actions removed:
Track 1 A `Reverse`, Track 4 A `Mixer`, Track 1 B `Reverse`, Clear `Mute`.
It leaves Tap tempo, Record performance and Clear all tracks unassigned.

Every action in the recommended map is in the catalogue today: the modes
`mute`, `fx`, `tuner`, `fade`, `peel`, `mixer`, `reverse`, `multiply`,
`divide`, and the commands `record-play`, `stop`, `undo`, `redo`,
`clear-all`, `tap-tempo`, `record-performance`.

### D2. Record / Play and Stop carry no Hold

Recommended: yes. Both keep contact timing. Peel stays reachable on Track 3
A Hold and Track 4 B Press.

The alternative is a new gesture rule: `Record / Play` fires on contact even
when the switch has a Hold. Then holding for Peel would first start a take,
so the Hold would need to undo it. That is a second behaviour to design and
test, and the drawn map does not need it.

### D3. Pedals can put the default map back

An install that already saved a pedal setup keeps its stored map. The app
does not migrate stored data (AGENTS.md, Engineering principles), so without
a control the owner's console never gets the default.

Recommended: the Custom context's `Clear custom assignments` dialog gains a
second action, `Use default assignments`. It replaces the draft's Custom map
with the default; `Restore` puts back the map from before, as it does after
a Clear; nothing reaches the rig until Save. The titlebar row keeps its
buttons. By my estimate from the button widths in
`pedal_setup_page.dart`, the row already holds about 1,400 px of buttons
when `Restore` shows, so a fourth wide button is unlikely to fit at 1920.

The alternative is a separate `Default assignments` button in the titlebar.
It is one tap shorter and needs the row measured first.

### D4. The Tuner seed is removed

Recommended: yes. The default map carries `Hold · Tuner` on Track 2 A. The
seed, its settings flag, the `tunerDefaultSeeded` state field, its notice
and their tests are deleted. An install that removed the seeded Tuner keeps
its stored map, as any stored map is kept.

## Parts

### Part 1: the default map (no new screen)

- `PedalSetup.defaultCustom`: the map as a `static final` unmodifiable
  `Map<PedalBindingKey, ControlGesturePair>`. It cannot be `const`:
  `PedalBindingKey` is `Equatable`, and a const map key needs primitive
  equality.
- `PedalSetup.fresh`: a `static final` setup with the accepted Track
  controls defaults and `defaultCustom`. `const PedalSetup()` stays the
  setup with nothing on Custom, which is what Clear produces and what a
  stored blob without a `custom` key decodes to.
- `ControlCubit.load` uses `PedalSetup.fresh` when no setup is stored. A
  stored setup decodes as today, an empty Custom map included.
- Delete the Tuner seed (D4): `_seedTunerDefault`, the `seedTunerDefault`
  parameter and its `AppRuntime` argument, `ControlState.tunerDefaultSeeded`,
  the listener and notice in `lib/app/view/app.dart`, the notice string, and
  `SettingsRepository.loadTunerDefaultSeeded` / `saveTunerDefaultSeeded`.
- Tests:
  - every action in `defaultCustom` is in `controlActionCatalogue()`;
  - no default pair puts a Hold on `record-play` or `stop`;
  - `fresh` round-trips through `encode` / `decode`;
  - a cubit loaded with no stored setup runs a default assignment (Track 3
    press enters Fade) and lights the assigned switches;
  - a saved cleared setup loads empty.
- Screenshots: the Custom face (`tracks_screenshots_test.dart`) and the
  Custom controls setup (`pedal_setup_screenshots_test.dart`) with the fresh
  map, in English and Spanish. Check that no caption wraps (#1900 lists the
  foot captions that still do).

### Part 2: Use default assignments (D3)

- `PedalSetup.withDefaultCustom()` and a getter that says whether the Custom
  map already equals the default (the action is disabled then).
- The Clear dialog's second action, its English and Spanish strings, and the
  draft handling: the snapshot `Restore` uses is taken before a Clear and
  before a default.
- Widget tests: the action replaces only the Custom map, leaves Track
  controls, LED colours and external pedals as drafted, `Restore` puts the
  earlier map back, Cancel discards, Save applies.
- Screenshot of the dialog.

### Part 3: design writeback and closing the issue

- Penpot page 10, `02 / Performance / Custom`: the face shows the shipped
  default (the Rec/Play Hold caption removed, the Track 1 and Track 4
  captions as decided in D1). A `c/` note records that the drawn map is the
  fresh default, why Rec/Play and Stop carry no Hold, and which slots change
  when Transpose and Speed ship.
- Penpot page 08, `02 / Pedals / Custom controls` and the
  `Clear custom assignments` tile: the dialog with its second action.
- A segno-design PR with the refreshed snapshot, linked to the app PR, and
  `.github/segno-design.sha` moved to it if the `design` job needs the new
  study.
- `docs/PROGRESS.md`: a status entry, and the Active threads row removed in
  the PR that closes the issue.

The Penpot edits need a browser tab with the file open and the MCP plugin
connected.

## Not in this plan

- Session actions by foot. The design's catalogue has `Load previous
  session`, `Load next session`, `Save session` and `New loop`. The app's
  `sessions` group is empty, and New loop by foot is listed under #1229.
  When they exist, the default map can take them in a later change.
- Moving the Custom map from the appliance's settings into the session
  (accepted behaviour §6.9; #1206 covers MIDI and external assignments).
  Until then the default is per appliance, and New loop keeps the map as it
  keeps the rest of the setup.
- Transpose and Speed themselves (#1179).
- External pedal and MIDI defaults.

## Verification

- `flutter test test/control` and the settings repository's tests while
  iterating; the full suites once before pushing.
- `dart analyze`, `bloc lint lib test packages`,
  `dart run tool/check_no_widget_methods.dart`.
- The screenshot suites rendered and compared against the Penpot frames.
- Nothing under `firmware/` or `packages/pedal_repository` changes, so the
  pedal link contract test is not required.
- On the console, after the first build: the foot feel of each default
  assignment, and that the assigned switches' LEDs light in Custom. This
  cannot be proved in CI.
