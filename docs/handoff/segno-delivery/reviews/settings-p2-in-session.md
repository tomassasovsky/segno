Model: Claude Opus (subagent), in-session

# Review of PR #1219: feat(settings): Settings as ten illustrated destinations (#1199 Part 2)

## Scope

- Branch `origin/claude/settings-1199-p2` at `86bedb152` (on Part 1,
  `179e72bb3`).
- The Settings home (`lib/settings/view/settings_home_page.dart`,
  `lib/settings/settings_destination.dart`), the ten PNGs under
  `assets/settings/`, the Power button and `requestPowerOff` /
  `currentPowerOffSnapshot`, the entry points (header icon, foot Mixer and
  foot Fade Settings buttons, S, right-click, macOS menu), focus handling,
  and the new `SurfaceTheme.menuArtGround` token.
- Against plan Part 2, pen `05 Loop setup / 01 Settings` (`v7Ekz`) in group
  `01 CURRENT UX`, AGENTS.md and the owner rules.

## Runs

- Full app suite with `SEGNO_ENGINE_LIB` from
  `packages/segno_engine/tool/build_test_lib.sh`, in a scratch worktree under
  the scratchpad: `+3371 ~49: All tests passed!` (`app_exit=0`). The
  settings screenshot goldens ran (fonts present) and passed.
- `dart analyze --fatal-infos lib test`: no issues.
- `bloc lint lib test packages` from the scratch worktree: 0 issues, 858
  files analyzed.
- Assets: all ten `git hash-object assets/settings/<key>.png` equal
  `56410d148:docs/design/settings-art/<key>.png`.
- Pen comparison: `v7Ekz` exported at scale 1 through the pencil MCP (read
  and export only, not saved) and compared pixel by pixel with
  `test/screenshots/goldens/settings_home.png`; node geometry read with
  `Get` (`resolveVariables`).
- Focus probe: a scratch widget test (deleted afterwards) pumped the home at
  1920 x 1080 with `FocusHighlightStrategy.alwaysTraditional`, pressed
  ArrowRight (focus moved to the Loop settings tile, rect
  `(449, 368, 774, 612)`), rendered the tree with `toImage` and counted
  amber pixels around that tile: **0**.
- Merge check with USB P5 (`a3de62da3`): `git merge-tree` reports a content
  conflict in `lib/appliance/power_off/power_off_host.dart`.
- Mutations (each reverted): Device tile opens Network, autofocus off, Power
  a no-op, foot Fade and foot Mixer Settings no-ops, header icon opens Device,
  brightness failure toast silenced: all killed.

## Verified correct (traced)

- Ten tiles in pen order; tile rects `(100, 368, 325, 244)` to
  `(1495, 636, 325, 244)` match the pen (menu at main (100, 120), rows at
  152 and 420, 96 px top bar). Art 128 x 128 at tile (98, 32); name top at
  174. Tile fill `#202735` matches the pen exactly in the golden.
- Every entry point (`stage_top_bar.dart:73`, `foot_mixer_view.dart:125`,
  `foot_fade_view.dart:137`, `tracks_commands`, `tracks_view` secondary tap,
  macOS menu in `app.dart`) calls `openSegnoSettings()`; tests fail if any is
  re-pointed or emptied.
- `requestPowerOff` reads `PowerOffCubit`, `LooperBloc`,
  `PerformanceRecorderCubit` and `SessionCubit`, all provided app-wide
  (`app.dart:489-490`, `:662`, `:696`), so it works from a route above the
  stage. `PowerOffHost` stays mounted under the stage route and shows its
  dialog on the root navigator, above Settings; its `popUntil` keeps
  Settings.
- Power appears only when `isAppliance()` (or the test override); its
  position matches the pen (`mGxF1` at screen (1756, 126), 64 x 64, radius 7).
- Back from a destination returns focus to the tile that opened it (tested,
  and the autofocus mutation is killed).
- `menuArtGround` is defined in both flavours and in `copyWith` / `lerp`.

## Findings

### High

