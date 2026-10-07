Model: Claude Opus (subagent), in-session

# Review of PR #1233: feat(control): foot Peel surface, mappings and refusal notices (#1164 Part 3)

## Scope

- Branch `origin/claude/peel-1164-p3` at `c79280778`, one commit on top of Peel P2. Merge base with the trunk: `531addc0d`.
- Trunk: `origin/claude/segno-integration` at `097e1ef68`, which now contains Peel P2 and Reverse P3 (#1162, merged at `ba0766ae3`).
- Reviewed against:
  - `docs/plan/2026-10-05-feat-foot-peel-plan.md`, sections 1.3, 3, 4 Part 3, "Part 3 as built" and 5;
  - AGENTS.md;
  - the owner rules;
  - Reverse P3 on the trunk: `control_foot_reverse.dart`, `foot_reverse_view.dart` and its goldens;
  - the main checkout's `segno-ui.pen`, read-only through the pencil MCP.
- Production files read in full:
  - `lib/control/model/foot_peel.dart`;
  - `lib/control/foot_peel_actions.dart`;
  - `lib/control/cubit/control_foot_peel.dart`;
  - `lib/looper/view/foot_peel_view.dart`;
  - every changed switch arm in `control_cubit.dart`, `control_state.dart`, `control_projection.dart`, `invariants.dart`, `control_action*.dart`, `tracks_view.dart`, `track_column.dart`, `wave_track_row.dart`, `tracks_commands.dart`, `pedal_plate.dart` and the two themes;
  - both ARBs.

## Runs

- `git merge-tree --write-tree origin/claude/segno-integration c79280778`: **18 conflicting files**.
  - 15 under `lib/`.
  - `test/looper/view/tracks_view_test.dart` and `test/screenshots/tracks_screenshots_test.dart`.
  - The binary golden `test/screenshots/goldens/pedal_setup_picker.png`.
- Local merge in a scratch worktree, resolved by keeping both arms everywhere. The resolution ran `flutter pub get` and `gen-l10n` first, then `dart format` on the merged files only.
  - `dart analyze --fatal-infos lib test`: clean, after putting the two union-merged imports in order.
  - `bloc lint lib test packages`: 0 issues, 887 files.
  - App suite with `SEGNO_ENGINE_LIB` from `build_test_lib.sh`: `+3505 ~56 -1`.
    - The one failure is `pedal_setup_screenshots_test.dart: Mode choices`, a golden pixel diff of 0.07% (1446 px). Neither side's `pedal_setup_picker.png` lists both Reverse and Peel.
    - After `--update-goldens` the test passes. I inspected the regenerated image: the 3x3 grid shows Fade, Reverse and Peel, nothing is clipped, and the layout is otherwise unchanged.
  - The four `foot_peel_*` and four `foot_reverse_*` goldens all pass on the merge.
- PR head: `dart analyze --fatal-infos lib test` is clean. The 182 tests in the Peel and related suites pass: `foot_peel_dispatch_test`, `foot_peel_projection_test`, `foot_peel_view_test`, `tracks_view_test` and `control_projection_test`.
- Mutation runs against those 182 tests, one mutant at a time, restored after each:

| Mutant | Result |
| --- | --- |
| M1 drop `!_takeLocked()` from `_peelEditable` | killed |
| M2 LED blue on `peelDepth > 0`, ignoring busy | killed |
| M3 a busy recorded track projects `hasContent: false` (reads "Empty") | killed (4 tests) |
| M4 assigned Peel arm no longer reports its refusal | killed |
| M5 `_slotless` Peel arm returns false | killed |
| M6 drop `!_inputRetired` from `_peelEditable` | **survived** |
| M7 toast listener restricted to `after.mode == peel` | **survived** |
| M8 `trackPressed` peels in Peel mode | killed |
| M9 selection bar on `hasContent` instead of `available` | killed |
| M10 drop the Session-transition gate | killed |
| M11 `activateFootPeelPedal` skips `_peelEditable` | **survived** |
| M12 `peelFootPeelTrack` skips `_peelEditable` | killed |

- `cspell -c .github/cspell.json` on the plan: 0 issues. CI spell-checks only `**/*.md`.
- Pen check: a pencil `Get` visitor over `segno-ui.pen` matching /peel/i found 37 nodes. All of them are "Hold · Peel" Custom-assignment examples, picker choices (`expr:switch:choose:mode:peel`, `loop:pedal-choice:Peel`) or the restoration note. There is no Peel performance frame.

## Verified correct (traced)

- **The take lock gates the surface.**
  - `_peelEditable` (`control_foot_peel.dart:4-9`) checks closed, input retirement, `_takeLocked()`, mode and the Session transition.
  - `_onPeelPress`, `activateFootPeelPedal` (except Exit) and `peelFootPeelTrack` all go through it. Exit bypasses it in both `_onPeelPress` and `activateFootPeelPedal`, and the header Exit calls `setMode` directly, as Fade and Reverse do.
  - Physical contacts are additionally gated by `_handleEvent` (`control_cubit.dart:2264`).
  - M1, M10 and M12 are killed by "refused while the power-off dialog is up" and "refused while a Session load holds control".
- **The take lock gates the assigned paths.**
  - Custom: `_fireCustomAction` checks `_takeLocked()` at `:2457`.
  - CTRL: the external contact path (`:446`) and `_fireExternal` (`:497`) check it.
  - MIDI: `control_midi.dart:587` checks it.
  - All three reach `_runAction` → `_runTrackOperation` → `TrackOperation.peel` only after the gate. The CTRL refusal under power-off is tested.
- **Busy tracks never read "Empty".**
  - `readFootPeelTrack` keeps `hasContent`, `layers` and `busy` apart.
  - `_layersWord` keys only on `hasContent` and `layers`.
  - The refusal order is `empty`, then `busy`, then `originalOnly`.
  - Natively, `le_publish_undo_depth` (`engine_commands.c:89-118`) zeroes `a_peel_depth` only while the wire reads EMPTY or a frozen Clear is pending. An overdubbing or draining track therefore keeps its real `peelDepth`, and the dimmed count is the true count. M3 is killed by four tests.
  - An empty track with a pending Count-in reads "Empty". That is correct: it has no content.
- **The `trackPressed` arm is inert.**
  - `case InteractionMode.peel: break;` sits beside Mixer and Fade (`control_cubit.dart:1802-1808`). The tile `onTap` in `track_column.dart` only selects in Peel mode.
  - The only `lib` caller of `trackPressed` is the `_onPress` track-pedal branch, which Peel mode never reaches because `_onPeelPress` returns first.
  - M8 is killed by "a track tile tap is inert in Peel mode".
- **The stateless action is shared.**
  - `FootPeelActions.peel` is the one adapter for the surface and for `TrackOperation.peel`.
  - It refuses from the projection before calling the engine and maps `invalid` to `originalOnly`, `notReady` to `busy`, and anything else to `failed`.
  - Peel is synchronous, so the report always belongs to the press that caused it. Reverse's visit and session checks are not needed.
- **LEDs and wire mode.**
  - The track LED is blue only on `Track.canPeel`.
  - Slot-less pedals light only for an accepted contact, through `_slotless`.
  - The wire mode is `PedalMode.custom` in both `projectFrame` and the invariant.
- **`allowsAllTracks` excludes Peel**, and the test asserts it.
- **Peel completes on the control thread.** `ControlState.footPeelFailure` and `footPeelRefusal` are in `props` and `copyWith`, and the toast reads the reason from the same emit.
- **The layer badge decrements on a peel.** This is tested in `tracks_view_test`.
- **Merge semantics.** Apart from the textual conflicts the two features are independent. The merged `_slotless` carries Fade, Reverse and Peel arms. The merged `_onPress` routes Reverse and Peel to their own handlers.

## Findings

### Medium

**M-1. The PR does not merge with the trunk: 18 files conflict, and two naive resolutions break the build.**

Every conflict is a pair of sibling `InteractionMode.reverse` and `InteractionMode.peel` arms. Most resolve by keeping both, but these do not:

- `lib/control/cubit/control_cubit.dart`:
  - the `footReverse*`/`footPeel*` method block (head `:2091`): a straight union leaves `_toggleReverseChannel` without its closing brace;
  - the `_onPress` routing (head `:2348`): a union leaves the Reverse `if` without `return; }`.
- `lib/control/control_projection.dart:241`: the `_slotless` header is duplicated.
- `lib/looper/model/interaction_mode.dart:50` and `lib/control/binding/control_action.dart:171`: the terminal `;` must become `,`.
- `track_column.dart` and `pedal_plate.dart`: the `=>` arms must become `||` patterns.
- `tracks_commands.dart` and `pedal_plate.dart` a11y: the `==` chains need `||`.
- `tracks_view_test.dart`: the Reverse `group` must be closed before the Peel tests.
- `tracks_screenshots_test.dart`: the two scene loops interleave line by line and have to be rebuilt as two loops.
- `pedal_setup_picker.png` must be regenerated.

On GitHub the PR's base is still `claude/peel-1164-p2`, where it reads MERGEABLE/CLEAN (checked with `gh pr view 1233`). That is the stacked-squash trap: once P2 is in the trunk, retargeting to `claude/segno-integration` turns the PR conflicting, and no CI has run against the trunk merge.

I resolved all of this locally and the result is green: analyze, bloc lint, and the suite with the regenerated golden. The functional content is sound. The branch still needs that merge, or a rebase, pushed, and CI rerun on it.

Suggested fix:
- merge the trunk into `claude/peel-1164-p3` as above and retarget the PR to `claude/segno-integration`;
- regenerate and inspect `pedal_setup_picker.png`.

Also consolidate two places where the merge leaves duplicate arms (see L-5).

### Low

**L-1. The Spanish retry wording does not match its sibling notices.**

`lib/l10n/arb/app_es.arb:2697-2698` uses voseo: "Probá de nuevo" and "Probá de nuevo cuando esté sonando".

On the trunk every other retry message uses tú:
- "Inténtalo de nuevo" appears 6 times, including the sibling surface failures `footMixerFailure`, `footFadeFailure` and `footReverseFailure` (`:2707, :2730, :2741`);
- "Vuelve a intentarlo" appears 3 times.

"Probá" appears nowhere else. The file does mix registers elsewhere (voseo instructions such as "Elegí", "mantenés", "Revisá" sit beside tú ones such as "Toca", "Pulsa", "Conecta"). The retry family is uniform, though, and the plan's stated reason, "Argentine voseo", is not the convention that family follows.

Suggested fix:
- `footPeelFailure`: "No se pudo quitar la capa. Inténtalo de nuevo."
- `footPeelRefusedBusy`: "... Inténtalo de nuevo cuando esté sonando."
- Update the plan's "Overview wording" bullet and its cspell ignore line, then regenerate `foot_peel_spanish.png` if the busy string appears in it. It does not appear in the current scene.

**L-2. Three gates have no test, and the mutants survive.**

- **M11:** `activateFootPeelPedal` (`control_cubit.dart:2127-2131`) is the only gate for semantic activation of Rec/Play, Stop and Bank. `_recAdvance` has no take-lock check of its own; `recPlay()` has one, but `_dispatchPeelAction` calls `_recAdvance` directly. The test activates only track pedals under the lock, and those are re-gated inside `peelFootPeelTrack`. Without the gate, an accessible activation of Rec/Play while the power-off dialog is up would start a take.
- **M6:** `!_inputRetired` in `_peelEditable` is unobserved.
- **M7:** the claim that every refusal shows a notice in every mode is tested only at the cubit level, through the `refusals` counter. No widget test shows the toast from an assigned Peel while in Tracks, Custom or another mode.

Suggested fix:
- add `activateFootPeelPedal(PedalButton.recPlay)` and `(PedalButton.stop)` under `powerOffUp` and after `close()`, asserting no record or stop calls;
- add one `tracks_view_test` case that fires an assigned Peel refusal in Record mode and finds the toast.

**L-3. The pen write-back is outstanding.**

The plan's "Part 3 as built" says to "add a Peel performance frame beside 13 (Reverse)" with the "Layers" heading, the "Original only" and "Empty" words, and the four refusal notices. The pen has no such frame (37 /peel/i matches, none a performance screen).

This PR ships a new surface and a departure from plan §3 (notices instead of silence). By the project rule that a shipped departure is written back into the pen, the design source is now behind the code.

Suggested fix: add the frame and a `c/` note before merge, or track it on #1164 as an explicit follow-up.

**L-4. The plan's status line is stale.**

`docs/plan/2026-10-05-feat-foot-peel-plan.md:5` still reads "implementation not started", while the same document records Parts 1 to 3 as built.

Suggested fix: update the status line.

**L-5. The merge leaves two duplicate arms (consolidation, rule 4).**

After resolution:
- `setMode` has identical `case InteractionMode.reverse:` and `case InteractionMode.peel:` bodies (`excluded: {}`, `parkedResume: {}`);
- `recPlay()` has a separate `case InteractionMode.reverse: _recAdvance(state.cursor);`, which git auto-merged next to the `record/mixer/fade/peel` group.

Both work, but each should be one grouped case.

## Notes

- **The departure from plan §3 needs the owner's call.** Plan §3 said "without a notice"; the PR gives a notice for every refused press, from the surface and from assigned Peel in any mode.
  - It is documented in "Part 3 as built" with rule 3 and the Reverse review's Medium 2 as the reasons. Since the issue is `autonomy:merge-gate`, the human merge is that call.
  - Visible consequences that differ from the siblings:
    - In Peel, an empty track's pedal is enabled-looking and gives a warning toast. In Reverse (`foot_reverse_default.png`, Track 4) and Fade, an empty track's pedal is dimmed and silent.
    - Assigned Fade and Reverse are silent on refusal; assigned Peel shows a toast.
  - These are coherent with the stated rationale. The owner should confirm them knowingly.
- **The busy notice can name the wrong cause.** `EngineResult.notReady` is mapped to `busy`, "...while the track records or is about to". The engine also returns NOT_READY for a pending state command, a cancel, or a Clear report. The repository returns it while a Session is applied, where an assigned Peel, which has no Session-transition gate, actually reads `empty` first because the public tracks are cleared. In those rare cases the wording names the wrong cause. The cases are sub-second windows and acceptable.
- **`FootPeelTrack.available` restates `Track.canPeel`.** It is `hasContent && !busy && layers > 1` (`foot_peel.dart:79`), while the LED uses `Track.canPeel` directly. Given the native contract (peel depth is 0 while EMPTY) the two are equivalent. Deriving `available` from `canPeel` would keep one definition.
- **The `FakeAudioEngine` fix is right.** The snapshot wrapper now forwards `peelDepth` and `pendingLaunch`, which it had dropped.
- **Outstanding:** the appliance hardware evidence, the plan's last success criterion.

Verdict: Request changes. The code is sound. Push the trunk merge (M-1) and fix the Spanish retry wording (L-1); L-2 to L-5 are small.

## Delta review (73f941d86)

### Scope

`origin/claude/peel-1164-p3` at `73f941d86`. The PR is now retargeted to `claude/segno-integration`. New commits:

- `dc4ff8593`: merges the trunk `097e1ef68`;
- `1704e647d`: dims an empty Peel track and adds tests for the surface gates;
- `456654207`: the notice policy for assigned Fade and Reverse;
- `73f941d86`: pins the Spanish retry wording in the tests.

The coordinator's rule-4 notice policy settles the departure from plan §3, so I did not reopen it.

### Runs

- `git merge-tree` of the trunk with the head: clean (exit 0). GitHub: MERGEABLE.
  - CI: 16 checks SUCCESS. 8 package `build` jobs were still QUEUED when I checked: build, fx-catalogue, looper-, session-, storage-, performance-, pedal- and controller-repository.
- At the head:
  - `dart analyze --fatal-infos lib test`: clean;
  - `bloc lint lib test packages`: 0 issues, 887 files;
  - `cspell` on the plan: 0 issues.
- Full app suite with `SEGNO_ENGINE_LIB`: **`+3513 ~56`, all passed** (exit 0).
- Mutation runs against 201 tests: the Peel suites, `tracks_view_test`, `foot_fade_dispatch_test` and `foot_reverse_dispatch_test`.

| Mutant | Result |
| --- | --- |
| M6 drop `!_inputRetired` | killed ("a retired input ignores the surface") |
| M7 Peel toast listener filtered to Peel mode | killed ("an assigned Peel says why ... outside the Peel surface") |
| M11 `activateFootPeelPedal` skips its gate | killed (2 tests, including "semantic Rec/Play, Stop and Bank do nothing under the power-off dialog") |
| P1 drop `_reportAssignedRefusal` | killed (4 tests) |
| P2 drop the Session check in `_reportAssignedRefusal` | **survived** |
| P3 Fade listener filtered to Fade mode again | killed |
| P4 Reverse listener filtered to Reverse mode again | killed |
| P5 the surface reports `empty` too | killed |
| P6 an empty track's pedal enabled | killed |
| P7 an assigned Fade refusal counted as Reverse | killed |

### Prior findings

- **M-1: resolved.**
  - I compared the merge resolution against the trunk for each of the 18 files. Every mode switch carries both arms as `||` patterns or grouped `case`s.
  - `_slotless` has Fade, Reverse and Peel arms. `_onPress` routes Reverse and Peel separately. The method blocks are intact. The imports are sorted.
  - `tracks_view.dart` has three listeners. The view ternary chains Fade, then Reverse, then Peel.
  - Golden: I inspected `pedal_setup_picker.png` (62138 → 62581 bytes). The 3x3 grid shows Fade, Reverse and Peel, nothing is clipped, and the rest of the layout is unchanged.
  - The four `foot_peel_*` goldens were regenerated for the dimmed empty pedal. I inspected the Spanish one: "Vacía" is dimmed on Track 4.
  - "Grabar / Repr..." is truncated, but identically in the trunk's Fade and Reverse Spanish goldens, so it predates this PR.
- **L-1: resolved.** `footPeelRefusedBusy` and `footPeelFailure` now use "Inténtalo de nuevo", like every sibling retry notice. `73f941d86` pins all four Spanish notices in `foot_peel_view_test`. The plan's cspell line and wording bullet are updated.
- **L-2: resolved.** M6, M7 and M11 are now killed, by:
  - "semantic Rec/Play, Stop and Bank do nothing under the power-off dialog";
  - "a retired input ignores the surface";
  - "an assigned Peel says why it removed nothing, outside the Peel surface".
- **L-3: accepted as a tracked follow-up.** The plan now lists the pen write-back as outstanding and owner-edited: the frame, the dimmed empty pedal, the notices and a `c/` note.
- **L-4: resolved.** The status line reads "Parts 1 and 2 built and merged into the trunk; Part 3 built (PR #1233), awaiting review and the appliance hardware evidence".
- **L-5: resolved.** `setMode` has `case reverse: case peel:` with one body. `recPlay()` groups `record/mixer/fade/reverse/peel` into one arm.

### The notice-policy commit (456654207), traced

- **The change.** `_runAction` now sends every assigned Fade and Reverse through `Future.wait`, single channel included.
  - When no target accepted, `_reportAssignedRefusal` increments `footFadeFailure` or `footReverseFailure` once per gesture, never once per channel.
  - The Session revision is captured before the toggles and checked again before the emit.
- **Double toasts in the toggle's own mode: none.**
  - The surface paths (`toggleFootFadeTrack`, `_toggleReverseChannel`) never go through `_runAction`, and the assigned paths never call the surface reporters. One gesture raises at most one increment.
  - In Fade or Reverse mode, an assigned trigger can come only from CTRL or MIDI. Custom requires Custom mode.
  - `FootFadeActions.toggle` and `FootReverseActions.toggle` emit nothing themselves. The repository's `toggleFade` and `toggleReverse` raise no notice; the only other Reverse notice, `footReverseOverdubRefused`, belongs to the record path.
  - `showAppToast` calls `dismissAppToast(id)` first, so even two quick refusals replace each other rather than stacking.
- **Removing the mode filter is safe.**
  - Every surface emitter still checks its own visit, mode and Session: `_reportFadeFailure` (`control_foot_fade.dart:66-73`) and `_reportReverseFailure`.
  - Those emitters, the new assigned reporter and `_reportPeelRefusal` are the only places the counters are incremented (`grep "Failure + 1"`).
  - So the unfiltered listeners cannot show a stale surface report after Exit or a Session change.
- **Stale reports across a Session change.** `_reportAssignedRefusal` drops a report whose Session has been replaced, and Peel's assigned report is synchronous. The guard is correct but untested (P2 survives; see D-1).

### New findings

**Low D-1. The Session guard in `_reportAssignedRefusal` has no test.**

`control_cubit.dart:2661-2670`, the `_looper.sessionRevision != session` check, can be deleted with all 201 tests passing.

Failure scenario if it regresses: a CTRL- or MIDI-assigned Reverse waits on its engine receipt, a Session load replaces the rig meanwhile, and the receipt's refusal raises "The track could not be turned around" against the new Session.

Suggested fix: one dispatch test that holds the fake engine's `toggleReverse` future, bumps `sessionRevision`, completes it with a refusal, and expects `footReverseFailure` to stay unchanged.

**Low D-2. The assigned notice for an empty target tells the performer to retry.**

An assigned Fade or Reverse whose target is empty (a fixed track, or All tracks with nothing recorded) now shows the generic engine-failure notice:
- "The fade could not be started. Try again.";
- "The track could not be turned around. Try again."

Retrying cannot help. Assigned Peel distinguishes this case ("The track is empty: there is no layer to peel.").

This follows the settled policy, so it does not block the merge. A follow-up could give Fade and Reverse an "empty" reason, or shared empty-target wording.

### Notes

- The `PedalButton` contact for a silent empty-track press is still added to `_acceptedContacts`. Track LEDs come from `trackLeds`, not from that set, so nothing visible changes.
- On a pedal-surface Peel, an empty track is silent, while an assigned Peel (CTRL in Peel mode included) on the same track shows "empty". This is the policy as written.

Delta verdict: **Approve.** M-1, L-1, L-2, L-4 and L-5 are resolved and L-3 is tracked. D-1 and D-2 are non-blocking Lows. The approval holds once the 8 queued CI jobs come back green.
