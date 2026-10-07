Model: Claude Sonnet (subagent), in-session retry; no earlier Claude verdict exists for this head

# Independent review: Segno PR #1141 (Closes #1139), stationary Session Fade levels

Base `a921bd9a96044b28dfad9cbd900947573a79a0d6`, head `c2e1d728293e2db03848362d6027cbc84692c468`.

## Verdict

No actionable findings. I traced the five production edits through their callers and the native context in the packet and found no introduced defect. Items below are separated into preexisting or out-of-scope notes, optional test suggestions and unconfirmed hypotheses.

## Coverage and limits

Read in full: `change.diff` (all 22 paths), the production hunks with their enclosing functions, and the packet's native sources (`engine_commands.c` Fade admission and receipts, `engine_process.c` RESET_FADE/FADE/COMMIT_SESSION/publish order, `engine_session.c` import/finalize, `engine_snapshot.c` `le_fade_read`, `engine.c` `le_engine_commands_settled`). I read `docs/PROGRESS.md` and the plan, but did not read the author's `review.md` before forming this verdict.

Not done: I did not execute anything, and I did not read the `evidence/` logs. I inspected tests by source only. Vendor code, binaries, device behavior and listening behavior are outside what I could judge. Unread changed paths: none beyond the docs I only skimmed (`PROGRESS.md`, `review.md`).

## Traced paths (verified)

1. **Save.** `session_repository.dart:710` takes `track.fade.amount` from the same `_engine.snapshot()` used for length, undo depth and lane export inside the synchronous `_capture`. `le_fade_read` is a revision-checked read, and `le_fade_publish` runs every buffer (`engine_process.c:6465`). Nothing is written back, so save does not freeze or toggle the live ramp.
2. **Codec.** `session.dart` `SessionTrack.fromJson` requires `num`, finite, in [0,1], and accepts integer endpoints. A missing field gives `null`, which is not `num`, so `FormatException`. Version bumped 10 to 11; `Session.fromJson` rejects 10 via the exact-version check. `==` includes `fadeAmount`, and `hashCode` includes it, which keeps equal objects hashing equally. `-0.0 == 0.0` is accepted and harmless (`amount >= 0` holds natively).
3. **Preflight before outgoing side effects.** `SessionCubit.loadNamed` (`session_cubit.dart:243`) calls `rigFromBundle` before `_performance.disarmAndFinalize()`, storage reads or `_fxPersistence.beginSessionLoad()`. The new check in `_rigTracks` therefore throws `FormatException` first, and it also covers tracks whose lanes are later dropped. `LooperRepository.applySession` repeats the check inside the existing validation `any(...)` at `looper_repository.dart:3838`, before `++_sessionRevision`. Fabricated rigs that bypass the codec are caught there.
4. **Ordering of material identity.** Each `importLayer` lane 0 and each `finalizeLayers` pushes `LE_CMD_RESET_FADE` (`engine_session.c:136,292`). The callback bumps `fade_generation` in `le_fade_reset`. `le_fade_publish` stores `a_fade_generation` before `a_commands_published` is released (`engine_process.c:6465-6466`), and `commandsSettled` is `commands_posted == a_commands_published`. The new loop at `looper_repository.dart:4414-4425` runs after all finalizations and before `snapshot()`, so the identities read at line 4426 are post-reset. The new test holds the callback after finalization and asserts no install, commit or launch happens early.
5. **Install.** `FadeImage(amount == target == saved, fullTravelSeconds default 0)` satisfies `le_fade_image_valid`. The callback accepts it only if lifetime and generation match, `lanes[0].a_len > 0`, and `install` is set. EMPTY state is allowed for installs. Each install is awaited through the existing receipt path (`_requestFade`, 50 x 10 ms). `requireCurrent()` runs before the `isOk` check, so supersession reports "superseded" and does not forge success. Installs are sequential and complete before `commitSession`.
6. **Commit.** `LE_CMD_COMMIT_SESSION` moves tracks to STOPPED and does not reset Fade, and no other `le_fade_reset` caller (record start, clear, undo-to-empty, void take) is reachable from the commit or Play path. The stationary vector therefore survives to publication. The existing commit check and `_importTracks` pin keep imported material hidden and `play()` returns `notReady` until the import finishes.
7. **Failure cleanup.** The existing catch runs only if `current()`. It calls `_clearDestructive`, and clear resets Fade natively (`engine_process.c:2131`), so an installed amount cannot leak onto replacement material. Ring order means a queued install precedes the queued clear. A timed-out receipt becomes a tombstone (`_pendingFades[request] = null`) that is drained at the next admission or poll, so a discarded Future does not strand a native slot. If clear acknowledgement fails, `stopEngine()` runs. A superseded import skips cleanup, so a replacement's material is untouched. Admission refusal after an earlier track installed also reaches this cleanup.
8. **Boot Retry.** No change in `session_settings_coordinator.dart` or `fx_chain_persistence.dart`. Retry replays the stored `_SessionBootImage` and never re-reads or reinstalls Fade. `play()` is gated by `_sessionBootStartBlocked` through `_sessionAudioReserved` (`looper_repository.dart:289-292`), so the `play()` returning `notReady` assertion in `app_runtime_test.dart` genuinely reflects the launch block (the scripted stopped snapshot is not the only cause).

