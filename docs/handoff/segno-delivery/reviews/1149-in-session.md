Model: Claude Opus (subagent), in-session
Base: 270209fbc (PR #1145 head) / Head: b45e999b3 (claude/foot-fade-controls-1147)
Scope: Fade part 3a. Read-only; nothing built or run. Duration MIDI/CTRL targets are #1148, not counted.

## Introduced defects

**D1. A Custom LED assigned to `direct:fade:all` never lights in a normal session (medium).**
`lib/control/cubit/control_cubit.dart:3703,3723`. `_channelsForAction(AllTracksScope)` returns all eight channels, and `everyTrack` requires every one of them to be attenuated. An empty track cannot fade: `FootFadeActions.toggle` refuses it and its envelope stays at unity. Trigger: record tracks 1, 2 and 5, then stomp a Custom `direct:fade:all`. Those three tracks fade, but the LED stays dark. It can only light when all eight tracks hold material. This breaks the "truthful LEDs" requirement. Fix: in the fade arm, evaluate only channels whose track has content, and require that set to be non-empty, e.g. `final recorded = channels.where((c) => looper.tracks[c].hasContent); recorded.isNotEmpty && recorded.every(attenuated)`. Add the case to `foot_fade_dispatch_test.dart` (the "all-tracks" test there uses exactly this {0,1,4} rig but never checks the LED).

**D2. Quick Time+/Time- taps can lose a step (medium-low).**
`lib/control/foot_fade_actions.dart:68-84`. `step` computes an absolute `next` from `settings.confirmed` before the write is queued. `FadeSettings._edit` then persists that absolute value and ignores the `value` its closure receives. Each persist does a checkpoint read, a write and a verifying read through `_serialize`, and `confirmed` only advances after that completes. Trigger: two Clear taps inside one persist round-trip. Both read 4000 and both write 4500, so the second tap is lost while each tap looks accepted. Mixer avoids this because it delegates relative steps to its owner (`mix.stepTrackGain(direction:)`). Fix: do the relative step inside the queued edit, e.g. `FadeSettings.step(int? channel, int deltaMs)` built on `_edit((value) => ...clamp...)`. Test it with a store whose write completes only when the test releases a gate.

**D3. The Bank pedal's on-screen selection bar ignores bank B (low).**
`lib/looper/view/foot_fade_view.dart:407-409`. `selected` is true only for Exit and attenuated tracks. The physical Bank LED is lit for bank B (`control_projection.dart` `PedalButton.bank => overlay.activeBank == 1`), and the accepted Pen frame `zzlgN.png` (Fade / Bank B) shows a lit Bank bar. Golden `foot_fade_bank.png` shows it dark. Fix: add `|| (role.press == FootFadeAction.nextBank && projection.bank == 1)`, then regenerate the golden.

## Design / VGV

**V1. The optional `FadeSettings? fadeSettings` is a fallback that exists only for tests.**
`control_cubit.dart:194,214`. Production (`app_runtime.dart:81`) always passes it. The null path still costs six null guards, a refusal branch in `setMode` (`:1799`) and a test of a state that cannot occur in production (`foot_fade_dispatch_test.dart` "without a Fade owner refusing"). That branch also runs `_footMixerVisit = Object()` and `_invalidateGestures()` (`:1772-1776`, including `releaseAllMomentary`) before it refuses, so a refused entry still destroys live gestures. AGENTS.md says to remove fallback paths. The other controls are required interfaces with fakes. Fix: make the parameter required, have the ~30 test constructors pass a `FadeSettings` over their existing `SettingsRepository`, and delete the null branches.

**V2. The view reads the application owner directly and uses its error-notice stream as change notification.** `foot_fade_view.dart:25-31`. This works: every confirmation, including `load`, `recover` and `installSession` via `_persist`, emits `null`, and the builder re-reads synchronously, so no update is missed. It is still a view depending on a non-Bloc owner. It is acceptable for now; the only alternative is to mirror durations into ControlState, which is more state. Leave it, but document that contract on `results`.

## Traced and found correct (no action)
- Exit while a track hold is pending, by physical Mode, the screen Exit button or Esc/M: `setMode` calls `_invalidateGestures`, which cancels `_trackHoldGestures`. The later release finds an inactive gesture and does nothing. Disposing a screen pedal routes to `footMixerCancelled` with a token match, so nothing leaks.
- A pending hold follows a bank change: the slot is resolved at fire time against `state.activeBank`. A completed hold clears `_onTap`, so its release is consumed.
- Physical and screen overlap on one button: `_pressedButtons.containsKey` refuses the second contact, and a release from a different owner is ignored.
- Session change: `_armGesture.stillValid` already checks `sessionRevision`.
- Link loss and retire: these are existing Mixer paths and apply unchanged.
- `_runAction` returns a Future for single and fade-all actions. Custom, external (`_fireExternal`) and MIDI (`await`) all handle `FutureOr`. Toggling each track independently under "all" matches the existing mute-all behaviour.
- Mode switch arms: wire `PedalMode.custom`, Rec/Play on the cursor, Stop → `parkAll`, inert tile/digit keys, Esc/M exit and meter colours are all consistent with Mixer and with the UX table.
- Spanish: the "Grabar / Repr..." ellipsis already exists in `foot_mixer_spanish.png`. It is not introduced here.

## Optional tests (gaps that matter)
1. A Custom `direct:fade:all` LED with partial recordings (D1).
2. Two Time+ taps before the first write confirms (D2).
3. A physical track hold, then Mode before the threshold: no selection change and no toggle after the release in Record. The plan lists this.
4. A session revision bump during a pending track hold.
5. A physical and a screen press on the same track: one toggle only.
6. The view refreshes after `fade.setDefault`. Every view test sets durations before pumping, so the StreamBuilder path is unverified.
7. Fade-mode Rec/Play acts on `state.cursor` after a Bank browse, i.e. it does not follow the visible bank.
The view tests use a mocked ControlCubit, so they check call wiring, not real dispatch as the plan asks. `foot_fade_dispatch_test.dart` covers real dispatch with independent oracles (literal seconds, independently decoded storage), which is good.

## Nits
- `_footMixerVisit` and `_cancelMixerHolds` now serve both Mixer and Fade. Rename them to performance-surface names (`control_cubit.dart:1408`, `control_foot_mixer.dart:11`).
- The session check in `dispatch` (`control_foot_fade.dart:29`) and the hold cancel in `_reduce` (`control_cubit.dart:1627`) repeat what `_armGesture.stillValid` already does. Keep only the selection reset.
- `canShorten`/`canLengthen` (`foot_fade.dart:215,218`) are unused.
- The "attenuated" predicate (`amount < 1 || amount != target`) appears three times: `control_projection.dart:100`, `control_cubit.dart:3725` and `FootFadeTrack.attenuated`. Put one getter on `FadeImage`.
- Adding `fade` to `empty-track-dark` exclusions (`invariants.dart:184`) is unnecessary. A Fade LED is always dark on an empty unity track, and keeping the invariant would catch a stale envelope on a cleared track.

## Verdict
Request changes: fix D1 and D2 (both small) and D3. V1 is recommended in the same PR. Gesture ownership and lifetime are sound.
