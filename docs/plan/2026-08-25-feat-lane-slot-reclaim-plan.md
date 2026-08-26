# A track gives a lane slot back — without eating a restorable take (#595)

Status: **the unsafe version is proven unsafe (built, reviewed, reverted in
#594); this plan defines the safe one.** The issue's own analysis of why the
UI-level trim loses audio checks out against today's code, line for line — so
this plan does not re-litigate it. It defines the two pieces the issue says
are actually needed, argues where each lives, and asks the owner to ratify the
trim shape.

## Current state (verified against master, 2026-08-25)

- Lane count only grows. `lib/looper/view/tracks/track_routing_dialog.dart`
  caps at `kMaxLanes` (lines 119–125, 308–312); un-routing frees the lane **in
  place** (deliberate — compacting would move a recorded take onto another
  source). A track routed and un-routed a few times sits at the cap with
  nothing left to give.
- **Hazard 1 confirmed** — `Lane.lengthFrames` is not "this lane holds
  audio": `packages/segno_engine/src/core/engine_process.c:4589` says it
  outright ("write head publishes the same growing length onto every active
  lane"), so `Lane.hasContent`
  (`packages/looper_repository/lib/src/models/lane.dart:65`) is a per-track
  fact wearing a per-lane name. And a cleared take stays restorable while
  every length reads zero: `a_clear_restore`
  (`engine_commands.c:66`) and `a_redo_depth` (`:247`) are live, per-track
  atomics surfaced in the snapshot (`engine_snapshot.c:40-41`). Re-growing
  the count runs `le_lane_reset` on the re-activated lanes
  (`le_engine_set_lane_count`, `engine_commands.c:2007`, reset at `:2035`) —
  a `memset` over audio the user could still have undone back.
- **Hazard 2 confirmed** — shrink desyncs the caches:
  `LooperRepository.setLaneCount` writes only `_laneCount`; the per-lane maps
  `_laneOutput` / `_laneVolume` / `_laneMute` / `_laneEffects` /
  `_laneChainEnabled`
  (`packages/looper_repository/lib/src/looper_repository.dart:253-268`)
  survive a shrink untouched and the start-time re-apply (`:806-841`)
  faithfully replays them — onto lanes the engine just reset to defaults.
- The per-lane Remove row this could have hung on is gone with
  `signal_panes.dart` (#533); the Tracks routing dialog is per-INPUT, so
  there is no lane row to put an affordance on. The issue's conclusion stands:
  the natural shape is an automatic trim, once it can be made safe.

## Decisions for the owner

**D1 — where "holds nothing recoverable" is computed.** Options:

- **(a) The engine publishes a per-lane recoverable flag.** A lane is
  recoverable iff it captured audio in the live take, the restore shadow
  (`clear_restore`), or any layer the redo stack can bring back. The engine
  is the only party that actually knows all three — it owns the undo shadow
  and the redo stack — and it already publishes per-track versions of exactly
  these facts.
- **(b) App-side bookkeeping** — the repository remembers which lanes
  recorded. Rejected: it mirrors engine state it cannot see (session load,
  drain-walk retires, redo pushes), and every mirror of engine truth this
  repo has tried eventually drifted. The issue itself asks for "a real
  per-lane signal **from the engine**".

Recommend **(a)**: a per-lane atomic (`a_recoverable` or equivalent), set on
the lane's first real write in a take, carried through clear-with-restore and
the redo stack, cleared only when nothing on that lane can come back (restore
consumed/expired AND redo emptied AND take cleared). Surfaced through the
snapshot into a real `Lane.recoverable` field, retiring `hasContent`'s
misleading role in this decision.

**D2 — the trim shape.** Options:

- **(a) Automatic trailing trim**: after an un-route, shrink the count past
  the longest trailing run of lanes that are both un-routed and
  non-recoverable. Holes in the middle stay (the in-place rule is untouched).
  No new UI; the routing dialog simply finds a free slot again.
- **(b) An explicit per-lane Remove** — needs a per-lane surface that no
  longer exists and that #533 deliberately deleted; resurrecting it for this
  is IA regression.

Recommend **(a)** — it is the issue's own conclusion, and with D1 the gate is
finally the right predicate. Nothing needs drawing in `segno-ui.pen`: the trim
has no surface of its own, and the routing dialog's drawn states already cover
"slot available". (Pencil was unreachable this session; if the owner wants
the freed-slot moment visualized, that is a new call — say so on the issue.)

**D3 — cache hygiene on shrink (not really open, but stated for the record):**
`setLaneCount` to a smaller count must evict every `(channel, lane)` cache
entry for the dropped lanes, so a later re-grow meets engine defaults with
repository defaults instead of replaying a ghost chain. The engine side needs
the mirror guarantee: shrink must not leave lane state that a grow resurrects
inconsistently — today grow resets the re-activated lanes (`:2035`), which
becomes *correct* once the trim only ever drops non-recoverable lanes.

## Implementation outline

1. **Engine** (`packages/segno_engine/src/core/`): per-lane recoverable
   atomic — set in the record/overdub write path on first real frames into
   the lane; preserved by `le_engine_clear`'s restore arm; cleared when the
   restore point is dropped and the redo stack empties for layers touching
   that lane; reset by `le_lane_reset`. Snapshot: per-lane field next to
   `a_len` (`engine_snapshot.c:148,308` already walk lanes).
2. **FFI + models**: regen bindings (then `dart format` — ffigen drifts);
   `Lane` gains `recoverable`; the projection in `looper_repository` fills
   it.
3. **Repository**: `setLaneCount` evicts dropped-lane caches (D3); a new
   internal trim — on un-route (`setLaneInput` to none, wherever the dialog's
   un-route lands), compute the trailing free run from lane state
   (`input == none && !recoverable`) and shrink. The re-apply on start
   (`:806`) then never replays evicted lanes by construction.
4. **UI**: nothing new. `track_routing_dialog.dart`'s cap check now passes
   when slots were reclaimed. One notice worth adding: none — silence is the
   feature.

## Verification plan

- **Native tests** (`bash packages/segno_engine/src/test/run_native_tests.sh`):
  the flag's full lifecycle — record sets it on exactly the writing lanes;
  clear keeps it while `clear_restore` holds; undo-to-empty keeps it while
  redo can return; emptying the redo stack drops it; `le_lane_reset` clears
  it; session save/load round-trips it. Plus the #594 regression pinned at
  engine level: set_lane_count shrink-then-grow over a recoverable lane must
  be impossible via the trim predicate.
- **Repository tests**: shrink evicts caches (extend the `:3598` "remembers,
  defers, re-applies" suite with the shrink case); trim fires only on
  trailing non-recoverable free lanes; holes never compact.
- **Widget test**: route → un-route → the routing dialog offers the slot
  again; route → record → un-route → it does not.
- `dart analyze`, `bloc lint`, full Flutter suite.

## Acceptance criteria

- A track routed and un-routed repeatedly no longer strands at `kMaxLanes`.
- No sequence of route / record / clear / undo / redo / un-route / re-route
  can lose audio that undo could have restored (the #594 failure, pinned by
  test at the engine).
- Shrink-then-grow leaves repository and engine agreeing on every lane's
  chain, routing, volume, mute — including across a restart.
- No new UI surface.

## Non-goals

- Compacting mid-track holes — moving takes across sources stays forbidden.
- A per-lane Remove affordance or any `signal_panes` resurrection.
- Changing `kMaxLanes` or lane allocation.
- Session-format changes beyond the one snapshot field.
