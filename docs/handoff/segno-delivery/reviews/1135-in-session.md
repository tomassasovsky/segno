# PR 1135 — Claude review (in-session)

Model: claude-opus-5-5 (Opus 5.5), interactive Claude Code session, 2026-10-05.
Packet base 6bf1ef00 → head 1ab753cd; seven paths (four production, three test).
Read-only over packet source/before/change.diff; nothing executed.

## Verdict: no correctness findings; one Low wording note

### Traced

- **Retry ordering.** `MonitorCubit.load` enters `MixSettingsCoordinator.runExclusive`,
  which increments `_exclusiveCount` synchronously at enqueue, so
  `acceptingEdits` is false from the Retry call until its section exits.
  Inside: ownership check, then `FxChainPersistence.flush()`, then `_restore`.
- **No lost accepted mute.** `applyMonitorMute` runs synchronously up to
  `saveMonitorMuteConfirmed`, whose `_queue` also runs before its first await,
  so every mute admitted before Retry is already in `_dirty` when Retry's flush
  starts. `_flushOutgoing` saves all dirty keys and rethrows a stored failure,
  so Retry cannot read storage older than an accepted mute; a failed earlier
  save is re-attempted by that same flush and keeps Retry failed until it lands.
- **No new mute mid-read.** Both callers (MonitorCubit.setMute and
  FootMixerActions monitor domain) go through the helper's synchronous
  `acceptingEdits`/`sessionTransitionActive` refusal before native admission.
  Foot reports through `onError`; nothing is retained or replayed.
- **Wait cycle.** `flush()` awaits `_sessionBootOutcome` only at entry. Retry
  cannot reach that read after `reserveSessionLoad` because `stillOwned()`
  checks `sessionTransitionActive` immediately before it. A reservation that
  lands later only flips `stillOwned()` and skips `_restore`; Session's own
  `beginSessionLoad` runs inside its exclusive, queued after Retry, so neither
  side waits on the other. `settlePending` waits only FX tickets, not Mix
  exclusivity. Close and Session retirement both end in the existing
  `whenComplete` path without a stale restore.
- **Coordinator.** `acceptingEdits` is a pure extraction of the existing
  `_closed || _exclusiveCount != 0 || _recovery != null` gate at both former
  sites (the first site's separate `_recovery` early return still runs first).

### Low — refusal message overstates the cause (introduced)

`lib/app/monitor_mute.dart:17-19`. `acceptingEdits` is also false while any
other exclusive is queued or running: `setControllerValues` (every mapped
CTRL/MIDI Mix write from `ControlCubit`, including CC sweeps) and Session
capture/load. A monitor mute pressed during an expression sweep or a Session
save is now refused with "refused during restore or recovery". The refusal
follows the existing ordinary-edit policy (`setTrackVolume` etc. refuse in the
same window), so the behavior is consistent; the message is not. Smallest
correction: say "busy" or distinguish the two conditions. Optional regression:
a mute during an in-flight `setControllerValues` reports refusal and succeeds
after it completes.

### Tests

The five added cases cover pending storage/receipt ordering, refusal during
Retry then acceptance, failed earlier save, Session/close retirement during the
drain, and Foot refusal without replay. They assert stored and repository
values rather than mirroring source.

### Limits

No execution; author test counts are reported, not observed. No hardware or CI claim.