## Findings

None introduced.

## Preexisting or out-of-scope (not charged to this PR)

- Full-engine start/configure replaces material (#1140). The PR does not claim retention, and Retry's mix-generation and device checks (`retrySessionBoot`) would refuse a recovery after a reconnect.
- In mock-flavor builds `MockAudioEngine.installFade` returns invalid (`mock_audio_engine.dart:604`), so a session with tracks fails there. It already failed before this PR, because the mock snapshot has no STOPPED tracks and the commit check throws "commit was refused". Not a regression.
- A rig track whose lane 0 was dropped (first lane not index 0) fails `finalizeLayers`/commit validation already, and now would equally fail the install. The failure mode is unchanged.
- `RESET_FADE` pushes are `(void)`; a full ring would lose the reset. `le_import_fade_room` guards this, so no new exposure.

## Unconfirmed hypothesis (low)

`le_fade_read` returns the previously cached image when it observes an odd revision (mid-publish). If the one control-thread `snapshot()` at `looper_repository.dart:4426` hits that window, it could carry the pre-reset generation, and the native install would be rejected with `invalid`. The result is a failed and cleaned-up load, never a stale or partial install becoming audible, and the window is a few instructions per buffer. I did not construct a deterministic trigger. If wanted, one bounded re-read of the snapshot on a `generation` mismatch would remove it, but that is optional hardening.

## Test assessment (source only)

- The held-finalization actual-native-style test (`session_import_publication_test.dart`) asserts `fadePosted == false`, `committed == false`, `play() == notReady` and all tracks EMPTY while the callback is held. It then checks the first output peak `.125` (PCM .5 x .25), a silent sibling (amount 0), `target == amount`, `fullTravelSeconds == 0`, undo depth 0 and PCM `.5` preserved. Phases and channel selection are checked, not only helper names.
- The refusal test (channel 1 refused after channel 0 installed) asserts no commit, EMPTY projection and coherence; the follow-up `.6` import is replacement evidence, not PCM retention across reopen, which the test names correctly.
- The moving-capture native test (`fade_settings_native_test.dart`): earlier projection stays 1; saved `.75` follows `1 - 8000/(8000x4)`; live amount then `.5`, target 0, travel 4 s; PCM `.5`. The arithmetic matches `le_fade_tick`. It is deterministic because the pumped engine only advances on `pump`.
- The final direct invalid-amount test (`looper_repository_test.dart`) uses a running, present engine, complete audio, NaN/infinity/-.1/1.1, the exact error `session mix cannot be restored`, and unchanged revision, tracks and `engine.calls`. It ends with a `.25` positive control on the same rig builder, so the branch under test is the Fade check and not an earlier device refusal.
- `session_test.dart` keeps meaningful equality assertions: decoded equals the re-decoded value, hashes match for equal objects, and unequal objects are only asserted unequal (`isNot`), not hash-distinct. The exact v10 rejection and v11 serialization are covered.
- The app-level invalid-vector test iterates over missing, NaN, -.1 and 1.1 and asserts revision, perf disarm count, armed capture, stored durations and the transition flag are all unchanged, so the preflight-before-disarm ordering is observed.

## Optional test suggestions

- A test where `installFade` returns `ok` but the receipt later reads `invalid` (generation mismatch) would cover the receipt-failure branch distinct from admission refusal (the current refusal test uses admission `notReady`).
- A boot-Retry assertion that the `FakeAudioEngine` `installedFades` count is unchanged across Retry would pin "no reinstall or recapture" directly. Today it is shown indirectly through unchanged amounts and states.
