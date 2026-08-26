# The last live output does not go quietly (#569)

Status: **most of this issue shipped while it sat on the board; what's left is
the guard, plus one keying call.** The issue was filed when #533 rendered the
`OUTPUTS` group read-only and "the write path is this issue". The write path
has since landed end to end. This plan re-scopes the issue to what master
actually lacks — the last-live-output intercept the pen draws — and puts the
one real decision (settings keying) in front of the owner.

## Current state (verified against master, 2026-08-25)

Shipped, working, none of it this plan's to build:

- **Write path**: `_OutputRow`'s `ConsoleSwitch`
  (`lib/looper/view/signal/signal_cards.dart:436-445`) fires
  `LooperOutputEnabledToggled` → `LooperBloc:487` →
  `LooperRepository.setOutputEnabled` → engine
  (`packages/looper_repository/lib/src/looper_repository.dart:883`), state in
  `LooperState.outputEnabledMask`
  (`packages/looper_repository/lib/src/models/looper_state.dart:35`).
- **Persistence**: `output_enabled.$output`
  (`packages/settings_repository/lib/src/settings_repository.dart:780`),
  default-on-by-removal (`:893`); boot re-apply in
  `lib/app/audio_bootstrap.dart:387`.
- **The after-the-fact warning**: all-off renders the failure banner
  (`signal_no_outputs_banner`, `signal_cards.dart:394`) — "said once, over
  the group".

Not shipped:

- **The intercept.** `_OutputRow.onChanged` writes unconditionally. Switching
  the last live output off silences the rig with no more ceremony than any
  other row — exactly the "must not reach it without being told" this issue
  kept when it split from #533.
- The pen has the design on master (via #603/#636, owner-confirmed
  2026-08-20): `SIGNAL / master-last-output` — Out 1 already off, the tap on
  Out 2 intercepted by a confirm in **warning amber, not destructive red**
  (nothing is destroyed; "Keep it on" costs nothing). Any other output's
  switch flips silently. **The dialog intercepts the write rather than
  undoing it.** Rationale in `c/master-last-output`.
- The issue's other two direction calls resolved on their own: the
  `InputMonitor.outputMask` relation is settled (none — strictly downstream
  of the sum; the owner's engineering comment and the shipped engine gate
  agree), and "where the flag lives" was answered by the shipped engine
  output-stage gate. What did NOT ship as proposed is the keying — see D1.

Pencil was unreachable this session; build step 0 is re-reading
`SIGNAL / master-last-output` for the dialog's copy, button order, and amber
treatment. Nothing new needs drawing.

## Decisions for the owner

**D1 — settings keying: `output_enabled.$output` (shipped) vs
`output_enabled.$device.$output` (as the issue proposed, the
`latency_offset.$device.$rate.$buffer` precedent).** The shipped key is
global by output index: turn off Out 3/4 because they are this interface's
phones pair, plug in a different interface whose Out 3/4 feed the PA, and the
PA is silently dead — the exact class of surprise per-device keying exists to
prevent, and why `latency_offset` and `input_name` are device-keyed. Options:

- (a) **Re-key per-device**, migrating legacy `output_enabled.$N` keys to the
  current device on first load (the settings repo already has a migration
  posture — `:1099` references this key family's default-on removal).
- (b) **Accept global** — outputs-by-index as a rig-level stance, one less
  migration.

Recommend **(a)**: the flag is a fact about a physical socket, and sockets
belong to devices. The migration is small and one-way; doing it in the same
slice as the guard keeps this issue's close meaning "outputs are done".

**D2 — none.** The guard's shape is pen-settled (amber confirm, intercept not
undo, "Keep it on" primary). If the owner disagrees with the pen, that is a
pen edit first — deviations write back into the `.pen`, per repo rule.

## Implementation outline

1. **Intercept in `_MasterStage` / `_OutputRow`** (`signal_cards.dart`): the
   stage already computes `live` (`:340-345`). Pass the row "is this the last
   live output" (`enabled && live.where((e) => e).length == 1`); on a
   turn-off tap of that row, show the confirm instead of dispatching. Confirm
   → dispatch `LooperOutputEnabledToggled(output, enabled: false)`; Keep it
   on → nothing (the write never happened — intercept, not undo). Use the
   console dialog idiom the Tracks routing dialog established, amber-toned
   per the pen; keys `signal_last_output_dialog`, `signal_last_output_confirm`,
   `signal_last_output_keep`.
2. **Turning any output ON never intercepts**; turning off a non-last output
   never intercepts (pin both in tests — the guard must not become friction).
3. **D1 if ratified**: `_outputEnabledKey` gains the device segment sourced
   the way `latency_offset`'s device id is; `loadOutputEnabled` falls back to
   the legacy key once, migrates, removes it. `audio_bootstrap.dart:387`
   passes the open device's id.
4. The all-off banner stays — the state remains reachable deliberately
   (confirmed tap) or structurally (device swap to fewer outputs), and the
   banner is the standing report; the dialog is the gate.

## Verification plan

- Widget tests on `_MasterStage`: last-live turn-off shows the dialog and
  writes nothing until confirmed; confirm writes exactly one toggle; keep-on
  writes nothing; non-last rows and all turn-ons stay silent; with the mask
  all off, turning one on needs no ceremony.
- Settings tests (if D1-a): device-keyed round-trip, legacy-key migration,
  default-on removal preserved per device.
- Goldens: the dialog over the outputs group; regen + eyeball.
- `dart analyze` + `bloc lint` clean.

## Acceptance criteria

- Silencing the rig via the outputs group is impossible without answering the
  amber confirm; every other switch interaction is unchanged.
- The dialog intercepts (state never flickers off-then-on).
- If D1-a: an output disabled on interface A is not disabled on interface B,
  and existing users' disabled outputs survive the migration.
- Issue body updated to record what shipped vs what this slice added.

## Non-goals

- Any `InputMonitor.outputMask` interaction — settled: strictly downstream.
- Per-route masks, monitor gates, or the Audio face's warnings.
- Renaming outputs or output labels.
- Guarding silence reachable by device topology (fewer hardware outputs) —
  the banner covers it; a dialog cannot intercept a hotplug.