**H1. The encoder focus ring is invisible on every tile.**
`SettingsTile` (`settings_home_page.dart:110-131`) wraps an opaque
`Container` in `FocusableTapTarget`. `FocusableTapTarget` draws its ring as a
`DecoratedBox` border behind its child, 2 px wide, at the child's own size
(`packages/routing_graph/lib/src/widgets/focusable_tap_target.dart:104-110`).
The tile's fill covers it, and the tile's `foregroundDecoration`
(`borderStrong`) is painted on top. The probe above focused a tile with
keyboard highlighting on and found no amber pixel; the pixel at the tile's
left edge stays `#3a3a40`. On the appliance an encoder or arrow-key user
cannot see which of the ten tiles is selected, and Part 2's hardware
criterion ("the encoder ... moves the amber focus across all ten tiles")
fails. The pen draws it as `e7kzxk`: a 3 px inner stroke `#f2bf70`, radius 8,
over the tile.
Fix: paint the ring inside the tile, in front: for example have the tile
listen to focus (a `Focus` / `onFocusChange` or `FocusableActionDetector`
with `onShowFocusHighlight`) and swap its `foregroundDecoration` to a 3 px
amber border while focused. Add a golden or pixel test of a focused tile;
the current golden is taken in touch highlight mode, so it shows no focus at
all.

### Medium

