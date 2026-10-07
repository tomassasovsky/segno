Model: Claude Opus (subagent), in-session

# Review of PR #1189: settings consolidation Part 3 (one owner-backed Control dispatch)

**Branch:** `claude/settings-owner-1159-p3` at d65f39390, base `claude/settings-owner-1159-p2d` at c7672e5cb.

**Scope:**
- `git diff origin/claude/settings-owner-1159-p2d...origin/claude/settings-owner-1159-p3`;
- `gh pr view 1189`;
- the plan's "Part 3 as built" and decisions 40-41.

**Setup:** I worked in a temporary worktree with `SEGNO_ENGINE_LIB` built and exported, and removed it afterwards.

**Runs:**

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `bloc lint lib test packages` | 0 issues in 828 files |
| `flutter test test/control test/app test/session test/looper` | +2248 ~6, all passed |
| `looper_repository` | +799, all passed |

## Verified correct (traced against the 2d head)

1. **No per-family special case was lost** in `OwnedValuePort` (`lib/app/application/owned_value_port.dart`).
   - **Click volume:** MIDI clamps through `OwnedValueTarget.coerce`, as the old fallthrough did, and External passes the value through `toDomain` unchanged, as before.
   - **Click volume's lifetime change** still *invalidates*, so its sources are reset. Every other family *supersedes*, in the old order: Decay, Once, Length, Timing, Click mode, Count-in, Fade, then Click volume (`lifetimeChanges`).
   - **Count-in:** the Released value still goes as `releasedBars` into `setControllerCountIn`, which pairs it with the held Sound value in `RecordStartOwnerControl`. Every Record-start ordinary change still supersedes before it records (`superseded: true`).
   - **Decay, Once, Length and Timing** pass `target.address`, so per-track addresses are unchanged.
   - **Fade** goes through `setControllerDuration` (no receipt, a bool result).
   - **Decay's send-back** lives in the family, so it is untouched.
2. **The merged ordinary stream neither duplicates nor drops.**
   - It is one broadcast sync controller over the eight family streams, subscribed on listen and cancelled on cancel.
   - `ControlCubit` maps each change back exactly as the seven old subscriptions did:
     - `value == null` gives supersede only;
     - Count-in gives supersede, then the ordinary write;
     - every other family gives the ordinary write only.
3. **The release eligibility tuple is unchanged** in content. The owned fields moved into `eligibilityKey`, element for element, and `sessionRevision`, `mixGeneration`, Mixer settle, FX settle and `mixSettingsSnapshot` stay in `_releaseEligibility`.
4. **The #1093 fixes.**
   - MIDI no longer skips a whole event on a stale origin. Dispatch-time origins travel into `_applyMidiProposals`, and each row passes through `_originCurrent`.
   - MIDI and External `cancelled()` now check only the session and close (External also checks its token and calibration).
   - A stale Mixer origin drops only its own value: `_originCurrent` asks `controllerOriginsCurrent({target: origin})` per target, both in `parameters.removeWhere` and in the `mixValues` filter.
   - `_invalidateValueTargets` clears expression baselines only for jacks that map an invalidated target, and resets decoders only for MIDI devices with a mapping that names one. The keys are compared with `canonicalString()`, the same convention the MIDI engine uses elsewhere (`supersedeParameterClaims`).
   - The four new `external_dispatch_test` cases target exactly these paths.
5. **MIDI decoder narrowing with two devices, traced.**
   - Device A maps Click volume and device B maps a track volume. A Click lifetime change resets only A's decoders, learn and signal state, and drops only A's level entries; B keeps its pickup.
   - That is correct, because B's targets did not change value.
   - An empty affected set returns early, so nothing is reset.
6. **Lifetime supersede ordering.** `_onLooperState` compares the lifetime record once per state event, supersedes in the old order, then invalidates Click volume, exactly as the eight separate comparisons did.
7. **Test edits.**
   - The dispatch suites change only construction: the eight ports become one `OwnedValuePort` (`testFadeSettings()` is hoisted so the port and the foot Fade share one instance).
   - `click_dispatch`, `count_in_dispatch`, `fade_duration_dispatch`, `control_cubit` and `control_availability` tests add and remove no `expect`.
   - `control_value_resolver_test` rewrites 8 `expect`s from named snapshot arguments to `owned: OwnedValueSnapshots(...)` with the same expected values.
8. **Layering.**
   - `lib/control` defines the interface (`owned_value_control.dart`, importing only control and looper models plus `settings_repository`) and never imports the port.
   - `lib/app/application/owned_value_port.dart` implements it, and only `app_runtime.dart` imports it.
   - Composition depends on features, not the reverse. No cubit method returns non-void, and `bloc lint` is clean.

## Findings

None blocking.

## Notes

- **Decision 40 can drop a MIDI Click volume press that used to apply.**
  - **Before:** MIDI captured Click volume's origin at *apply* time (`captured.click`) and External fell back to the current lifetime.
  - **Now:** the dispatch-time origin overrides the apply-time one, so a Click volume MIDI value queued across a device restart or reconnect (`mixGeneration` change) is skipped silently, where it used to apply to the new lifetime.
  - A Session load was already a cancel. Every other family already behaved this way, and the next CC, or the release of a held control, re-applies.
  - This is a narrow race, consistent with decision 40, and not a rule-1 data issue.
- **Decision 41 changes which writes survive a mid-job cancel.**
  - Order between independent owners cannot change any result *except* through `cancelled()` between writes. A session change while an earlier owned write awaits its receipt drops the writes after it.
  - Click volume used to be written first, so it survived that cancel. Now it survives only if it comes first in the map.
  - The trigger is a Session change in the middle of an External job, which is rare, and no stored data is affected.
- **`_resetMidiDecoders(only:)` publishes `midiLevels: const {}`** while it keeps the other devices' entries in `_midiLevels`. Their meters blank until the next MIDI reading republishes the full map. That is cosmetic; publishing `Map.unmodifiable(_midiLevels)` there would keep them.
- **The decoder narrowing has no failing test,** as the PR says, because the harness has a single MIDI device. The trace above is the evidence. A two-device harness case would pin it.

**Verdict:** Approve.
