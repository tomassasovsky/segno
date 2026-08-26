# FX mode should transform the stage, not just recolor the pill (#692)

Status: **design options defined, one recommended; pen drawing is the gating
prerequisite.** This answers the owner's bench request: entering FX mode on
the pedal leaves the main view as the tracks grid, and the only cues are a
pill and per-tile overlays.

## Current state (verified 2026-08-25)

`InteractionMode` (`lib/looper/model/interaction_mode.dart`) is
`record | mute | fx`; `fx` is deliberately excluded from boot defaults. When
the mode is `fx` today, the stage changes exactly this much:

- the status-bar mode pill re-labels and re-colors to the accent pair
  (`stage_status_bar.dart:172-179`, `surface_theme.dart:205-209` — FX maps
  to `accent`/`accentSurface`);
- the chrome's mode affordance swaps icon + word
  (`tracks_chrome.dart:263-271`);
- tile taps become chain toggles (mirroring the 1–8 keys), and a bypassed
  chain shows a `_ChainOffPill` overlaid on the meter
  (`track_column.dart:250-305`) — the comment there admits this pill is
  "the ONLY on-screen cue that an FX-mode tap landed", because the meter is
  taken pre-chain and never reacts;
- semantic labels append the chain state (WCAG 1.4.1 handled).

The layout, the meters, and everything else remain the record-mode tracks
grid. In the pen, `STAGE / stage-fx` draws only the pill swap to the blue FX
state — the issue itself says the design call has not been made. #663's
STAGE audit lists no stage-fx transformation either.

Relevant neighbours: chains already summarize into one line
(`chainSummary`, `signal_cards.dart:473` — entries in signal order, `Chain
off · run` when disabled); racks (#535) will add a name per chain; the
pedal's FX-mode target LEDs are #631; per-entry bypass legibility is #601.

## Decision for the owner

**What does the stage become in FX mode?** Three candidate shapes:

- **Option A — transform the tiles in place** (recommended). The grid
  geometry stays exactly where record/mute mode put it — same tile
  positions, same 1–8 key parity, same footswitch muscle memory — but each
  tile re-dresses for the question FX mode asks: the chain's name (rack name
  once #535 lands, `chainSummary` run today) and a big unambiguous on/off
  state replace the transport-first dressing; the stage chrome shifts to the
  accent surface so the whole stage — not a pill — says which mode it is in.
  The meter stays (it is truthful, pre-chain) but recedes.
- **Option B — per-track chain strips.** Replace the grid with horizontal
  strips, one per track, each drawing its chain entries as blocks (the
  Signal cards' vocabulary at stage scale). Richest FX picture; but it
  re-arranges the performer's spatial map mid-performance, breaks tile/key
  correspondence at a glance, and duplicates the Signal domain one tab away.
- **Option C — racks-focused surface.** The stage becomes a rack loader
  (chips per #535). Strongest tie-in, but it turns a *performance* mode into
  an *editing* surface, and it hard-blocks on #535 shipping first.

**Recommendation: Option A.** FX mode is a performance mode — the performer
is standing on a pedal, mid-song; what they need is "which chains are on,
which tile flips which, did my tap land", at stage distance. A answers all
three without moving anything under their feet, works today (chain
summaries exist; rack names slot in when #535 lands), and leaves B's
richness to the Signal domain where it already lives. C conflates
performing with editing and adds a dependency.

## Implementation outline

1. **Pen first (gating):** draw the transformed state on `STAGE / stage-fx`
   in `segno-ui.pen` — accent-surfaced stage chrome, the FX-mode tile
   dressing (chain name/summary line, dominant on/off state, receded
   meter), and a `c/` note recording why the geometry is frozen (muscle
   memory, key parity). This is the design call the issue exists for; build
   does not start until the owner approves the drawn state.
2. `TracksView`/`TrackColumn` branch on `mode == InteractionMode.fx` to
   swap the tile dressing (a widget-level branch, not a new page — the
   grid, keys, and gestures are shared). The `_ChainOffPill` special case
   dissolves into the new dressing.
3. Stage chrome/background follows `modePair(mode)` so the accent surface
   covers the stage, not just the pill.
4. Rack-name hook: render the chain's name from #535 when a rack reference
   exists; fall back to `chainSummary` until then (explicitly not blocked
   on #535).
5. Semantic labels keep the transport word + chain state contract already
   in place.

## Verification plan

- Widget tests: entering FX mode re-dresses tiles (chain summary + state
  visible), leaving restores; tap still emits `LooperTrackChainToggled`;
  1–8 keys unaffected; a11y labels unchanged in shape.
- Golden/screenshot pass for the stage in all three modes (author-machine
  goldens; regen + eyeball).
- Bench check on the console (the request came from the bench): pedal into
  FX mode, confirm the stage visibly transforms at performance distance and
  a chain toggle is legible without looking at the pill.
- `dart analyze`, `bloc lint`, `flutter test` per the verify loop.

## Acceptance criteria

- With the pedal in FX mode, the main view is unmistakably an FX surface at
  a glance — not the record-mode grid with a blue pill.
- Every track tile shows its chain identity and on/off state; a tap's
  effect is visible on the tile itself.
- Tile geometry and key/footswitch mapping are unchanged across modes.
- `segno-ui.pen`'s `STAGE / stage-fx` matches what shipped, with the
  rationale in a `c/` note.

## Non-goals

- Editing chains from the stage (adding/removing/reordering entries) — that
  stays in Signal.
- Rack loading from the stage (Option C territory; revisit after #535).
- Pedal LED behaviour (#631) and per-entry bypass idiom (#601) — adjacent,
  tracked separately.