**M1. Merge hazard with USB P5 (#1217) in `power_off_host.dart`.** USB P5
adds `transferInFlight: _maybeRead<StorageRepository>(context)?.transferInFlight ?? false`
to the snapshot inside `_PowerOffHostState._snapshot()`. This PR replaces
that method with the top-level `currentPowerOffSnapshot`
(`power_off_host.dart:20-30`), which both the rear key and the Settings Power
button use. If the conflict is resolved by taking this side, neither press
carries `transferInFlight`, and the power-off gate stops refusing during a
USB copy (the data-loss case USB P5 exists to prevent). Fix for whoever
merges second: move the `transferInFlight` read into
`currentPowerOffSnapshot`, with a top-level `maybeRead`, and add a test that
the Settings Power press with a transfer in flight is refused.

**M2. Tile stroke colour does not match the pen.** The pen strokes each tile
1 px inside with `#556881`; the code uses `borderStrong` (`#3a3a40`,
`settings_home_page.dart:129`). In the golden the tile edge reads `#3a3a40`
where the pen reads `#556881`, a neutral grey line instead of the blue-grey
one, on all ten tiles. The PR already added `menuArtGround` because no token
fit the fill; the stroke is the same case. Fix: add a token (for example
`menuArtLine = #556881`) rather than writing a token mismatch back into the
pen.

### Low

**L1. Focus ring colour and shape differ from the pen even once visible.**
`surface.warning` is `#e0a94a` (`surface_theme.dart:517`); the pen's focus is
`#f2bf70`. The ring is 2 px at radius 10 around the tile; the pen's is 3 px
inside at radius 8.

**L2. Power stroke colour.** `LoopOutlinedButton` strokes with
`borderStrong` (`#3a3a40`); the pen's Power (`mGxF1`) stroke is `#5f5f5f`.
The golden does not show Power at all, because it is taken with
`isAppliance()` false; the screenshot test should pass
`powerAvailable: true`.

**L3. The ten 480 x 480 PNGs are decoded at full size for 128 px tiles.**
About 9 MB of decoded images while Settings is open. `cacheWidth` /
`cacheHeight` at `128 * devicePixelRatio` would cut that by about 14x.

**L4. A tile whose route is already on the stack does nothing.** If Settings
is pushed over an open destination (the macOS menu works over any route),
tapping that destination's tile is a silent no-op because `_pushOnce` sees
the name. Desktop only; note it for the menu entry.

## Pen mismatch list (`v7Ekz` vs `settings_home.png`)

Matches: tile rects, tile fill `#202735`, art size and offset, name top
(glyph top 548 vs pen 549), crumb position, title x, Back / Stage / Power
positions.

Mismatches specific to this PR:
1. Encoder focus not visible (H1).
2. Tile stroke `#3a3a40` vs `#556881` (M2).
3. Focus colour `#e0a94a` vs `#f2bf70`; 2 px outset radius 10 vs 3 px inset
   radius 8 (L1).
4. Power stroke `#3a3a40` vs `#5f5f5f`; Power absent from the golden (L2).
5. Tile name colour `textPrimary` `#f3f4f7` vs `#e7edf6`.

Mismatches from the shared `LoopSettingsFrame` and the app font (present on
every Loop settings page, not introduced here):
6. Font Inter vs Arimo; tile names are wider ("Effects" 101 px vs 92 px,
   "Loop settings" 203 px vs 185 px).
7. Page and top bar background `#0b0b0c` vs `#111215`.
8. Top bar rule `#2a2a2e` vs `#3d3d3d`.
9. Back glyph is an arrow, the pen's is a chevron; Back stroke `#3a3a40` vs
   `#515d6e`.
10. Stage fill `#1e1e21` vs `#202735`; stroke `#3a3a40` vs `#515d6e`.
11. Title "Settings" glyph top 144 vs 142 (2 px low); colour `#f3f4f7` vs
    `#e7edf6`.
12. Crumb colour `#9a9aa2` vs `#b5b5b5`.

## Notes

- The old `SettingsPage` is unreachable from this PR on; the stored
  boot-default mode keeps applying with no control until Part 3 (see the
  plan review, M1). Ship Parts 2 and 3 together.
- The pen write-back list in the build record proposes changing the pen to
  `borderStrong` and `warning`; M2 and L1 suggest matching the pen instead.

Verdict: Request changes (H1; M1 must be carried by whichever of #1219 and
#1217 lands second).

## Delta review (ccb828632)

Scope: `ccb828632` (the fix) on top of `73bbed06f` (merge of P1 at
`9dcddac52`, which carries trunk `097e1ef68`).

Runs:
- Full app suite with `SEGNO_ENGINE_LIB`: `+3508 ~56: All tests passed!`
  (`app_exit=0`). `dart analyze --fatal-infos lib test`: no issues. `bloc lint`
  from a scratchpad worktree: 0 issues, 897 files.
- New `settings_home.png` compared pixel by pixel with the pen export of
  `v7Ekz`: focus ring at x 100-102 and y 368 is `#f2bf70` in both, x 103 is
  tile fill in both; tile stroke `#556881` in both; Power stroke `#5f5f5f` in
  both.
- Scratch merge with USB P5 (`a3de62da3`): `power_off_gate.dart` merges
  cleanly (identical change on both sides); `power_off_host.dart` conflicts,
  and both sides of the conflict carry `transferInFlight`, so either
  resolution keeps the guard. Taking this branch's side is the right one.

### Findings from the first round

- **H1 (invisible focus ring): resolved.** Tiles now use `LoopFocusable`,
  which paints a 3 px `encoderFocus` border with
  `DecorationPosition.foreground` over the tile
  (`loop_settings_widgets.dart:52-63`). The test "the focused tile draws the
  encoder amber inside its edge" reads pixels and fails if the ring is drawn
  behind; the golden now shows the focused first tile.
- **M1 (USB P5 power-off seam): resolved.** `currentPowerOffSnapshot` reads
  `StorageRepository.transferInFlight` (null-safe when no repository is
  provided), `powerOffGate` refuses on it, and the test "Power during a USB
  transfer is refused" covers the Settings button.
- **M2 (tile stroke): resolved** with the new `menuArtLine` token.
- **L1: resolved.** New `encoderFocus` token (`#f2bf70`) replaces `warning`
  on every Loop settings focus stop (`LoopFocusable`, `LoopStepper`,
  `LoopSlider`), 3 px inside.
- **L2: resolved.** `LoopOutlinedButton.borderColor` with `menuPowerLine`;
  the golden shows Power.
- **L3: resolved.** Art decoded at `128 * devicePixelRatio`.
- **L4: not changed** (desktop only; acceptable).

Tokens: `menuArtGround`, `menuArtLine`, `menuPowerLine` and `encoderFocus`
are defined in both flavours, in `copyWith` and `lerp`, and used by the
tiles, Power and the focus stops; `test/theme/app_theme_test.dart` pins them.

### New in this commit

- The foot Reverse Settings button (from Reverse P3, now on the trunk) opens
  Settings instead of the tray, with a test. Good catch.
- Low (shared frame, already Part 7 / #1230): the Power button sits 2 px low
  (stroke at y 128 and 191 against the pen's 126 and 189), the same offset as
  the title row.
- Note: `LoopFocusable` shows its ring whenever it has focus, not only in
  keyboard-highlight mode, so the Effects tile is amber when Settings opens.
  That is what the pen draws.

Verdict: Approve.
