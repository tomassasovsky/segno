# feat: whole-rig undo-clear-all — the surfacing call (#219, part 4)

**Status:** Definition for plan-gate sign-off · **Date:** 2026-08-25 · **Type:** feature (control + UI; no engine work)

> Tracking: #219 (`epic`, `stage:build`). Parent plan:
> `docs/plan/2026-07-16-feat-undoable-clear-plan.md`. Verified against
> `master` @ `61609b35`.

## What already shipped — do not re-plan it

Parts 1–3 of the epic are **merged**; anyone reading the epic title and
planning "make clear undoable" is planning work that is already on master:

- **Part 1** (#220 / PR #221): tagged history entries — `le_hist_entry` with
  `kind` (`LE_HIST_LAYER` / `LE_HIST_CLEAR`), replacing the bare slot-index
  stacks (`engine_private.h:547`).
- **Part 2** (#222 / PR #223): the engine restore point.
  `le_engine_clear_undoable` (`engine_commands.c:959`) pushes a
  `LE_HIST_CLEAR` entry on top of the surviving history; undo routes through
  `LE_CMD_RESTORE_CLEAR` (`engine_process.c:1971`); redo re-clears
  (`engine_commands.c:1136`); `track_acquire_slot` never evicts a slot a
  restore point pins (`engine_commands.c:46,106`); master-grid invalidation
  retires a restore point when a new recording redefines the grid.
- **Part 3** (#226): the repository routes the **user** clear to the undoable
  path (`LooperRepository.clear` → `clearUndoable`,
  `looper_repository.dart:1244`) while `applySession` keeps
  `_clearDestructive`; `_clearRestore` snapshots FX chains + lane mutes per
  channel and `undo` restores + re-persists them when
  `AudioEngine.undoRestoresClear` says the undo restores a clear
  (`looper_repository.dart:1323`).

**Per-track clear-undo is live end-to-end.** `ControlCubit.clearAll`
(`control_cubit.dart:880`) fans out per-track `clear`, so after a clear-all
*every* cleared track holds its own restore point — the engine side of part 4
already exists. The snapshot even surfaces it: `Track.clearRestore`
(`models/track.dart:71`) is true exactly when the next undo on that channel
restores a clear, and `canUndo` already includes it.

## What part 4 actually is

One gap, purely control/UI: **undo is strictly channel-addressed.** After a
clear-all, recovering the rig means cursor-hopping — select track 1, undo,
select track 2, undo, … across banks. The pedal's undo footswitch taps
`undo(state.cursor)` (`control_cubit.dart:1024`), keyboard `⌘Z` is per-track,
and no surface offers "put the whole rig back". That is the remainder, and it
is small; what blocks it is a taste call on the affordance, which is why the
epic is `plan-gate` here.

### A premise to kill: "undo-clear-all needs group memory"

It does not. The tempting design — `clearAll` records the set of channels it
cleared, and undo-all replays that set — adds an invalidation problem the
engine already solved. A remembered set goes stale two ways (a new take on a
cleared track overwrites the live slot its restore point names; a take that
redefines the master grid strands every restore point), and both are exactly
the retirements the engine already performs on its own restore points. The
correct definition of undo-clear-all is therefore **derived, not remembered**:

> undo every track whose *current* top-of-history is a clear restore point —
> i.e. every track with `Track.clearRestore == true` in the live snapshot.

That is self-invalidating for free (a retired restore point drops out of the
set), it needs no new state, no new FFI, and no engine change. It also does
the right thing in the partial cases: clear-all → record a new take on track
2 → undo-clear-all restores tracks 1, 3, 4 and leaves the fresh take alone
(the grid case retires everything, so the action correctly becomes
unavailable).

Consequence to accept, stated openly: undo-clear-all is really "undo every
pending clear", so two *separate* per-track clears also restore together.
That is coherent — a pending clear is a pending clear — and vastly simpler
than distinguishing "cleared together" from "cleared apart".

## The decision for the owner: the affordance

Four candidates were parked on the epic. Assessment of each:

1. **Post-clear-all toast with an "Undo clear all" action** (the app already
   has an action-capable toast system, `lib/app/app_toasts.dart` /
   toastification). Discoverable at exactly the moment of the mistake, zero
   permanent chrome, and it matches the mental model — a mis-stomped CLEAR is
   noticed within seconds. Cost: transient (dismissed toast = back to
   cursor-hopping unless paired with option 2).
2. **Keyboard shortcut.** `⌘Z`/`⌘⇧Z` are taken (per-track undo/redo,
   `shortcuts_help_sheet.dart:93`). `⌘⇧C` mirrors `C` = clear-all and is
   free. Cheap, but undiscoverable alone.
3. **Pedal: make the undo footswitch rig-aware after a clear-all.** Rejected
   as a *default*: the tap already means "undo on the cursor's track", and a
   context-dependent meaning for the one recovery control on the plate is
   exactly the kind of modal surprise the pedal design has avoided (compare
   the FX-mode undo inertness note at `control_cubit.dart:977`, which exists
   for the same reason). A pedal affordance can be revisited when protocol v4
   (#763) reshapes the plate; nothing here forecloses it.
4. **Dedicated persistent button.** Rejected: permanent chrome for an action
   that is meaningful only in the seconds after a clear-all.

**Recommendation: 1 + 2 together.** One `ControlCubit.undoClearAll()` behind
both; toast for discoverability, shortcut for permanence. The toast fires
from the tracks view in response to the clear-all completing (whichever
surface triggered it — pedal, `C`, or the chrome button all land in
`ControlCubit.clearAll`), and the shortcut stays live for as long as any
track's `clearRestore` is set, not just while the toast shows.

## Implementation outline (single PR once the affordance is picked)

- **Control:** `ControlCubit.undoClearAll()` — iterate `_tracks`, call
  `_looper.undo(channel:)` for each with `clearRestore == true`. The
  repository's existing per-channel restore (`_restoreClearedTake`) handles
  FX + mutes + re-persist per track; no repository change. Emit nothing
  mode-related — unlike `clearAll` it does not re-home the overlay.
- **UI:** toast (`AppToastId` entry + action wiring in the tracks view) and
  the `⌘⇧C` handler in `tracks_commands.dart` + a row in
  `shortcuts_help_sheet.dart`; the shortcut no-ops (and the toast never
  shows) when no track has `clearRestore`.
- **Docs:** `docs/PROGRESS.md:627` still says "clear removes a track's
  content **and its undo history**" — stale since #223/#226 for the user
  clear; fix it in this PR (the parent plan's status comment already flags
  it).
- **Autonomy:** `merge-gate` per the parent plan's part-4 row (taste on the
  surfaced result), even though the mechanics are `auto`-grade.

## Verification plan

- Cubit tests (`test/control/`): clear-all → `undoClearAll` restores every
  cleared track (state, via a fake looper asserting per-channel undo calls);
  clear-all → new recording on one channel → `undoClearAll` skips it;
  no-op when nothing is pending; invariants suites stay green.
- Widget tests: toast appears after clear-all with content, its action calls
  `undoClearAll`, `⌘⇧C` routes, both inert with nothing pending.
- Real app: record on 2 tracks + FX + a mute → clear-all (pedal) → toast →
  whole rig back, chains + mutes intact, layers still peelable.

## Acceptance criteria

- After a clear-all, one action restores every track that still holds a
  clear restore point — takes, layers, FX chains, mutes — with no
  cursor-hopping.
- The action is derived from live `Track.clearRestore` state: it never
  resurrects a track the engine has retired, and it disappears when nothing
  is pending.
- `applySession` clears remain non-undoable; per-track undo semantics are
  unchanged.
- `docs/PROGRESS.md` no longer claims clear wipes undo history.

## Non-goals

- No engine or FFI changes (parts 1–3 delivered the whole engine surface).
- No group/batched history model; no "redo clear-all" beyond what per-track
  redo already gives.
- No pedal-plate changes — explicitly deferred to the protocol-v4 work
  (#763).
