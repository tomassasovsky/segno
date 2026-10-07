Model: Claude Opus (subagent), in-session

# Review of claude/library-1178-p5-lows (80be1665e): Open and New loop withdraw a pending arm before they save, and the timeout says the take is finishing

**Branch:** `origin/claude/library-1178-p5-lows`, head 80be1665e, one commit on 55ee5a373 (Part 5 after its delta). 6 files, +150/-7.

**Scope:**
- The commit, checked against the Part 4 delta's D-1 (a pending arm is not withdrawn before the outgoing save) and D-2 (the timeout copy).
- The engine semantics of `cancelArm`, `cancelCountIn` and `PendingLaunchAction`.
- AGENTS.md conventions.
- The owner rules.

## Runs

Everything ran in a scratch worktree at 80be1665e, removed afterwards. `SEGNO_ENGINE_LIB` was set.

| Check | Result |
| --- | --- |
| `test/session test/library test/looper/view test/app` | +1114 ~6 -1 |
| The one failure | `click_persistence_test` "Save As and Save capture Released" failed in its `setUp` while three suites ran in parallel. Alone, it and `decay_persistence_test` pass (+9). A trunk test that is sensitive to load |
| `dart analyze --fatal-infos lib test packages` | No issues |
| `git merge-tree` onto the trunk 787d51db6 | clean |
| `git merge-tree` with p8 | clean |

**Mutations** (each reverted, run against `session_cubit_test.dart` and `library_page_test.dart`). All five are caught:

| Mutation | Caught by |
| --- | --- |
| No `cancelArm` of pending tracks | "...withdrawn before the outgoing rig is saved (review D-1)" |
| No `cancelCountIn` for a pending launch | the same test |
| The wait ignores arms (`while (capturing())`) | "an arm that is not withdrawn in time refuses the Open" |
| The early return ignores arms | the D-1 test |
| The Open question ignores `pending` | "a track armed to record is asked about first (review D-1)" |

## Verified correct (traced)

1. **Arms and launches are withdrawn before anything is saved.** `_endCaptures` (inside `runExclusive`, first in both Open and New loop) does the following:
   - calls `cancelArm` on every `pending` track. That is "the unconditional cancel" the looper documents for "nothing may fire later".
   - calls `cancelCountIn` when any track has a `pendingLaunch`.
   - stops live captures as before.
   - waits until no track is pending, launching or capturing, or refuses after 20 s.
2. **`cancelCountIn` covers every pending launch.** In the engine, a launch cohort exists only under a Count-in: `le_launch_defer` returns 0 unless `count_in_total > 0` or a Count-in begins. `le_cancel_count_in` resets the whole cohort (`le_count_in_reset` clears every `a_pending_launch`) and settles any grace. So no `pendingLaunch` can outlive the call and hold the wait for 20 s.
3. **Signal-triggered and quantized arms** are both `pending` and both withdrawn by `cancelArm`, which needs no matching trigger.
4. **The Open question** now also asks for `pending` and `pendingLaunch` tracks. New loop always asks.
5. **The wait uses a `Stopwatch`**, so an NTP step at boot cannot change it.
6. **The timeout copy** is "The take is finishing. Try again when it has stopped.", with the Spanish to match. It no longer claims nothing changed.

## Findings

### 1. Low: an Open that is then refused has already withdrawn the player's arms and Count-in

- **Where:** `_endCaptures` runs before `_preserveOutgoing` and before the target is read.
- **Trigger:** the target is refused (unreadable, unconvertible, or the device not running), or the preservation save fails.
- **Impact:** the Open changes nothing on disk, as reported, but a pending arm, a pending Play or a Count-in the player set is gone. This is the same order as Stop, which the Part 4 dialog announces, and the confirm now names armed tracks. So it is a Low.
- **Fix:** read and validate the target (`bundlePathOf`, the manifest read) before `_endCaptures`, or say in the refusal that the arm was withdrawn.

### 2. Low: the arm withdrawal is covered only with the fake looper

- **What exists:** the D-1 tests use the cubit's mocked looper. `open_preserves_engine_test.dart` (real engine) has no case with a track armed for the loop top.
- **Fix:** add one: arm track 1 at the loop top, Open, then check that no capture started and that the outgoing bundle holds only the existing tracks.

**Verdict:** Approve. D-1 and D-2 are fixed, and every branch fails a test under mutation. The two Lows can follow.
