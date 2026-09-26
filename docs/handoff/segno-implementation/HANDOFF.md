# Segno design implementation: handoff

Written 2026-09-15. This covers everything done so far on epic #1009, "implement the accepted Segno design throughout the app": slices 1, 2 and 3 in full, slice 4 parts 4a to 4g, the pedal protocol v4 work (#763), and the footswitch art fix (#1033). Nothing in it is merged.

This folder is untracked, like the rest of `docs/handoff` and `docs/design`. A git worktree cannot see it, so read it from the main checkout at `/Users/Tomas/Documents/Work/opensource/loopy/docs/handoff/segno-implementation/`.

## Read this first

**What exists.**
- **Stacked PRs.** 27 open PRs, from #1011 down to #1049, form one linear stack. Each PR's base is the branch of the one before it.
- **Two local branches, not pushed.** They continue the stack:
  - `claude/midi-controls-page-1026` holds the MIDI controls page.
  - `claude/midi-old-model-removal-1026` removes the old MIDI model.
  - The GitHub CLI token expired before they could be pushed.
- **Merge state.** Only #1011, slice 1, is based on master, and only #1011 has CI. It was `ci:green`, `review:clean` and `ready-to-merge` against the master it was cut from. Every PR below it is `ci:red` because CI has not run on it, not because CI failed. See section 1.

**What changed underneath the stack.** `origin/master` has moved nine commits past `aa4f13df`, the commit the stack was cut from (fetched 2026-09-15 10:22 -0300). Two of those commits collide with slice 4:
- **#984 removes the pedal protocol slice 4 builds on.** It replaces the USB pedal with a UART console link and deletes `firmware/segno_pedal/pedal_protocol.{c,h}`, `pedal_codec.dart`, `pedal_protocol_traffic.dart` and `native_pedal_transport.dart`. #1029, #1030, #1031, #1032, #1036, #1039 and #1047 are written against those files.
- **#986 builds a second model for the CTRL jacks.** It routes them through `ControllerRepository`, via `lib/pedal/console_ctrl_source.dart` and `packages/pedal_repository/lib/src/pedal_ctrl.dart`, and renames `midi_tray_body.dart` to `controllers_tray_body.dart`.
  - Part 4f (#1035 to #1045) built the same jacks a different way.
  - The local removal branch deletes `ControllerRepository` and the old MIDI tray.
  - The brief forbids two owners for one value, so **the owner has to decide which pedal protocol and which CTRL model survive** before anything from #1029 down is rebased.
- **Conflicts.** A trial merge (`git merge-tree`) conflicts in 3 files for #1011 and in 54 files for the tip of the stack.
- **#1051 has merged**, so its engine fix is now on master too.

**What to do next, in order.**
1. Ask the owner to run `gh auth login`.
2. Push the two local branches and open their PRs. The descriptions are ready in `part-4g-midi/pr-a-body.md` and `pr-b-body.md`.
3. Post the part 4g progress note on #1026.
4. Get the owner's decision on #984 and #986 against slice 4.
5. Build a throwaway integration branch that merges the stack onto current master, and resolve the conflicts once there.
6. Land #1011, then each child in turn, with the procedure in section 1.
7. Continue slice 4 with part 4h (Reverse), then 4i to 4n, then slices 5, 6 and 7. Section 1 lists what each remaining part and slice covers.

**Rules that apply to every step.**
- No emojis, no attribution lines.
- Plain literal prose.
- No backward compatibility.
- Commit from a worktree.
- Every departure from the pen goes back into the pen.
- Every behaviour claim gets a test that fails without the fix.

Section 1 (e) lists the commands and the traps that have already cost time.

## What is in this folder

| Path | What it is |
| --- | --- |
| `HANDOFF.md` | This document. |
| `sources/pulls.md` | Every PR description from #1011 on, saved from GitHub on 2026-09-15. |
| `sources/commits.md` | The full commit messages of every PR in the stack, in stack order, plus the two local branches. |
| `sources/issue-*.md` | The epic #1009 and issues #1010, #1012, #1016, #1026, #1033, #1040 and #763, with their comments. |
| `part-4g-midi/` | The detailed part 4g handoff: its own `HANDOFF.md`, four research reports (pen spec, cubit map, UI and navigation map, old-model removal inventory), `pen/` exports of the 12 MIDI screens, and the two drafted PR descriptions. |

The original brief is `docs/handoff/segno-app/` in the main checkout: `IMPLEMENTATION_PROMPT.md`, `implementation-map.md`, `accepted-behavior.md`, `delivery-checklist.md` and `reference-gates.md`. The design documents it cites are in `docs/design/`. `segno-ui.pen` is the design source; read it only through the pencil MCP tools.

## Contents

1. Cross-cutting state: the PR stack, CI, landing procedure, tracking, progress against the brief, owner decisions, open questions, working rules and gotchas
2. Slices 1 and 2: Tracks view, first-take crown, reversible edits, record timing, Loop settings
3. Slice 3: mix model, output destinations, Audio routing, Mixer, FX placement and printing, FX surfaces
4. Slice 4, parts 4a to 4e: Press and Hold, Pedals setup, Custom controls, pedal protocol v4, LED colours, footswitch art
5. Slice 4, part 4f: External pedals (the CTRL jacks)
6. Slice 4, part 4g: MIDI formats, the mapping engine and the MIDI controls page

How it was written:
- **Sections 2 to 6.** Written from the PR descriptions, commit messages, issue comments, the notes kept during the work, and the code on the branches.
- **Section 1.** Written from the saved GitHub data and the git refs read on the morning of 2026-09-15. Its master facts were checked again at 10:22.
- **Not done.** No final cross-check between sections was run, so where two sections disagree, trust the PR description and the commit message.
- **Missing facts.** Where a section says a fact is not recorded, no source had it.


## 1. Cross-cutting state: PR stack, tracking, progress, decisions and working rules

Sources used here:
- PR and issue data saved from GitHub on 2026-09-15 at 06:38 (`sources/`).
- Git refs in `/Users/Tomas/Documents/Work/opensource/loopy`, read on 2026-09-15 at about 08:00. `origin/master` was last fetched at 07:57 -0300.
- The memory notes under `~/.claude/projects/-Users-Tomas-Documents-Work-opensource-loopy/memory/`.

Nothing on GitHub was checked again after 06:38.

### (a) The PR stack

- **Shape.** 27 open PRs and 2 local-only branches form one linear chain. Each branch contains its parent (checked with `git merge-base --is-ancestor`), and each PR's base is the branch in the row above it. The local branch tips match the head SHAs in the saved PR data.
- **Size.** The chain starts from master `aa4f13df` (#905). Against that commit, the chain tip changes 807 files (+85,773 / -41,799 lines).
- **Labels.** Every PR has `stage:in-review` and `autonomy:merge-gate`. Area labels are uneven: #1020 to #1022, and #1039 onward, have none. They do not affect the merge gate.

| PR | Part | Branch | Tip | Base | review | ci | Summary |
|---|---|---|---|---|---|---|---|
| #1011 | slice 1 (#1010) | `claude/segno-app-implementation-7c90a8` | `ec3e25f0` | master | clean | green, `ready-to-merge` | Tracks view, 7" selected-track face, engine crowns first completed take, snapshot `position_frames` / `output_peak` |
| #1013 | 2a | `claude/segno-slice2-edits-1012` | `6cdfb9fb` | #1011 | pending | red | Mode gate with stop-and-switch, undo/cancel during capture, frozen clear, grouped Clear All |
| #1014 | 2b | `claude/segno-slice2b-timing-1012` | `42c4d079` | #1013 | pending | red | Per-track `RecordTiming` and overdub decay, Once in all modes, count-in / Sound start exclusion |
| #1015 | 2c | `claude/segno-slice2c-loop-settings-1012` | `839cb330` | #1014 | clean | red | Loop settings hub and six pages; tray Loop domain and `QuantizeCubit` retired |
| #1017 | 3a | `claude/segno-slice3-mixer-fx` | `37f328ef` | #1015 | clean | red | Mix model: lane pan law, Solo, capture trim, every input monitorable, meters, `InputSetup`, `MixTarget` |
| #1018 | 3b | `claude/segno-slice3b-outputs` | `8625ba75` | #1017 | clean | red | 16 output buses (level/mute/mono/balance/chain), Cut, bypass tail drain, capture tap policy, `OutputSetup` |
| #1020 | 3c | `claude/segno-slice3c-routing-surfaces` | `6f7a3451` | #1018 | pending | red | Audio routing and Output setup pages, destination names |
| #1021 | 3d | `claude/segno-slice3d-mixer` | `2bca71f4` | #1020 | pending | red | Mixer as the third stage view |
| #1022 | 3e | `claude/segno-slice3e-fx-placement` | `be987759` | #1021 | pending | red | Pre/Post placement, Pre printing, All tracks chain, channel handling, whole-track Pre render |
| #1024 | 3f | `claude/segno-slice3f-fx-surfaces` | `95dcea0d` | #1022 | pending | red | Effects destinations, rack and single-effect editors, presets, `packages/fx_catalogue`, `LE_FX_MAX` 64; Signal tray retired |
| #1027 | 4a, 4b | `claude/segno-slice4-assignments` | `b89342e2` | #1024 | pending | red | Press and Hold as separate actions, gesture generations, selected-track scope |
| #1028 | 4c | `claude/segno-slice4c-pedals-setup` | `f93a4b6d` | #1027 | pending | red | Pedals setup Layout A, shared action catalogue; `ModeSwitchStyle` becomes the MODE pair |
| #1029 | 4d (#763) | `claude/pedal-protocol-v4-763` | `3fd9bf05` | #1028 | pending | red | Pedal protocol v4: mode value 3 means custom |
| #1030 | 4d (#763) | `claude/custom-controls-mode-763` | `27efe48a` | #1029 | pending | red | Custom controls mode; `_runAction` is the one interpreter; MODE default Mute / Custom |
| #1031 | 4e (#763) | `claude/pedal-v4-colours-763` | `424e12d0` | #1030 | pending | red | v4 adds 30 RGB bytes per footswitch; `pedal_unpack7` overflow fixed |
| #1032 | 4e | `claude/pedal-led-colours-1026` | `1e1dbc60` | #1031 | clean | red | LED palette; `PedalStateFrame.isLit` decides lit, the palette decides hue |
| #1034 | #1033 | `claude/pedal-face-art-1033` | `ef50473b` | #1032 | clean | red | Pedals setup map draws the real footswitch |
| #1035 | 4f | `claude/external-pedals-1026` | `b1a37fbe` | #1034 | clean | red | CTRL jack model and External pedals screen, switch half |
| #1036 | 4f | `claude/external-dispatch-1026` | `cafd2a3b` | #1035 | clean | red | CTRL switch Notes 10-13 reach `_runAction` |
| #1039 | 4f | `claude/external-expression-1026` | `4b8be459` | #1036 | clean | red | Expression CCs 0x11/0x12, calibration, value dispatch |
| #1041 | 4f | `claude/expression-screen-1026` | `1f6b563d` | #1039 | clean | red | Expression screen: meter, calibrate view, pickers |
| #1043 | 4f | `claude/external-controls-1026` | `1562b8e9` | #1041 | clean | red | External button Controls dispatch (On/Off, Held/Released) |
| #1044 | 4f | `claude/external-controls-panel-1026` | `fdc92b4f` | #1043 | clean | red | External button Controls panel |
| #1045 | 4f | `claude/external-row-art-1026` | `1e8ba6f0` | #1044 | clean | red | Row pictures from the Looper X factory art |
| #1047 | 4g | `claude/midi-formats-1026` | `37789aa7` | #1045 | clean | red | Program Change capture; `MidiProtocol` / `MidiSource` / `MidiDecoder` |
| #1048 | 4g | `claude/midi-mapping-engine-1026` | `280f116f` | #1047 | clean | red | Pure `MidiMapping` / `MidiMappingSet` / `MidiMappingEngine` |
| #1049 | 4g | `claude/midi-engine-wiring-1026` | `63d8d7b5` | #1048 | clean | red | `ControlCubit` runs the engine; keys `midi.mappings`, `midi.control_enabled` |
| local | 4g | `claude/midi-controls-page-1026` | `efa5a24f` (3 commits) | #1049 | no PR | no PR | MIDI controls page, editor session, 15 s Learn timeout. Body: `part-4g-midi/pr-a-body.md` |
| local | 4g | `claude/midi-old-model-removal-1026` | `3876f578` (1 commit) | page branch | no PR | no PR | Removes `ControllerRepository`, the CC 80-86 scheme, old bindings and the Control face MIDI tab; adds `command:tap-tempo`. Body: `pr-b-body.md` |

- **Where the local branches live.** They are refs in the main repository. The worktrees `/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy/1a736a10-cdfb-4daa-ad93-3176a9204d1d/scratchpad/wt-4fe` and `/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy/1a736a10-cdfb-4daa-ad93-3176a9204d1d/scratchpad/wt-4ff` share that repository, so deleting a worktree does not delete its branch.

Other PRs:
- **#1051** (click with Sync off, closes #1050) **merged into master** as `ffc96d94` after the data was saved. The saved data showed it open, `review:clean`. It changes `engine_private.h`, `engine_process.c` and `test_engine_core.c`, with one conflict hunk against the chain tip.
- **#1023** is a dependabot PR (lucide_icons_flutter 3.1.19) against master.
- **#1042** is enclosure work (#1037) based on `claude/sheet-metal-enclosure-analysis-6c2aa4`. #1038 is closed.

**Why CI is red**

- **No CI runs on stacked PRs.** `.github/workflows/main.yaml` triggers on `pull_request: branches: [master]`. A PR based on another branch gets no Actions run; only GitGuardian reports. `gh pr checks` then shows no checks, which means CI was absent, not that it passed.
  - The rule is to label such PRs `ci:red`, never `ci:green`, and say so in the body (`loopy-stacked-pr-squash-merge-landmines.md` item 1; bodies of #1013 to #1018).
  - So `ci:red` from #1013 down means "CI has not run", not "CI failed".
- **#1011 is the only PR based on master.** It is `ci:green`, `review:clean` and `ready-to-merge`. It is also `autonomy:merge-gate`, so only the owner merges it.
  - No PR below it gets CI until #1011 merges and #1013 is retargeted to master. The 4g handoff calls this "the #1011 gate".
- **Local checks instead.** Each PR body lists the checks run locally in place of CI.

**master has moved since the chain was cut** (checked again at 2026-09-15 10:22 -0300; no PR, issue or note mentions it)

`origin/master` is nine commits past `aa4f13df`:

| Commit | Change |
|---|---|
| `d30802cb` | README |
| `7adc0d1a` | #984, "replace USB pedal with UART console link" (closes #983) |
| `5645b098` | #986, "make CTRL pedals bindable controls" (closes #985) |
| `1de1050f` | #990, "ship and update matching console firmware" (closes #989) |
| `eb401937` | #977, carry tryboot through the staged update reboot |
| `ffc96d94` | #1051, align sync-off clicks to the existing loop (closes #1050) |
| `809da568` | #982, gate startup and inspect release bundles |
| `a77aaa97` | #1053, install squashfs tools for appliance inspection |
| `848f1337` | #1055, inspect appliance bundles with pinned Yocto tools |

Someone is merging to master now: fetch again before any landing work.

What a trial with `git merge-tree --write-tree` shows (nothing was resolved or tested):
- **#1011 no longer merges cleanly.**
  - Content conflicts: `lib/app/view/app.dart`, `test/app/view/app_test.dart`, `test/looper/view/track_meters_test.dart`.
  - The agent that wrote this section also reported modify/delete conflicts. #1011 deletes `lib/looper/view/stage_status_bar.dart`, `lib/visualizer/console_volume_overlay.dart`, `lib/visualizer/readout_control.dart` and their tests, while master changed them. Check this on the integration branch.
  - Its `ci:green` and `ready-to-merge` were earned against `aa4f13df`. Updating the branch is a push, and a push invalidates the earlier review (AGENTS.md).
- **#984 deletes the pedal protocol that slice 4 extends.**
  - Deleted: `firmware/segno_pedal/pedal_protocol.{c,h}`, `segno_pedal.ino`, `hardware/firmware/segno_pedal_32u4/*`, `firmware/test/test_pedal_protocol.c`, `packages/pedal_repository/lib/src/pedal_codec.dart`, `pedal_protocol_traffic.dart` (home of `isPedalProtocolInput`), `native_pedal_transport.dart`.
  - Added: `firmware/console_board/` and a `pedal_link` codec (`pedal_link.{c,h}`, `firmware/test/test_pedal_link.c`).
  - Written against the deleted files: #1029, #1030, #1031, #1032, #1036, #1039 and #1047.
- **#986 builds a second model for the CTRL jacks.**
  - It routes switches and expression calibration through `ControllerRepository`, using `lib/pedal/console_ctrl_source.dart`, `packages/pedal_repository/lib/src/pedal_ctrl.dart` and calibration persistence in `PedalCubit`.
  - It renames `midi_tray_body.dart` to `controllers_tray_body.dart`.
  - Part 4f (#1035 to #1045) built the same jacks as pedal-protocol Notes 10-13 and CCs 0x11/0x12, with `ExternalPedalPage`.
  - The local removal branch deletes `ControllerRepository`, `midi_learn_section.dart` and `control_cubit_controller_test.dart`, all of which #986 edits.
  - Keeping both models would give one value two owners, which the brief forbids. No source records which model survives. This needs the owner.
- **The chain tip conflicts with `origin/master` in 54 files.** The tip is `claude/midi-old-model-removal-1026`. A single slice 4 branch such as `claude/pedal-protocol-v4-763` conflicts in 22.

**Known CI risks once CI runs (not verified)**

- **Analyzer infos.** `packages/looper_repository/test/models/fx_chain_group_test.dart` has ten analyzer infos, added by `87684b29` in #1024 (noted in the #1044 body and `pr-a-body.md`). #1011's first CI run failed on package analyzer infos, so expect the build job to fail from #1024 down until these are cleared.
- **Linux-only code.** #1047's ALSA `PGMCHANGE` case is compiled only by CI's Linux job.

**Landing procedure for a human**

This is based on `loopy-stacked-pr-squash-merge-landmines.md`, AGENTS.md and `docs/TRACKING.md`. No source records a decision to merge the chain into fewer PRs.

1. **Restore GitHub access and open the last two PRs.**
   - The owner runs `gh auth login`.
   - Push both local branches with the credential override in (e).
   - Open PR A (base `claude/midi-engine-wiring-1026`) and PR B (base `claude/midi-controls-page-1026`) using the drafted bodies. Labels: `stage:in-review`, `autonomy:merge-gate`, `ci:red`, `review:pending`.
   - Run `/code-review` on both.
   - Post the 4g progress note on #1026. It has not been posted (`part-4g-midi/HANDOFF.md`).
2. **Get the owner's direction on #984/#986** before rebasing anything from #1029 down.
3. **Build a throwaway integration branch.**
   - Fetch again and merge the whole chain onto current master. Resolve conflicts once.
   - Run the native suites and their variants, the fuzz suite, the firmware suite, every package suite and the root suite there.
   - Reuse the resolved files for each per-branch update, and compare each PR's final tree with the integration tree.
4. **Update #1011 and have it merged.**
   - Update it onto current master and push.
   - Set its labels back to `ci:red` / `review:pending` until CI and `/code-review` pass on the new head.
   - Then add `ready-to-merge`. The owner squash-merges.
5. **Retarget each child before merging its parent.**
   - Retarget with `gh pr edit <child> --base master`.
   - Never delete a parent branch while a child still bases on it: GitHub closes the child.
   - After any retarget, check the parent's `state` again (#571 was found closed right after its child was retargeted).
6. **Move each child onto master after its parent squash-merges.**
   - Use `git rebase --onto master <old-parent-tip> <child>`. For #1013: `git rebase --onto master ec3e25f0 claude/segno-slice2-edits-1012`.
   - A plain `git rebase master` re-applies the parent's diff and conflicts on binary files. The chain carries 120 goldens and the `fx_catalogue` images.
   - Push. The `synchronize` event starts CI; closing and reopening the PR does not do so reliably.
7. **Check `state` before any force-push.** Force-pushing the branch of a closed PR makes that PR impossible to reopen. Never close a PR to refresh its mergeability.
8. **Check scope after each update.**
   - `git diff --name-only origin/master HEAD` must equal the PR's own file list.
   - For deletions, compare with the child's own parent tip (`git diff --diff-filter=D <parent-tip> <child-tip>`), not with master.
9. **Check commit subjects.** A single-commit PR squashes to its commit subject, not its title, so the subject needs a conventional prefix (`loopy-ci-check-before-commit.md`).
10. **Repeat steps 5 to 9 down the chain.** Each PR ends with a human merge after `ci:green` and `review:clean`.
11. **Land the pen separately.** The pen write-backs exist only in the owner's uncommitted `segno-ui.pen` (see (b)). Landing them is a separate `chore(design):` PR (`loopy-deviation-updates-the-pen.md`). The file also carries other owner edits, so this is the owner's call.

### (b) Tracking contract as applied

The contract is in `docs/TRACKING.md` and the "Tracking and review" section of AGENTS.md.

Labels used:
- `stage:in-review`, `stage:build`, `stage:brainstorm`
- `autonomy:merge-gate`, `autonomy:plan-gate`
- `ci:red`, `ci:green`, `review:pending`, `review:clean`, `ready-to-merge`
- `epic`, `area:console`, `area:engine`, `area:design`, `area:fx`, `area:pedal`

| Issue | Role | Labels (06:38) | Checklist |
|---|---|---|---|
| #1009 | epic | `stage:build`, `autonomy:merge-gate`, `epic` | slices 1-3 ticked, 4-7 open |
| #1010 | slice 1 | `stage:in-review`, `autonomy:merge-gate` | none |
| #1012 | slice 2 | `stage:in-review`, `autonomy:merge-gate` | 2a-2c ticked |
| #1016 | slice 3 | `stage:in-review`, `autonomy:merge-gate` | 3a-3f ticked |
| #1026 | slice 4 | `stage:in-review`, `autonomy:merge-gate` | 4a-4f ticked, 4g-4n open |
| #763 | custom mode + protocol v4 | `stage:in-review`, `autonomy:plan-gate` | direction approved 2026-08-26 |
| #1033 | footswitch art | `stage:in-review`, `autonomy:merge-gate` | none |
| #1040 | single MIDI input | `stage:brainstorm`, `autonomy:plan-gate` | awaiting owner call |

- **Merge gate.** #1009 says: "UX taste on the result is the owner's call, so slices are `autonomy:merge-gate`." The agent builds, gets both checks green and stops; the owner merges. No PR in this programme is `autonomy:auto`, so the agent merges nothing.
- **`ready-to-merge` rule.** It needs `ci:green` and `review:clean` on the current head. `review:clean` is set only after a complete `/code-review` of that head with no unresolved findings, and any push invalidates it (AGENTS.md). Only #1011 ever reached `ready-to-merge`.
- **Review practice.** Each PR body records its review rounds (several finder angles plus verifiers, sometimes an adversarial skeptic). Every behaviour claim is mutation-checked: revert the fix and confirm the test fails.
- **Stale labels.** Labels were not always updated after later fix rounds. #1013 and #1014 still say `review:pending`, but the confirmed findings of the 2026-09-10 round are fixed in their current tips `6cdfb9fb` and `42c4d079` (`loopy-segno-slice2-edits.md`). No source records a full review of those heads afterwards. No clean review is recorded for #1020, #1021, #1022, #1024 or #1027 to #1031.
- **Issue links.** TRACKING.md requires `Closes #N`. Each slice issue spans several PRs, so most bodies say `Part of #N` instead.
  - Closing lines that exist: `Closes #1010` in #1011's commit message (not its body); "Closes #1012 with #1013 and #1014" in #1015; "Closes #1016 part 3f" in #1024; `Closes #1033` in #1034; `Closes #1050` in #1051.
  - Nothing closes #1026, #763 or #1009.
  - GitHub acts on these lines only when a PR merges into master.
- **Progress notes on issues.**
  - #1016: three comments on 2026-09-10 (the 3d split, the whole-track Pre question, the whole-track Pre built) and two on 2026-09-11 (3f progress with two decisions, the catalogue module table).
  - #1026: four comments on 2026-09-12 (4e, 4f plan, expression wire with #1040 filed, expression screen) and three on 2026-09-13 (4f complete, row pictures decided, 4g plan).
  - #763: one on 2026-09-10 and four on 2026-09-11.
  - Not posted: the 4g page and removal note, including its departures from the pen.
- **Implementation ledger.** The brief requires a durable ledger. `docs/plan/2026-09-09-segno-implementation-ledger.md` is tracked in the chain, but it was last changed by `b89342e2` (#1027, part 4b). Parts 4c to 4g are recorded only in PR bodies, #1026 comments, memory notes and the untracked 4g handoff.
- **Pen write-backs.** Departures were recorded as `c/` notes in the owner's working copy of `segno-ui.pen`:
  - slice 1: `c/ Implementation · slice 1`, node `B9Qoq4`, section 25
  - 2c: note `OaX2R`, section `EYla4`
  - 3f: `c/signal-domain-retired`
  - 4c: `c/ Implementation · slice 4c`, section `08 Pedal setup & LEDs`

  No branch in the chain changes the pen. The working copy's blob is `18506780`; master's is `d3b4eb47`. For the departures in 3d, 4f and 4g, no source says they were written into the pen.

### (c) Progress against the brief

**Order.** The brief's order (`IMPLEMENTATION_PROMPT.md` "Execution", `implementation-map.md` "Dependency-ordered vertical slices") is:
1. Tracks and both displays
2. history and timing
3. routing and FX
4. controls and foot performance
5. library, sessions, backing and recovery
6. MIDI, sync and instruments
7. device and appliance

The prompt's prose names instruments before media, while the map and #1009 put media (5) before instruments (6). The prompt calls its sequence "a starting plan". Below, "built" means code on a branch with local checks. Nothing is merged, and nothing is verified on hardware.

| Slice / part | State | Where |
|---|---|---|
| 1 Main Tracks journey | built; was ready-to-merge before master moved | #1011 |
| 2a-2c | built | #1013, #1014, #1015 |
| 3a-3f | built (the 3d foot Mixer moved to 4n) | #1017, #1018, #1020, #1021, #1022, #1024 |
| 4a-4f | built | #1027 to #1045 (with #1034 for #1033) |
| 4g MIDI Learn formats | **in progress**: 3 PRs pushed; page and removal committed locally, not pushed; #1026 note and memory update not done | #1047, #1048, #1049, two local branches |
| 4h Reverse | not started | |
| 4i Speed | not started | |
| 4j Fade | not started | |
| 4k Transpose | not started | |
| 4l Multiply / Divide | not started | |
| 4m Bounce / Peel | not started | |
| 4n foot Mixer, performance feedback, touch lock, double-press Solo | not started | |
| 5 Library, sessions, backing, durable recovery | not started | |
| 6 MIDI, external sync, instruments | not started | |
| 7 Device and appliance completion | not started | |

**Remaining slice 4 parts.** #1026 records that eight of the ten performance operations have no engine path: Reverse, Speed, Fade, Transpose, Multiply, Divide, Bounce and foot Mixer level. Peel exists inside `le_engine_undo`. The offline restore worker is named as the place destructive edits should hook in. The action catalogue already declares the empty headings, so each part adds its `ControlAction` entries along with its engine operation (`loopy-segno-slice4-controls.md`).

**Slices 5 to 7, as `implementation-map.md` defines them.**
- **5.** Extend the session and performance repositories rather than adding a second save system. Scope: musical versus appliance ownership, New Loop preservation, audio import and export, prepared-list reorder, seek and end, backup and repair transactions, and USB identity across reconnect. Failed writes must leave the rig and the saved session untouched.
- **6.** Native instrument voices as routable inputs. Scope: MIDI ports, channels and ranges (0-127), layered instruments, remaps and chords, sustain, held and latch, audition isolation, and clock loss, transport follow and reconnect. MIDI Sync, the tab missing from the 4g page, has not been built yet.
- **7.** Accepted screens over the existing audio, network, brightness, storage, update and power services. Scope: automatic-first latency measurement with a fallback, per-display calibration, touch lock (also listed in 4n), USB capture limits, safe shutdown, and verified update and restore.

**Gaps carried from built parts**
- **From #1011.** No CPU readout: nothing owns live engine load.
- **Crown handoff UI.** #1011 deferred it to slice 2, and no slice 2 body mentions building it.
- **#1010 out-of-scope items.** Load-audio, the MIDI sync pill, first-take tempo review and the Sync/Band successor rule on clearing a primary. Their later status is not recorded.
- **From #1015.** The Audio & tempo page is only a readout, because tempo following is not built. Encoder focus rectangles are not built.
- **From #1041 and #1026.** Double-tap reset and encoder editing of values are not built, and no shared model exists for them.
- **From #1020 and #1021.** No backing player exists; "Backing & click" routes the click only. The Signal face's per-jack output gate is kept until there is a design answer.
- **From #1018.** The Follow-output capture preference has no setting or screen.
- **Offline render (#1017, #1018).** It ignores pan, bus Mono, balance and bus chains.
- **From #1022.** The engine has no Speed, Reverse, pitch preservation or Follow tempo.
- **From #1024.** 20 of the 26 catalogue modules pass audio through unprocessed. There is no rack-level bypass bit, preset Import/Export controls do nothing, and My presets has no artwork.
- **Parity rows still open (`reference-gates.md`).** 239 control domains, 300 reset defaults and 26 Single FX schemas.
- **From #1039.** Expression position has 7-bit resolution.
- **4g page departures (`pr-a-body.md`).**
  - Entry is a row on the Control face.
  - A crumb replaces the Controls / Sync tabs.
  - Device cards show status without USB/DIN.
  - Performance actions open the shared picker.
  - Values are shown as a percentage.
  - Pan and balance are not parameter targets.
  - No held-instrument rule.
- **Hardware.** Nothing physical is verified: displays, touch, footswitches, LEDs, CTRL jacks, audio levels and timing.

### (d) Owner decisions and open questions

**Decisions (do not reopen)**

| Date | Decision | Source |
|---|---|---|
| 2026-08-26 | #763 direction. D1: custom bindings cover FX targets plus named app actions (rack targets wait for #535). D2: zero-growth v4 wire. D3: manual firmware version picker. D4: custom joins the MODE cycle, boot-excluded. D4's cycle was later replaced by the accepted MODE Press/Hold pair (#1028, #1030); custom joins the keyboard `M` cycle. D3 has no UI (`selectFirmwareVersion` has no caller). | #763 comments |
| 2026-08-28 | The product is an appliance only; macOS stays as an unsupported development host | `loopy-appliance-only-decision.md` |
| 2026-09-10 | Keep the whole-track Pre switch, implemented as a non-destructive rendered copy that renders only while every part's chain is entirely Pre | #1016 comments, #1022, `docs/design/2026-09-10-whole-track-pre-render.md` |
| 2026-09-11 | The Looper X factory catalogue ships (159 presets, 66 images) | #1016 comment, #1024 |
| 2026-09-11 | Raise the engine chain ceiling before building racks | #1016 comment, #1024 |
| 2026-09-11 | Drop the hosted-plugin browser with the Signal tray; plugin hosting stays in the engine and repository | #1024 "Decisions taken", `loopy-segno-slice3f-fx-surfaces.md` |
| 2026-09-11 | Widen v4 with 30 RGB bytes per footswitch instead of adding a v5 | #763 comment |
| 2026-09-13 | Row pictures use the Looper X factory images for now; never generate artwork | #1026 comment, `loopy-looperx-art-for-rows.md` |
| standing | No backward compatibility: remove obsolete paths, no compatibility layers or migrations | AGENTS.md |
| standing | No reserved MIDI CC command scheme; a controller does nothing until mapped | `part-4g-midi/HANDOFF.md` section 1 |
| standing | Independent DSP and sound are allowed; racks, effects and parameters must match | `reference-gates.md` |

**How the no-compatibility rule was applied**
- #1015: a stored `tempo.length_preset.N` of 0 now reads as an explicit Auto.
- #1018: `le_engine_set_master_fx*` and ring codes 51 and 52 were deleted.
- #1024: an old `master` FX binding decodes to null.
- Removal branch: the old `controller.mappings` blob is no longer read.
- One exception remains: #1014's first-read migration from `track_quantize.N` to `track_record_timing.N`. `_trackQuantizeKey` is still in `settings_repository.dart` at the chain tip, and no source revisits it.

**Open questions and blocked items**

| Item | What is needed | Source |
|---|---|---|
| #984 / #986 against slice 4 | Owner direction on which pedal protocol and which CTRL jack model survive | git; not in any source (see (a)) |
| #1011 | Update onto current master, re-run checks, owner merge | (a) |
| #1040 | Product call: a third-party MIDI controller alongside the console board, or instead of it. The issue's premise was that pedal traffic shares the one open MIDI input; #984 removes the USB-MIDI pedal transport, and nobody has re-checked the premise since. | #1040, #1026 comment 2026-09-12 |
| LED recording hue | Whether a live take keeps its own hue over the palette colour (a one-line precedence rule). Better decided before a unit is flashed. The owner was told and has not ruled. | #1032, #1026 comment 2026-09-12, `loopy-segno-slice4-controls.md` |
| #763 | Still open. Pico 2 firmware must implement its own mode colour and `indicatorFor`, which the drift check in `firmware/test/run_tests.sh` cannot cover. How #984 affects this is not recorded. | #763 comments, #1029 |
| #1033 | Closes when #1034 merges | #1034 |
| Untracked `docs/design` (377 entries, 226 MB) | Owner call on what to commit; not yet asked | #1034, `loopy-design-studies-untracked.md` |
| Signal face per-jack output gate | Design answer | #1020 |
| Double-tap reset and encoder editing | Its own issue when encoder work starts; none filed | #1041 |
| 7-bit expression | Bench check; if the sweep visibly steps, use a 14-bit pair on the wire | #1039 |
| Who owns MIDI mappings | Default is app settings. Record that the session-recall slice moves pedal actions, expression ranges and MIDI mappings together. | `part-4g-midi/HANDOFF.md` section 5 item 4 |
| #1046 | Segno owning interface routing. The Scarlett 4i4's internal matrix fed the headphones from PCM 1-2. | `loopy-scarlett-internal-routing.md` (not in the saved issue data) |
| #1050 / #1051 | Merged into master as `ffc96d94` (2026-09-15). What remains: an ear check on the appliance, and its conflict hunk when the chain is updated onto master. | #1051, git |
| #1019 | Enclosure base plate. The fix is on `claude/sheet-metal-enclosure-analysis-6c2aa4`. Do not send the package to Dinacut without the owner's go-ahead. Outside this epic. | `loopy-console-shell-load-hold.md` |
| Pen commit | The owner's uncommitted pen carries the write-backs | (b) |
| GitHub auth | The owner runs `gh auth login` | `part-4g-midi/HANDOFF.md` |

### (e) Working rules and gotchas

**Commands**

| Purpose | Command | Source |
|---|---|---|
| Dart tests | `/Users/Tomas/development/flutter/bin/flutter test`. A bare `flutter test` / `dart test` is hook-blocked; the very_good MCP test tool exits 69. | `loopy-test-runner-gotcha.md`, AGENTS.md |
| Native tests | `bash packages/segno_engine/src/test/run_native_tests.sh`, then with `EXTRA_CFLAGS="-fsanitize=address -g"` and with `EXTRA_CFLAGS="-DLE_CALLBACK_TELEMETRY=0"` | `docs/PROGRESS.md` |
| C++ shim check after a core header change | `clang++ -std=c++17 -U__clang__` on a file that includes `engine_fx.h` inside `extern "C"` (full recipe in `docs/PROGRESS.md`) | `loopy-engine-header-cpp-shim.md` |
| FFI-backed Dart tests | `export SEGNO_ENGINE_LIB="$(bash packages/segno_engine/tool/build_test_lib.sh)"`, then `flutter test --tags fuzz`. Without the library, FFI-gated tests skip silently (at 3b: 306/475/2246 tests with it, 274/464/2217 without). | `loopy-segno-slice3-mix-fx.md` |
| Firmware | `bash firmware/test/run_tests.sh` (built with sanitizers since #1031; master's #984 rewrote it) | AGENTS.md, #1031 |
| ffigen | In `packages/segno_engine`: `dart run ffigen --config ffigen.yaml`, then `dart format lib/src/generated/segno_engine_bindings.dart`. ffigen emits short style. The note still names the old `loopy_engine` paths. | `loopy-ffigen-format-drift.md` |
| FFI symbol parity | `packages/segno_engine/tool/check_ffi_symbols.sh <lib>` | `implementation-map.md` |
| Analyzer | `dart analyze --fatal-infos` at the root and inside every touched package (CI runs it per package) | `loopy-segno-implementation-slice1.md` |
| Bloc lint | `~/.pub-cache/bin/bloc lint lib test packages`. Confirm the file count: under `.claude/worktrees/` it prints "No files found" and exits 64, so work in a worktree outside ignored paths. | `loopy-worktree-gitignore-lint-noop.md` |
| Package suites | Run every package suite. A cross-package removal once left the `performance_repository` and `settings_repository` suites uncompilable, and the root run did not show it. | `loopy-segno-slice3f-fx-surfaces.md` |
| cspell and PR title | CI spell-checks `**/*.md` only, and local `@latest` cspell is only a pre-filter. PR titles need a conventional prefix. | `loopy-ci-check-before-commit.md` |

**Git and publishing**
- **Commit from a git worktree, never the main checkout.** The main checkout holds the owner's uncommitted work, and `git add` there can pick up another session's edits (`loopy-shared-worktree-commit-race.md`).
- **Create the new branch before committing a new part.** Run `git branch --show-current` first. Committing onto the previous PR's branch happened twice; #1039 and #1043 each needed a reset and force-push (`loopy-segno-slice4-controls.md`).
- **Revert analysis options before staging.** Run `git checkout -- packages/*/analysis_options.yaml` right before `git add -A`, because a package `flutter test` rewrites it. One slipped into `ab914391` and was reverted in `ec3e25f0` (`loopy-segno-implementation-slice1.md`, `part-4g-midi/HANDOFF.md`).
- **Push through the gh credential helper.** Use `git -c credential.helper= -c credential.helper='!gh auth git-credential' push ...`; plain `git push` hangs on the keychain.
- **Check for local-only work first.** Before starting an issue that looks unstarted, run `git ls-remote --heads origin <branch>` (`loopy-git-push-keychain-hang.md`).
- **No emojis and no attribution lines** in commits, PR bodies or issue comments (AGENTS.md, `part-4g-midi/HANDOFF.md` section 1).

**Formatting**
- **`dart format` in a fresh worktree.** Run `flutter pub get` first (and `flutter gen-l10n` if l10n changed).
  - Never run `dart format .` at the root; format only the directories you touched. A diff of about 200 files is this bug.
  - Discard `pubspec.lock` rewrites.
  - Shell edits bypass the format hook.
  - `dart format` does not rewrap comments, so run `dart analyze` after formatting.

  Sources: `loopy-dart-format-worktree-trap.md`, AGENTS.md.
- **ARB files contain duplicate keys.** Edit them as text; never round-trip them through JSON (`loopy-segno-slice4g-midi.md`).

**Bloc lint rules**
- **Public cubit methods return `void` / `Future<void>`.** Bloc lint also refuses getters that return values, so the page reads cubit state after the call (`loopy-segno-slice4g-midi.md`, `loopy-worktree-gitignore-lint-noop.md`).
- **No `ValueListenable` getter on a cubit.** `avoid_flutter_imports` refuses it; read `PedalRepository.lastFrame` instead (`loopy-segno-slice4-controls.md`).

**Tests**
- **Goldens run only on the author's machine.** They use `skip: !hasScreenshotFonts`, and CI skips them.
  - Before `--update-goldens`, compare `flutter --version` with `flutter_version` in `main.yaml`. Master now pins `3.47.x`; the note's 3.44.x is stale.
  - Regenerate and look at every PNG after a UI change.
  - Use `--exclude-tags screenshots` when judging an unrelated failure.

  Source: `loopy-screenshot-goldens-author-only.md`.
- **Icons in goldens** need the lucide font loaded through `test/helpers/screenshot_fonts.dart` (`loopy-segno-slice2-edits.md`).
- **Artwork in goldens** needs `tester.runAsync(() => precacheImage(...))`, because pumps use fake async (`loopy-segno-slice3f-fx-surfaces.md`, `part-4g-midi/HANDOFF.md`).
- **Stream cancel hang.** An inline `await sub.cancel()` inside `testWidgets` hangs. Use `unawaited(...)` or `addTearDown` (flutter/flutter#139870; `loopy-testwidgets-stream-cancel-hang.md`).
- **Stored futures in `runAsync`.** A cubit method that chains on a stored future hangs inside `tester.runAsync` (`loopy-segno-slice4g-midi.md`).
- **Two pumps for a bloc push.** With `whenListen`, one pump delivers the event and the second rebuilds. A test that passes with one pump may pass for the wrong reason (`loopy-widget-test-bloc-push-two-pumps.md`). Two pumps do not rebuild a const stage (`loopy-segno-implementation-slice1.md`).
- **Test window size.** Tests run at 800x600 while the pen is 1920x1080.
  - Wrap pen-sized rows in `ShrinkToWidth`, never a `Spacer` inside a `FittedBox`.
  - `ConstrainedBox` cannot be const.
  - Test one case at 1920x1080.

  Source: `loopy-widget-test-window-size.md`.
- **Mutation-check every new test** by reverting the fix it claims to pin. In 3b, four tests passed against their reverted fix (`loopy-segno-slice3-mix-fx.md`).
- **Engine interface changes.** Update the four fake `AudioEngine`s (in the `looper_repository`, `performance_repository` and `session_repository` test helpers, and root `test/helpers`). `EngineSnapshot.copyWith` is pinned by two source-level goldens (`loopy-segno-slice3-mix-fx.md`).
- **`chainEntriesAt` is an extension method.** Stubbing it with `when(...)` stubs the wrong member (`loopy-segno-slice3f-fx-surfaces.md`).
- **Mocked `MidiDeviceRepository`.** It must stub `messages`, `connections`, `activity` and `connection` (`part-4g-midi/HANDOFF.md` section 11).

**Pen and design sources**
- **Reading the pen.** `segno-ui.pen` is the design source. Read it only through the pencil MCP (`execute` with `filePath` and `input`, then `Get` / `Print`), never with Read or Grep. The MCP elides path geometry as `"..."` (#1033; `loopy-pen-is-the-design-source.md`, `loopy-pen-mcp-and-app-driving.md`).
- **Coordinate frames.** Each screen is a 1920x1152 tile: the screen frame starts at tile y=72 and the main area at y=168. `LoopSettingsFrame` children use main-local coordinates (tile y minus 168). A 96 px offset error shipped once in 3c (`loopy-pen-coordinate-frames.md`).
- **Saving the pen.** Pencil does not autosave MCP edits.
  - Save by clicking File > Save in the Pen app menu with computer-use; a Cmd+S key event does not register.
  - Verify with `git hash-object segno-ui.pen` against `git rev-parse HEAD:segno-ui.pen`. `git status` does not show the change, but `git add -A` stages it.
  - A branch checkout discards a saved but uncommitted pen.
  - `get_screenshot` renders the saved file, not unsaved edits.

  Source: `loopy-pen-save-invisible-to-git-status.md`.
- **Deviations go back into the pen.** Any shipped departure is a design change: update the geometry and the `c/` note as part of finishing the work, and land it as its own `chore(design):` PR (`loopy-deviation-updates-the-pen.md`).
- **Untracked design docs.** `docs/design` (377 entries, 226 MB) and `docs/handoff` are untracked in the main checkout, and worktrees cannot see them. Read them from the main checkout and commit only the specific files an implementation reads (`loopy-design-studies-untracked.md`).

**Other code traps**
- **Wire codes in C enums.** `LE_PLOG_*` values cross a file boundary and duplicates compile silently. Pick the next free number and add it to `test_plog_codes_are_distinct` (`loopy-c-enum-wire-code-collision.md`).
- **Pedal frames.** A widget must not re-project a pedal frame; read `PedalRepository.lastFrame` (`loopy-segno-slice4-controls.md`).
- **Tray rail rows.** A ninth row does not fit. A new `TrayRailEntry` route row must update `_routeGlyph`, `_routeLabel` and `_openRoute` (`loopy-segno-slice4-controls.md`, `part-4g-midi/HANDOFF.md`).
- **Widget details.**
  - `LoopOutlinedButton.icon` replaces the label; `leadingIcon` goes in front of it.
  - A `FractionallySizedBox` meter fill needs `heightFactor: 1`.

  Source: `loopy-segno-slice4-controls.md`.
- **`Object.hash`** accepts at most 20 arguments; use `Object.hashAll` (`loopy-segno-slice2-edits.md`).


## 2. Slices 1 and 2: Tracks view, crown, reversible edits, timing and Loop settings (epic #1009; issues #1010, #1012)

### Epic #1009 brief as it applies to slices 1 and 2

- **The epic.** #1009 is open, labelled `stage:build`, `autonomy:merge-gate`, `epic`. It builds the accepted Segno design (design work under #919) one slice at a time, and the app must keep working after each slice. The epic has slices 1-3 ticked. The owner judges UX taste, so every slice PR is `autonomy:merge-gate` and the owner does the merge.
- **The brief exists only as untracked files in the main checkout**, under `docs/handoff/segno-app/`:
  - `IMPLEMENTATION_PROMPT.md`, `implementation-map.md`, `delivery-checklist.md`.
  - `accepted-behavior.md`: sections 1 and 2 are the contract for these slices.
  - `reference-gates.md`: FX parity only, not relevant here.
  - Check the pack with `python3 docs/handoff/segno-app/verify_handoff.py`.
- **Brief rules that shaped this work:**
  - The latest owner correction wins. Settled choices are not reopened. Current native code is evidence of what exists, not a limit on what gets built.
  - Each value has one owner, along presentation -> Bloc/Cubit -> repository -> `AudioEngine`.
  - Native API changes and the ffigen bindings are updated together. The audio callback does no allocation, I/O or locking.
  - When a replacement works, the old path is removed. No compatibility layers and no second state owner.
  - Real, measured state only. A capability that does not exist stays unavailable and says why. This is why there is no CPU readout and why Audio & tempo is a readout.
  - Keep a durable ledger. It is `docs/plan/2026-09-09-segno-implementation-ledger.md`, tracked on the branches, with one section per part.
  - Any departure from `segno-ui.pen` is written back into the pen.
- **Slice 1 acceptance (from the map):**
  - Record Track 3, then Track 1: the crown stays on 3.
  - Selection and Bank change neither playback nor the crown.
  - Queued actions stay on their own track, and Mute stays on the columns.
  - Reload is correct.
  - Evidence required: widget/Bloc tests, native crown tests, desktop playback, both real displays. Keep meter rebuilds isolated and measure frame timing.
- **Slice 2 acceptance (from the map):**
  - A one-bar partial take recovered inside an established four-bar Multi loop keeps three silent bars, and the mode does not change.
  - Redo of the defining take plays immediately. Cancel changes nothing.
  - Undo of Clear All restores the grouped audio, timing and previous playback state. It keeps Mixer/FX edits made later, and brings interrupted captures back stopped.
  - Evidence required: frame-level tests, full pedal sequences, session round trips. Timing and latency need hardware proof.
- **Gates (map and #1012):**
  - `bash packages/segno_engine/src/test/run_native_tests.sh`, run plain, with `-fsanitize=address` and with `-DLE_CALLBACK_TELEMETRY=0`.
  - After an API edit, `dart run ffigen` then `dart format` on the bindings.
  - Coverage floors from `.github/workflows/main.yaml`: root 90%, looper_repository 95%, session 89%, performance 99%.
  - `dart analyze` inside each touched package, `bloc lint lib test packages`, cspell.
  - `/code-review` clean and CI green before `ready-to-merge`.
- **Design records these parts cite, all untracked in the main checkout:**
  - `docs/design/2026-09-09-primary-crown.md`
  - `docs/design/2026-09-07-stage-display-roles-ux.md`
  - `docs/design/2026-09-07-loop-mode-transitions-ux.md`
  - `docs/design/2026-09-06-loop-setup-ux.md`
  - `docs/design/2026-09-08-capture-recovery-ux.md`
  - `docs/design/2026-09-09-timing-completion.md`
  - `docs/brainstorm/2026-09-07-undo-redo-brainstorm-doc.md`
- **No owner comments.** The saved export has no comments on #1009, #1010 or #1012. The decisions below are the implementer's, recorded in the PR bodies and the ledger with citations to the design records.

### Stack state

| Part | PR | Branch -> base | Labels (as saved) | Tip | Size |
| --- | --- | --- | --- | --- | --- |
| 1 | #1011 | `claude/segno-app-implementation-7c90a8` -> `master` | stage:in-review, autonomy:merge-gate, ci:green, review:clean, ready-to-merge, area:console, area:engine, area:design | `ec3e25f0` | 118 files, +5113/-7276 |
| 2a | #1013 | `claude/segno-slice2-edits-1012` -> slice 1 branch | stage:in-review, autonomy:merge-gate, ci:red, review:pending, area:console, area:engine | `6cdfb9fb` | 34 files, +3244/-497 |
| 2b | #1014 | `claude/segno-slice2b-timing-1012` -> 2a branch | same as 2a | `42c4d079` | 55 files, +2467/-211 |
| 2c | #1015 | `claude/segno-slice2c-loop-settings-1012` -> 2b branch | stage:in-review, autonomy:merge-gate, ci:red, review:clean, area:console | `839cb330` | 134 files, +6988/-5851 |

- **Branch state.** All four PRs are open, and each local branch matches `origin`. Every tip is an ancestor of the later stack branches and of the local tip `claude/midi-old-model-removal-1026` (`3876f578`).
- **What `ci:red` means on 2a-2c.** No CI ran on them. `main.yaml` only runs for PRs into `master`, so a PR based on a feature branch gets only GitGuardian. The checks listed below were run locally.
- **Base and master drift.** The stack base is `aa4f13df` (#905). At the 2026-09-15 fetch, `origin/master` was three commits ahead, touching 287 files:
  - `d30802cb` (README), `7adc0d1a` (#984, UART console link), `5645b098` (#986, CTRL pedals bindable).
  - They change files these parts also change: `lib/app/view/app.dart`, both arb files, `lib/control/cubit/control_cubit.dart`, `packages/settings_repository/lib/src/settings_repository.dart`, `lib/audio_setup/view/audio_settings_section.dart`, `docs/PROGRESS.md`, `.github/cspell.json`, and several tests. #1011 needs master merged in, or a rebase, before it can land.
- **Issues.** #1010 and #1012 are open at `stage:in-review`. #1011 carries `Closes #1010`. #1015's body says it closes #1012 together with #1013 and #1014.

### Slice 1: Tracks view, selected-track display, first-take crown

**PR #1011** · `claude/segno-app-implementation-7c90a8` -> `master` · open · review:clean, ci:green, ready-to-merge · issue #1010. Commits: `37a245eb` (feature); `533d8585`, `8986bc05`, `ab914391` (review rounds 1-3); `ec3e25f0` (reverts a tooling side effect).

**What it built**

Main display (`lib/looper/view/`):
- **`TracksView`** (`tracks_view.dart`) is the accepted stage. `TrackColumn` (`track_column.dart`) draws four columns for the active bank. Each column has:
  - the name with `PrimaryCrown`;
  - number · bars · layers · FX marker. Bars show `—` until a tempo grid exists;
  - one whole-track meter, dB-linear over -60..0 dBFS, with a red clip cap that clears on a timer;
  - the queued-action cue inside the track, and a thin bottom progress bar.
- **Queued cue.** `queueActionOf(track, recDub:)` and `queueTimingOf(track, division)` read the engine's `pending_trigger`: 0 grid, 1 Sound start, 2 Band section toggle, -1 none. The cue names punch-out and section arms. A queued take-end reads Play, or Overdub when `TransportState.recDub` is on.
- **Shared scales and bars:**
  - `StageDbScale` (`stage_db_scale.dart`): dB scales on both sides.
  - `StageTopBar` (`stage_top_bar.dart`): Library, the performance-record light, session name, bank button, view menu, Settings.
  - `StageFooter` (`stage_footer.dart`): BPM · signature (replaced by `countingInLabel` during a count-in), elapsed time, OUT dBFS with CLIP, loop mode.
- **Views.** `StageView` in `lib/looper/cubit/tracks_state.dart` has `track` and `wave`; #1021 (3d) added `mixer`. The Wave view is `WaveTrackRow` (`wave_track_row.dart`), with a `BarRulerPainter` layer drawn over the wave (`lib/visualizer/widgets/waveform_view.dart`).
- **Narrow windows.** `ShrinkToWidth` (in `track_column.dart`) scales readout rows down when the window is narrower than the pen, instead of overflowing.
- **Removed:** `stage_status_bar.dart`, the mode pill, the bank pair, the readiness strip, the crown tap, and the TrackIndicator theme / mode pair.

Second display (7"):
- **`ConsoleReadoutView`** (`lib/visualizer/console_readout_view.dart`) follows the control cursor. It shows number, crown, name, state word, bars, and the track's own waveform with bar ruler and playhead. The footer shows tempo and function · bank.
- `lib/app/view/app.dart` pushes it through `waveform_window_service.dart` and `waveform_window_channel.dart`.
- **Removed:** `console_volume_overlay.dart`, the MIX pill, and the control back-channel `readout_control.dart`.

Crown (engine and repository):
- **`le_primary_reconcile`** (`engine_process.c`) crowns the first completed take when nothing is crowned, and clears `a_primary_track` when every track is empty.
  - It runs after every content change, including a non-defining `finalize_new_track`.
  - `le_engine_configure` drops the crown along with the tracks it empties.
  - The designation survives a clear of the primary while a sibling still holds audio (D18).
- **`resolvedPrimaryTrack(designation, tracks)`** (`looper_repository.dart`) picks the crown the screens draw: the designation if it has content, else the lowest track with content, else none.
- **`_pendingCrown`** replaces the old `_primaryTrack` re-apply cache. A crown chosen while the engine is stopped is pushed once at the next start and never re-applied after a restart.
- `le_engine_crown_primary`, `LooperRepository.crownPrimary` and `LooperCrownPrimaryPressed` are kept for the explicit timing handoff.

Snapshot:
- **New fields, added at the end of their structs:**
  - per-track `position_frames` (`le_track.a_play_pos`; the write head while RECORDING);
  - `output_peak` (`a_out_peak_bits`, the master-bus block peak after gain and limiter);
  - per-track `pending_trigger`.
- **Dart side:** `positionFrames`, `outputPeak`, `Track.pendingTrigger`, and `Track.layers` (`undoDepth + (hasContent ? 1 : 0)`). `Track.progress` reads 0 while recording.
- Bindings were regenerated. The diff also includes older ASIO doc drift the committed bindings had not picked up.

Waveform copy:
- **`LooperRepository.readTrackWaveform`** keeps one copy per track, shared by the stage row and the 7".
- **When it re-reads:**
  - on every call until the playhead has swept a full lap past a content change;
  - on every call while capturing;
  - once per lap at the wrap while the track moves;
  - never while the track is still.
- **Which lap:** the master loop in Multi, Sync and Band; the track's own loop in Free and Song.
- **When copies are dropped:** a track loses its content, or a stopped engine reports fewer tracks. A session load drops every copy.

**Decisions**
- **No CPU readout.** The pen draws `CPU 18%`, but the only source is the #722 callback telemetry, which is a whole-session mean and is kept out of the render-rate snapshot. A live load figure needs engine work. No issue is recorded.
- **The crown is a readout on every view.** The Sync/Band tappable badge is gone, and the explicit handoff UI was deferred to slice 2 (see open items).
- The mode pill and bank pair left the main bar. Function · bank moved to the 7" footer.
- **Mixer view deferred.** The engine had no pan, Solo or stereo metering. #1021 (3d) delivered it.
- **7" volume overlay retired.** Track level stayed adjustable from the Signal tray and from controllers until the Mixer existed.
- **Pen write-back.** Note `c/ Implementation · slice 1`, node `B9Qoq4`, section 25 (`I400Yi`). It was saved through Pen File > Save into the main checkout's uncommitted `segno-ui.pen` and is not on any branch.
- **Accepted as is (review round 3):**
  - A rec/dub take-end on a track whose mute was deferred during the take lands playing, because no pending-mute fact reaches the UI.
  - Wrap detection needs a read at least every half lap.
  - `Track.pending` and `Track.pendingTrigger` are two fields for one fact.
  - The overdub punch-out boundary rule (D8) is named in the view, not published by the engine.

**Verification**
- **Native tests** in `packages/segno_engine/src/test/test_engine_core.c`, all 5 suites passing:
  - `test_first_completed_take_is_crowned`, `test_explicit_crown_is_the_handoff`
  - `test_clearing_the_last_take_uncrowns`, `test_crown_persists_through_clear_with_a_sibling`
  - `test_undo_to_empty_uncrowns_and_redo_recrowns`, `test_clear_restore_recrowns`
  - `test_configure_drops_the_crown`, `test_non_defining_finalize_crowns`
  - `test_snapshot_pending_trigger`, `test_snapshot_track_position_and_output_peak`
  - `test_sync_first_completed_take_becomes_primary` (premise rewritten)
- **Dart counts after round 1:** `segno_engine` 242, `looper_repository` 398, root 2234 tests at 91.8% coverage.
  - Main test files: `test/looper/view/tracks_view_test.dart`, `test/app/view/app_test.dart`, `test/visualizer/console_readout_view_test.dart`, `test/looper/view/track_meters_test.dart`, `test/visualizer/waveform_view_test.dart`, `packages/looper_repository/test/looper_repository_test.dart`, `packages/looper_repository/test/models/track_test.dart`.
  - Deleted with their surfaces: `stage_status_bar_test.dart`, `console_volume_overlay_test.dart`, `readout_control_test.dart`, `mode_pair_test.dart`, `waveform_window_test.dart`.
- **Goldens.** All 52 author-only screenshot goldens were regenerated and viewed. `tracks_main_window.png`, `tracks_fx_window.png` and `tracks_device_lost.png` changed layout.
- **Live check** on a macOS development build: a defining take crowned GUITAR, a later take on BOOM left the crown in place, tempo was derived, the clock ran, and the Wave view switched. The input was silent, so no meter fill was seen.
- **Review rounds:**
  - Round 1: `/code-review` at high effort, ten findings, fixed in `533d8585`. The first CI run had failed on package analyzer infos; those were fixed here too.
  - Round 2 (`8986bc05`): the waveform cache froze stale shapes, because the engine's visual buffer is a lazily swept tap.
  - Round 3 (`ab914391`): the sweep now uses the clock the tap is bucketed on, and stale copies are pruned.
- **Not recorded:** mutation checks, frame timing.

**Open items**
- **Displays not verified.** The 7" face has not been seen on a real second display (this Mac has one display, so the app skips the window). Appliance displays, touch, pedal LEDs and real audio levels were not exercised.
- **Explicit crown (timing) handoff has no UI** anywhere in the stack.
  - At `3876f578`, nothing in `lib/` dispatches `LooperCrownPrimaryPressed`, and `crownPrimary` is called only on session restore.
  - The ledger planned it for 2c, and 2c did not build it. No issue is recorded.
- **Sync/Band successor rule** when clearing a primary while other tracks hold audio (accepted-behavior 2.9): listed out of scope on #1010, not built, no issue recorded.
- **CPU readout:** no issue recorded.
- **Touch lock:** #1026 part 4n.
- **Load-audio, MIDI sync pill, first-take tempo review:** listed out of scope on #1010; no issue recorded.

### Part 2a: mode rules and reversible edits

**PR #1013** · `claude/segno-slice2-edits-1012` -> `claude/segno-app-implementation-7c90a8` · open · label review:pending · ci:red (a stacked PR gets no CI). Commits:
- `fb58fff3` (feature);
- `7dd83dcf`, `438df12c`, `6984a486`, `fd13ca36`, `a8ed5305` (ledger only), `222c3e03` (review rounds 1-5);
- `6cdfb9fb` (adversarial round, 2026-09-10).

**What it built**

Mode changes with recorded audio:
- **The gate.** `le_engine_looper_mode_gate` (`engine_commands.c`) returns open, capturing, queued, spans or playing. Dart: `LooperModeGate` (`engine_snapshot.dart`), `LooperModeControl.looperModeGate`, `LooperRepository.looperModeGate`.
- **Rules:**
  - Multi: whole multiples of the shortest take, which is what Multi itself records.
  - Sync/Band: whole multiples of the primary, or the divisions the engine plays (half, quarter).
  - Song/Free: anything.
  - The gate measures effective lengths (`le_effective_len`), so a restore that is posted but not yet applied counts, and a posted arm counts as queued.
- **Switching a playing rig.** `le_engine_set_looper_mode` posts STOP for each playing track and then the mode, so the switch always lands on a stopped rig. The D4 content lock and the old clear-then-switch flow (and its strings) are gone.
- **Re-clocking** (`le_apply_mode_switch`, `engine_process.c`):
  - Into Song/Free: each take runs its own clock at its own length, and the master goes dormant. The master is reset before the "nothing recorded" return. The grid is removed (`a_loop_bars`, `a_current_beat`, `grid_total_beats`); tempo and its source are kept.
  - Into Multi/Sync/Band: the master is re-established from the primary's span, each take's multiple or division is re-derived (`le_restore_multiple_or_divisor`), and the tempo grid is re-established.
- **App flow.** `requestLooperModeChange` (`lib/looper/view/looper_mode_change.dart`):
  - reads the gate;
  - asks "Stop loops and switch" when loops are playing, and re-checks the gate after the confirm;
  - otherwise shows the `looperModeRefusal` reason. In this part that is a snackbar from the old chooser; 2c replaced it.
- **Which mode is remembered.** The remembered mode follows what the engine reports (`_rememberLooperMode`).
  - A request the reports never confirm is dropped after twelve polls.
  - The mode replayed after a restart is armed as a request.
  - `LooperBloc` persists `repository.intendedLooperMode` at the moment of choice (`6cdfb9fb`), so a mode chosen while the interface is closed is saved.

Undo during capture:
- **During an overdub:** undo pushes `LE_CMD_RECORD` to punch out immediately, then peels the pass once it retires. Redo restores the partial pass without resuming capture. A pass that wrote nothing peels the previous layer. A `dub_punch_out_posted` latch makes two taps in one audio block idempotent.
- **During a first take:** undo sends `LE_CMD_CANCEL_TAKE`.
  - The take is finalized at its captured length (a defining take still sets grid and tempo), then the track is emptied.
  - `LE_EVT_TAKE_CANCELLED` files the redo slot, and redo plays the take immediately.
  - A later take keeps its whole-loop span, with silence outside what was captured. The seam crossfade is skipped.
- **Clear on a capturing track:** `LE_CMD_CLEAR` with `arg_f` 1 freezes the take, stopped. `LE_EVT_CLEAR_FROZEN` completes the restore point. Undo brings the take back stopped and audible, never as a resumed capture.

Clear All as one grouped edit:
- **Entry points:** `LooperRepository.clearAll(channels)`, `undoRestoresClearAll`, `undoClearAll`; `ControlCubit.clearAll` / `undoClearAll`; `lib/looper/view/tracks_commands.dart` with the `AppToastId.undoClearAll` snackbar.
- **Undo** on any member restores every member.
- **Redo** re-clears the group only when every member's next redo is that re-clear (`le_engine_redo_reclears`).
- **Group membership** comes from the engine (`le_engine_clear_restore_pending`, `le_engine_undo_restores_clear`). The group dissolves when a member's restore point is retired or a single-track clear happens.
- **Undo at a frozen clear.** The tap is held in `_pendingClearUndo` and taken on the first poll after the restore point lands. A capture that held nothing is forgotten.
- The Undo pedal and key reach the group through the ordinary `undo`.
- The console confirm dialog (`lib/common/console_surface.dart`) now wraps long button labels.
- **Supporting engine pieces:**
  - `le_rig_effective_master_len`: a press behind a queued restore reads the master that restore will re-establish.
  - `pending_master_len`.
  - `depth_republish`: an empty track never publishes an undo depth above 0 while a frozen point or a restore is in flight.

**Decisions**
- **Capture recovery.** The frozen-capture and cancelled-arm behaviour implements `2026-09-08-capture-recovery-ux.md`. The handoff accepts it for the established Multi cycle; the Clear All cases are that proposal's own choices.
- Nothing is cleared, trimmed, repeated, stretched or padded to make a mode fit.
- **Accepted as is:**
  - A second undo tap queued behind a freezing clear does nothing once the first has restored.
  - A frozen member retired by a fresh take in that same window leaves the group without notice.
- No pen departures are recorded for this part.
- **Refuted in the adversarial round (do not re-report):**
  - A dropped `LE_EVT_CLEAR_FROZEN`: the control thread drains the event ring on both sides of that push.
  - A tempo derived from a cleared take: this is the contract, and the restore path depends on it.

**Verification**
- **Native tests.** The part adds 27 test functions in `test_engine_core.c`. All 5 suites pass plain, with ASan and with telemetry off. They include:
  - gate: `test_looper_mode_gate_measures_spans`, `test_looper_mode_gate_multiples_and_divisions`, `test_looper_mode_gate_queued_arm`, `test_looper_mode_gate_sees_an_unapplied_restore`;
  - switching: `test_looper_mode_switch_with_playing_content_stops_first`, `test_looper_mode_switch_multi_song_free_reclocks_content`, `test_mode_switch_to_free_drops_an_undone_grid`;
  - undo during capture: `test_undo_during_overdub_removes_the_pass`, `test_undo_during_recording_cancels_the_take`, `test_undo_during_later_take_keeps_the_span` (the partial-take silence case);
  - clear during capture: `test_clear_during_recording_freezes_the_take`, `test_clear_during_overdub_freezes_the_pass`;
  - grouping and races: `test_redo_reclears`, `test_two_undo_taps_in_one_block_do_not_re_record`, plus the cancel and freeze race tests.
- **Dart counts after round 5:** `looper_repository` 427, `segno_engine` 242, `performance_repository` 111, `session_repository` 84, root 2234 at 91.8%.
  - Files: `packages/looper_repository/test/looper_repository_test.dart`, `test/control/control_cubit_test.dart`, `test/looper/bloc/looper_bloc_test.dart`, `packages/segno_engine/test/pumped_native_engine_test.dart`.
- **FFI suites.** `pumped_native_engine_test` (31) and the fuzz suite (29) passed against a hand-built engine library. In round 2, the fuzz suite's `depths-sane` invariant caught an empty track publishing peelable layers.
- **Review rounds 1-5** (all 2026-09-09) each found one-block races. Details are in the PR body and the ledger's "Slice 2a" section. Round 5 found that the round-4 native test passed without its fix; it now arms with quantize on.
- **Adversarial round (2026-09-10).** It covered #1013 and #1014: one verifier per finding, then a skeptic on anything that survived.
  - 12 findings: 9 confirmed, 3 refuted. Seven were fixed on this branch in `6cdfb9fb`. All are mutation-checked except the divide by zero, which is structural.
  - The record is in the ledger's Slice 3 section ("The twelve engine findings, settled", commit `6f7a3451` on the 3c branch), not in this PR body or the 2a ledger section.
  - That entry says the two engine PRs had never been reviewed, which conflicts with the five rounds in this PR body. The label still reads `review:pending`.

**Open items**
- Hardware timing of stop-and-switch and of a cancelled take on the appliance.
- Full pedal sequences on hardware are not recorded.
- Accepted-behavior 2.12 (failed capture publication holds the take; clock loss) is not in this part. No issue is recorded in the slice 2 sources.
- Peel as its own foot action is #1026 part 4m.

### Part 2b: record timing, overdub decay and Once per track

**PR #1014** · `claude/segno-slice2b-timing-1012` -> `claude/segno-slice2-edits-1012` · open · review:pending, ci:red. Commits: `7a8c7c3b` (feature), `621c5ac6` (round 1), `b77d258f` and `42c4d079` (adversarial round, 2026-09-10).

**What it built**

Record timing:
- **`RecordTiming`** (`packages/segno_engine/lib/src/engine_snapshot.dart`) has `immediately`, `loopStart`, `bar`, `half`, `quarter`, `eighth`, `sixteenth`. `RecordTiming.of(quantize:, division:)` combines the engine's gate with a `GridDivision`.
- **Per-track division in the engine.** `le_engine_set_track_quantize_div` sets `a_quantize_div_override` (-1 inherits), next to the existing per-track gate `le_engine_set_track_quantize`. `le_live_subdiv_ratio(e, ch, ...)` reads it at every boundary check, so two armed tracks can fire on different grids in the same lap.
- **Repository:** `setRecordTiming`, `setTrackRecordTiming`, `Track.recordTimingOverride`, and `TransportState.recordTiming`. `Track.quantizeOverride` is now a getter over the override.
- **Snapshot** publishes `quantize`, `auto_record`, the global `overdub_feedback` and the per-track overrides. The gate and the division are published together from the control thread's copy (`42c4d079`).
- A Sync force-armed defining take is pinned to the primary's loop top, whatever division is set (`42c4d079`).

Overdub decay:
- **Meaning.** Decay is a percent: 0 keeps every layer whole, 100 replaces them. The engine uses feedback `1 - decay/100`, by default and per track (`le_engine_set_track_overdub_feedback`, `a_overdub_fb_bits`, a negative value inherits). Playback never decays.
- **Mid-pass changes** ramp at the write head over the punch fade (about 10 ms) in `mix_tracks_frame`.
- **Repository:** `setOverdubDecay`, `setTrackOverdubDecay`, `Track.overdubDecayOverride`, `TransportState.overdubDecay`.
- **Perf-log code.** `LE_PLOG_SET_TRACK_OVERDUB_FEEDBACK = 317` in `perf_log_ring.h`. It was 315, which collided with `LE_PLOG_PERF_ARMED`. It is documented in `docs/design/performance-event-log-format.md`.

Once in all five modes:
- **Free/Song** stop at the track's own clock wrap.
- **Multi/Sync/Band:** `le_shared_clock_one_shots` ends a track's lap on the shared clock: at the master wrap back to the first segment for a k-multiple, every base/n frames for a division, at the wrap for a 1x take.
- **Stopping.** Both paths call `le_one_shot_stop`, the same transition as a manual Stop.
- **Ordering.** The check runs after both the grid and section arm loops, and a track whose arm fired into an overdub this frame keeps that pass. `sounding_frames` makes a lap end stop a track only after a whole lap.
- **Documented assumption:** "subsequent launch starts at the beginning" is read on the shared clock. A track launched mid-lap stays aligned to the master; from a held transport the next launch starts at the top.

Count-in and Sound start:
- They exclude each other in the repository's re-apply caches, and in `RecordOptionsCubit` and `TempoCubit`. Those cubits take the values from the repository, which reads correctly while the engine is stopped. The engine already enforced this (D9).

Persistence:
- **Settings keys:**
  - `track_record_timing.N`, migrated from `track_quantize.N` on first read;
  - `track_overdub_decay.N` and `looper.overdub_decay`;
  - the default record timing stays in the existing `looper.quantize` and `tempo.quantize_div` keys.
- **Session:**
  - `Session.recordTiming` / `overdubDecay` hold the defaults. They were saved but never restored until `b77d258f`.
  - `SessionTrack.recordTiming` / `overdubDecay` hold the per-track overrides.
- **App:**
  - events `LooperTrackRecordTimingChanged` and `LooperTrackOverdubDecayChanged`;
  - `PlaybackOptionsCubit` (`lib/looper/cubit/playback_options_cubit.dart`);
  - boot restore in `lib/app/audio_bootstrap.dart`.
  - The routing dialog's three-way switch wrote a timing override; #1020 later retired that dialog.

**Decisions**
- The product exposes one `RecordTiming` value; the engine keeps its separate gate and division.
- **Noted, not changed:** the session reads a track's timing override from the engine's report. A forced gate with an inherited division is therefore saved with the division filled in, and comes back as an explicit value.
- **Refuted in the adversarial round:** a per-track division/gate ordering race.
- No pen departures. No screen changed except the routing dialog.

**Verification**
- **Native tests.** 16 new tests; 5 suites pass plain, with ASan and with telemetry off. They include:
  - division and decay: `test_track_quantize_div_override_fires_on_own_boundary`, `test_track_overdub_feedback_override_and_inherit`, `test_track_overdub_feedback_change_mid_pass_ramps`;
  - snapshot: `test_snapshot_publishes_record_start_settings`, `test_quantize_gate_and_division_publish_together`;
  - Once: `test_one_shot_stops_at_lap_in_multi_mode`, `test_one_shot_multiple_stops_after_its_own_laps`, `test_one_shot_punch_out_arm_at_wrap_stops`, `test_one_shot_stop_does_not_unpark_siblings`, `test_one_shot_take_finalized_mid_lap_plays_a_full_lap`, `test_one_shot_division_stops_after_its_own_lap`;
  - adversarial fixes: `test_sync_force_arm_ignores_a_per_track_division`, `test_plog_codes_are_distinct`.
- **Dart counts:** `segno_engine` 242 (snapshot field golden in `engine_snapshot_test.dart` extended), `looper_repository` 430, `settings_repository` 138, `session_repository` 84, `performance_repository` 111, root 2245 at 91.7%.
  - `test/looper/cubit/playback_options_cubit_test.dart` is new; `test/session/session_mapping_test.dart` covers the defaults restore.
  - Pumped-native and fuzz ran against a hand-built library.
- **Review round 1** (`621c5ac6`) fixed Once ordering races, the mid-lap stop, and the cubit copies that read a stopped engine.
- **Adversarial round** fixes are `b77d258f` and `42c4d079`. Mutation checks for those two commits are not recorded.

**Open items**
- Hardware timing of the per-track grids and of the Once stop. The decay ramp needs a listening check on hardware.
- **Saved while stopped.** A session saved while the engine is stopped drops the per-track timing and decay overrides (ledger round 1, not changed).
- **Empty channels lose overrides.** Observed in code at `3876f578`; not recorded as a finding anywhere:
  - Per-track record timing and decay overrides still travel on `SessionTrack`.
  - `SessionRepository` writes a `SessionTrack` only for a channel with audio (`if (lanes.isEmpty) continue;` in `session_repository.dart`), so an override on an empty channel is not saved.
  - 2c fixed the same problem for length and Once by using session-level maps.

### Part 2c: the Loop settings pages

**PR #1015** · `claude/segno-slice2c-loop-settings-1012` -> `claude/segno-slice2b-timing-1012` · open · review:clean, ci:red. Commits: `555b9c9d` (feature), `e3aa2625` (round 1), `f6299400` (round 2), `839cb330` (round 3).

**What it built**

The route:
- **`LoopSettingsPage`** (`lib/looper/view/loop_settings/loop_settings_page.dart`) is one page stack. Each page is a 1920x1080 `LoopSettingsFrame` canvas, scaled down to fit the window.
- It is opened by `openLoopSettings` (`lib/app/segno_navigator.dart`), from the console tray's Loop rail entry (`TrayRailEntry` in `tray_navigation_rail.dart`) and from the desktop Settings list (`settings_page.dart`).
- **The hub** (`loop_settings_hub.dart`, `LoopSettingsPageId`) has six rows, each with a live summary.

The pages:
- **`loop_mode_page.dart`**
  - A refused mode shows its `looperModeRefusal` reason in place of its description.
  - Playing loops ask "Stop loops and switch" in the pen's dialog, which lives in `looper_mode_change.dart` and is the only confirm. Its body text: "Playing loops will stop. Recordings stay intact."
  - Cards rebuild on track states, queued triggers, lengths, `transport.countingIn` and `track.layerInFlight`.
- **`loop_recording_page.dart`**: reads rec/dub, Sound start (`autoRecord`) and count-in. Locked behind `LoopLockBanner` during a capture.
- **`loop_tempo_page.dart`**: tempo with 1 BPM and 0.01 BPM step buttons, click mode, count-in bars, and the Time signature page.
- **`loop_length_page.dart`**
  - A Tracks / Defaults / 1-8 scope selector, with the default length and record timing.
  - Per-track overrides go through `LooperTrackLengthPresetChanged` and `LooperTrackRecordTimingChanged`. A track that differs from the default shows "Use default".
  - In Multi the length shows "Shared in Multi".
  - Locked during a capture.
- **`loop_playback_page.dart`**
  - Loop/Once and decay, default and per track, through `LooperTrackOnceChanged` and `LooperTrackOverdubDecayChanged`.
  - Stays live during a capture. The decay slider previews locally and commits at the end of the drag.
- **`loop_audio_tempo_page.dart`**: a readout only. It shows the recorded-speed state with its choices disabled, and one line saying tempo following is not available yet.

Ownership:
- **`RecordTimingCubit`** (`lib/looper/cubit/record_timing_cubit.dart`) is the single app owner of record timing.
  - It keeps the last musical division while the gate is off, and the two audio-setup toggles read the gate from it.
  - `QuantizeCubit` is deleted, and `TempoCubit` no longer holds a division.
- **Repository defaults and overrides:**
  - setters: `setDefaultLengthPreset`, `setDefaultOnce`, `setTrackLengthPreset` (`null` follows the default, `0` is an explicit Auto), `setTrackOnce`.
  - In Multi, `_effectiveLengthPreset` returns the default, and a stored override is inactive. Once stays per track in every mode.
  - `_pushTrackDefaults` runs on start. `_pushLengthPresetsAcross` re-pushes only override channels, and only when a switch crosses the Multi boundary.
  - Setters write the engine before `_reproject()`. Presets are clamped to the engine's 64-bar limit.
- **Settings keys:**
  - new: `looper.default_length_bars`, `looper.default_once`, `track_once.N`;
  - per-track length stays in `tempo.length_preset.N`: -1 follows the default, 0 is Auto, 1..64 is bars. `loadTrackLengthPreset` now tells "follow" from Auto.
- **Session.** `SessionLoopSettings`, built by `loopSettingsFromLooper` (`lib/session/session_mapping.dart`), carries:
  - the rig defaults;
  - session-level maps `Session.lengthPresetOverrides` and `onceOverrides`, mirrored on `SessionRig`.
  - `applySession` puts every track on the default, then writes the overrides as saved, limited to the engine's tracks. `oneShotChannels` is removed.
- **Cubit fields and boot:** `RecordOptionsCubit.defaultLengthBars`, `PlaybackOptionsCubit.once`, and boot restore of the defaults and the per-track Once.

Retired:
- Surfaces: the tray's Loop domain (Tempo / Click / Mode tabs), the tempo keypad sheet, the desktop Tempo and Mode sections, the tray's Tracks > Lengths tab, and the desktop Tracks length and One Shot rows.
- Events and methods: `LooperOneShotToggled`, `LooperAllOneShotToggled`, `LooperRepository.setOneShot`.
- Settings: the `tempo.sync` key and `TempoCubit.setSyncTempo`. The engine default (sync on) applies.
- Strings: 65 orphaned l10n keys and a duplicate `loopLengthAuto`. About 110 new `loop*` strings were added in en and es.

Other changes:
- **Interim click output.** `ClickOutputCard` / `ClickOutputSection` put click routing and level on the Audio tray's Device tab and the desktop Audio section, because a fresh unit's `a_click_mask` of 0 is silent. #1020 (3c) removed them again when Audio routing took over click routing.
- **`LoopSlider.onChangeEnd`** commits once per touch, on the raw pointer-up. The tap and drag recognizers each cancel when the other wins, so a plain tap had committed twice.
- **Undo, Redo, Clear All** were already reachable from keys (`Z`, `Y`, `C`, `Shift+C`) and pedals (`LooperAction.undo`, `clear`). No new wiring was needed.

**Decisions and pen departures**

Written into `segno-ui.pen` as `c/ Implementation · slice 2c`, node `OaX2R`, section `EYla4`, in the owner's uncommitted pen:
- Pen icon glyphs are drawn with lucide equivalents (chevron, check, arrow-left, repeat, arrow-right-to-line, minus, plus, timer, music), because the pen MCP cannot read path geometry.
- The pen's hex colours map onto console theme tokens, as in slice 1.
- The Length page's lock banner sits under the scope selector, with the sections moved down by 92.
- The tempo steps are two labelled buttons (1 BPM / 0.01 BPM) instead of the pen's unlabelled pair.

Also listed in the ledger:
- Click routing and level on the Audio Device tab until the Mixer owns them.
- The Lengths tab and the desktop length / One Shot rows removed.

Other decisions:
- **The manifest saves overrides and defaults, not effective values.** The PR body's first paragraph still describes effective values; review round 1 replaced that.
- **Left as is:**
  - A `tempo.length_preset.N` of 0 saved by an earlier build reads as an explicit Auto. There is no migration; "Use default" clears it in one tap.
  - The Loop widgets keep pen-width parameters, because the pages are pen-geometry canvases.

**Verification**
- **Tests:**
  - new: `test/looper/view/loop_settings/loop_settings_test.dart` (22), `test/looper/cubit/record_timing_cubit_test.dart`, `test/audio_setup/view/click_output_card_test.dart`, `test/audio_setup/view/click_output_section_test.dart`;
  - updated: `test/session/session_mapping_test.dart`, `test/session/cubit/session_cubit_test.dart`, `packages/settings_repository/test/settings_repository_test.dart`, `packages/looper_repository/test/looper_repository_test.dart`;
  - deleted: `quantize_cubit_test.dart`, `loop_faces_test.dart`, `looper_mode_section_test.dart`, `tempo_settings_section_test.dart`.
- **Goldens** (author machine), compared against the pen:
  - `test/screenshots/loop_settings_screenshots_test.dart` adds 11: `loop_settings_hub`, `loop_settings_mode`, `loop_settings_mode_confirm`, `loop_settings_recording`, `loop_settings_recording_locked`, `loop_settings_tempo`, `loop_settings_signature`, `loop_settings_length_defaults`, `loop_settings_length_custom`, `loop_settings_playback_custom`, `loop_settings_audio_tempo`.
  - The screenshot suites now share one font loader, `test/helpers/screenshot_fonts.dart`, which also loads the lucide font.
  - The tray Loop goldens and the settings Tempo/Mode goldens were deleted.
- **Counts after all rounds:** root 2192, `looper_repository` 435, `session_repository` 91, `settings_repository` 141. Analyzer clean at the root and in the packages; bloc lint clean. The engine is untouched.
- **Review rounds:**
  - Round 1: eight finder angles, one verifier per candidate, ten confirmed findings.
  - Round 2: overrides on empty channels were lost on save; the mode-card rebuild key was incomplete; a cancelled slider gesture left its preview.
  - Round 3: a tap committed twice; manifest presets above 64 bars.
- No mutation checks are recorded.

**Open items**
- **Not verified:** the pages on the appliance's two displays and by encoder. The pen's encoder focus rectangles are not implemented.
- **Audio & tempo** (Follow tempo and pitch preservation, accepted-behavior 2.6) is only a readout. The engine has no Speed, Reverse, pitch preservation or Follow tempo (#1016 says the same). Speed is #1026 part 4i.
- **Explicit crown handoff UI:** not built (see slice 1).
- **Record timing and decay overrides on empty channels** are not saved in a session (see 2b).

### Gotchas specific to slices 1 and 2

- **Design sources are not on the branches.**
  - The contracts and the handoff pack exist only as untracked files in the main checkout; a fresh worktree does not have them.
  - The pen notes for slices 1 and 2c are only in the uncommitted `segno-ui.pen`. Branch blob `d3b4eb47` equals master's; the working copy was `18506780` at this reading.
  - Check with `git hash-object segno-ui.pen` against `git rev-parse HEAD:segno-ui.pen`, never `git status`.
- **Landing the stack.** After #1011 is squash-merged, retarget each child to `master` before deleting its parent branch, then merge master into the child. The details are in memory note `loopy-stacked-pr-squash-merge-landmines.md`.
- **FFI-gated Dart tests skip without warning on these four branches.**
  - `packages/segno_engine/tool/build_test_lib.sh` was broken until `8625ba75` (slice 3b, #1018).
  - Build the library by hand: that script's compile line plus `-I third_party/rnnoise/include -I third_party/rnnoise/src`, the rnnoise source list from `run_native_tests.sh`, and `restore_declip.c` and `restore_halfband.c`. Then export `SEGNO_ENGINE_LIB`.
  - The fuzz suite is `flutter test --tags fuzz`.
- **Engine visual buffer.** It is a lazily swept tap: nothing is written during a defining take, and a recording track contributes zeros. Never cache it on steady track facts; read through `LooperRepository.readTrackWaveform`. A stopped engine reports zero tracks.
- **Mode persistence.** Persist `intendedLooperMode` at the moment of choice, but keep the projection on the engine's reported mode. The waveform sweep policy depends on the reported mode.
- **Engine threading rules:**
  - `LE_CMD_RECORD` does not bump `a_state_acks`. Do not fix that with `le_mark_state_cmd`: it blocks every effective-state read.
  - `handle_clear` acknowledges its own state command, so callers must not.
  - Every audio -> control event needs an epoch or pending guard.
  - The control side must not pre-zero `a_len` when the audio thread can decline the command.
- **Mode-card rebuild key.** The mode gate reads `a_counting_in` and `a_layer_in_flight`, so any widget that shows the gate must rebuild on `transport.countingIn` and `track.layerInFlight`.
- **Record timing and the gate.** `RecordTiming.of(quantize: false)` collapses to `immediately`. Anything that toggles the gate must remember the division itself, as `RecordTimingCubit` does.
- **Per-channel session settings.** A `SessionTrack` exists only for a channel with audio. A setting that must survive a save on an empty channel belongs in a session-level map.
- **Perf-log codes** in `perf_log_ring.h` are on-disk values and are not in numeric order. Take the next unused number and add it to `test_plog_codes_are_distinct`.
- **Naming.** The UI says "Once"; the engine and repository still say one shot (`AudioEngine.setOneShot`, `oneShotOverride`, `defaultOneShot`). Per-track length is still keyed `tempo.length_preset.N`.
- **Native test harness:**
  - Use `tg_make_engine(1000)` with `tg_advance`.
  - `process_const` holds one 64-frame buffer; use `tg_feed` for longer runs.
  - Overdub one track at a time.
  - Mutation-check every new test: in 2a round 5, a race test passed without its fix because the audio thread decides defining-or-not on its own clock.
- **Widget tests:**
  - The default test surface is 800x600 while the pen is 1920x1080: use `ShrinkToWidth`, and note that `ConstrainedBox` cannot be `const`.
  - A state pushed through a mocked bloc stream needs two `pump()` calls.
  - Loop pages must read defaults from the cubits, not from the mocked bloc transport.
  - Under the Ahem font, choice labels need `FittedBox` scale-down.
  - Icon goldens need the lucide font loaded through `test/helpers/screenshot_fonts.dart`.
- **Goldens run only on the author's machine,** on the Flutter pinned in `.github/workflows/main.yaml`. Never run `--update-goldens` on a different Flutter version.
- **Analyzer files.**
  - A package-level `flutter test` rewrites that package's `analysis_options.yaml`. Revert it before `git add -A`: one change was committed by accident in `ab914391` and reverted in `ec3e25f0`.
  - CI runs `dart analyze --fatal-infos` inside each package.
- **Pen coordinates.** Children of `LoopSettingsFrame` use main-local pen coordinates (tile y minus 168), not screen-local (tile y minus 72).


## 3. Slice 3: inputs, outputs, Mixer and FX (issue #1016)

Issue #1016 is still open. All six part checkboxes are ticked. The contract docs are listed on the issue: `accepted-behavior.md`, `docs/design/2026-09-07-audio-routing-ux.md`, `output-setup-ux.md`, `mixer-performance-ux.md`, `2026-09-06-fx-ux-design.md`, `fx-simplicity-review.md`, `2026-09-08-fx-parity-correction.md` and `2026-09-09-fx-reference-completion.md`. Most of `docs/design` is untracked in the main checkout, so a worktree cannot see it. The detailed record is `docs/plan/2026-09-09-segno-implementation-ledger.md` on each branch, in the sections "Slice 3a" through "Slice 3f part 11". It has more detail than the PR bodies.

| Part | PR | Branch <- base | Labels | Head |
| --- | --- | --- | --- | --- |
| 3a mix model | #1017 | `claude/segno-slice3-mixer-fx` <- `claude/segno-slice2c-loop-settings-1012` | stage:in-review, autonomy:merge-gate, review:clean, ci:red, area:console, area:engine | 37f328ef |
| 3b output destinations | #1018 | `claude/segno-slice3b-outputs` <- `claude/segno-slice3-mixer-fx` | same as #1017 | 8625ba75 |
| 3c Audio routing + Output setup | #1020 | `claude/segno-slice3c-routing-surfaces` <- `claude/segno-slice3b-outputs` | stage:in-review, autonomy:merge-gate, review:pending, ci:red | 6f7a3451 |
| 3d Mixer view | #1021 | `claude/segno-slice3d-mixer` <- `claude/segno-slice3c-routing-surfaces` | same as #1020 | 2bca71f4 |
| 3e FX placement and printing | #1022 | `claude/segno-slice3e-fx-placement` <- `claude/segno-slice3d-mixer` | same as #1020 | be987759 |
| 3f FX surfaces, Signal retires | #1024 | `claude/segno-slice3f-fx-surfaces` <- `claude/segno-slice3e-fx-placement` | stage:in-review, autonomy:merge-gate, review:pending, ci:red, area:console, area:fx | 95dcea0d |

- All six PRs are open.
- Local and `origin` heads match for all six branches.
- Every PR shows `ci:red` because the repository workflow only runs on PRs that target master. Stacked PRs get GitGuardian only. All checks listed below were run locally.
- The issue gates are `/code-review` clean and CI green before ready-to-merge. Only #1017 and #1018 carry `review:clean`.

---

### 3a. The mix model: PR #1017

**Status:** open, review:clean, ci:red. Commits: 6d71b895 (feature), 012d927f (review round 1), 37f328ef (review round 2). The memory notes cite pre-rebase hashes.

**What it built.** Engine, repository, settings and session only; no UI.

- **Pan:** `le_engine_set_lane_pan` (-1..1).
  - Applied to the lane's stereo pair after its chain and after the wet cache.
  - The law is `le_pan_gains`: the near side stays at unity, the far side falls on a quarter-sine and is exactly silent at the hard side.
  - Centre is bit-identical to the engine before this change.
  - A lane routed to one output receives the pair's mid.
  - Gains are computed when the pan is set.
- **Solo:** `le_engine_set_track_solo`.
  - While any track is soloed, only soloed tracks route.
  - Solo sits beside mute in the audible gate and never writes mute.
  - Chains keep running, dry meters keep reading, and monitors are unaffected.
  - Not saved. Cleared by a session load.
- **Capture trim:** `le_engine_set_input_trim`, linear 0..+12 dB. The repository speaks -24..+12 dB in half-dB steps.
  - It scales only the sample a lane records. Monitor, meters, clip detector, trigger and tuner read the untrimmed input.
  - It is a direct store, so it holds while stopped.
- **Monitoring:** `le_engine_set_monitor_input_pan`. `LE_MAX_MONITORED_INPUTS = LE_MAX_CHANNELS` (32 monitors, 106 KB), so every hardware input can be monitored. Ring commands 58 to 60.
- **Meters,** as trailing snapshot fields: per-track post-fader `peak_l`/`peak_r`, per-input raw peaks, per-monitor peaks, and per-output-channel peaks after the master stage. They are projected per channel the device has and read only what reaches an output.
- **Recorded image,** in the repository:
  - `_seedLaneImage` fixes each lane's pan and balance gain from its input's setup when a take starts. A pair member sits hard on its side; a mono input sits where its pan put it.
  - The engine receives the effective pan (image + track pan) and effective volume (level x balance gain).
  - Stereo pairs are two mono lanes with pans -1/1. No stereo lane type exists.
  - Later input edits move the live monitor and future takes only.
- **Models:**
  - `InputSetup` (`packages/looper_repository/lib/src/models/input_setup.dart`) holds trims, pans, and pairs with balance. It is on `LooperState.inputSetup`.
  - `MixTarget` (`mix_target.dart`) covers track pan, input level/pan and pair balance, with `tryParse`/`canonicalString()` like `FxAddress`. Track level stays `TrackVolumeTarget`.
- **Settings:**
  - `track_pan.N` and `input_trim/pan/pair/balance.<device>.N`.
  - Writers are per input (`saveInputTrim/Pan/Pair`), plus one whole-setup writer used by a session load.
  - Restored at boot after the lane counts.
- **Session manifest:**
  - Fields: `tracks[].pan`, `lanes[].volume` (the level), `lanes[].pan` (the image), `lanes[].balance`, `monitors[].pan` and `inputSetup`.
  - Captured through `SessionLoopSettings.laneMix`/`trackPans`.
  - The input setup is session-owned: a load replaces it and re-persists it. Input names stay appliance-wide.
- **Bloc events:** `LooperTrackPanChanged`, `LooperTrackSoloToggled`, `LooperSoloCleared`, `LooperMixerReset`, and the `LooperInputEvent` family (`LooperInputTrimChanged/PanChanged/PairChanged/BalanceChanged`).
- **Offline paths:** Solo gates `perf_render.c` and `packages/daw_export/lib/src/event_log_reader.dart`, seeded from a per-track `solo` in the arm manifest. Pan does not reach either path; both are mono.

**Decisions.**
- The pan law is an engineering choice; the accepted records leave it open.
- Pairing is refused while a track fed by either member is armed or capturing, and past the engine ceiling.
- Reset mixer walks every remembered track.

**Verification.**
- Native tests: `test_lane_pan_law`, `test_track_solo_gates_routing`, `test_input_trim_scales_capture_only`, `test_monitor_pan_and_wide_inputs` (monitor on input 18 of 18), `test_track_stereo_peaks_follow_fader`, and `test_meters_read_only_what_routes`. All run plain, with ASan and with telemetry off.
- Dart: `packages/looper_repository/test/mix_model_test.dart`.
- **Review round 1** (four finder angles, six verifiers) fixed:
  - Level, image and balance projected and saved from the repository's own caches; a load no longer folded balance into the level.
  - Grown lanes get the track pan.
  - Solo in the offline render and the DAW export.
  - Meters bounded to the device.
  - The pairing lock.
  - Re-persisting on load.
  - `MixTarget` cleanups.
- **Review round 2** fixed:
  - The fresh-take path still saved the engine gain as the level.
  - A grown lane was pushed at unity instead of the track's level.
  - A load posted 64 ring commands.
  - The DAW export left a track silent at arm.
- Final counts: `segno_engine` 263, `looper_repository` 457, `settings_repository` 148, `session_repository` 102, `performance_repository` 113, `daw_export` 100, root 2210.

**Open.**
- The pan law by ear and the meters on the appliance.
- The offline performance render replays solo but not pan (it renders lane 0 mono).
- A lane pushed into the pan clamp by the track pan reloads slightly less far from centre; the ledger records this as a known small loss.

---

### 3b. Output destinations: PR #1018

**Status:** open, review:clean, ci:red. Commits: f628c741, 393f16f7 (round 1), 8625ba75 (round 2).

**What it built.** Engine and repository only; no UI.

- **Output buses:**
  - Destination `k` = outputs `2k`/`2k+1`. `LE_MAX_OUTPUT_BUSES = LE_MAX_CHANNELS / 2` (16). An odd channel count leaves a single-jack last bus.
  - Each bus has a level (kept behind the mute), a mute, Stereo/Mono, a balance on the lane pan law, and its own chain.
  - Setters: `le_engine_set_output_level/mute/mono/balance` and `le_engine_set_output_fx*`. Ring commands 61 to 66; Cut is 67.
  - Snapshot fields: `output_bus_count`, `output_level[]`, `output_muted[]`, `output_mono[]`, `output_balance[]`, `tail_reset_rev`, `perf_follow_output`, `perf_capture_bus`.
- **Frame order:** tracks, monitors, click. Then per bus: chain, performance tap, Mono/balance, level, mute. Then the global master gain, the limiter and the output meters. A bus at its defaults with no chain costs nothing per frame.
- **Master insert:** it is now bus 0's chain.
  - `le_engine.master_fx`, `le_engine_set_master_fx*`, ring codes 51/52 and the Dart `setMasterFx*` family are deleted.
  - The chain now also processes monitors and the click; the old D-MASTER rule is retired.
  - The click sums in before the buses, so its destination's chain, level and mute apply.
- **Performance capture tap:**
  - By default the tap sits after the captured bus's chain and before its level, Mono, balance, mute, master gain and limiter.
  - `le_perf_set_follow_output` / `PerformanceRepository.setFollowOutput` set the policy that the next arm freezes. The policy survives a reconfigure.
  - The captured bus is the first destination with an enabled channel. It is published as `perf_capture_bus` and recorded as `captureBus` in the arm manifest, read after `le_perf_arm`.
  - `perf_render` skips the master stage for a default take. Under Follow it replays the captured bus's level and mute.
  - A manifest with no `followOutput` key reads as Follow, because earlier takes were captured post-gain.
- **Cut all sound (`le_engine_cut_sound`):**
  - Every playing or capturing track goes through the Stop handler and is perf-logged per track.
  - The count-in is cancelled.
  - Every chain's DSP state and delay rings are cleared inline in one callback; settings stay.
  - `a_tail_reset_rev` advances.
- **Bypass drains the tail,** only for `le_fx_type_drains` types (ring-owning with no reported latency: delay, echo, reverb).
  - `enable_mix` scales the feed: `dry*(1-mix) + effect(dry*mix)`.
  - The slot keeps running on silence until the tail stays under 1e-4 for 50 ms, or 8 s pass.
  - Drive, octaver and hosted plugins keep the old crossfade.
  - `le_fx_entry_reset` clears the drain state, and so does plugin install.
- **Stop drains Post tails; Mute gates them.**
  - `mix_tracks_frame` splits the old gate into `fed` (playing, not gated), `gate_ok` (not muted or soloed away) and `routes`.
  - The track chain routes via the union of the gate-open lanes' destinations.
  - Output chains keep draining under Mute.
- **Persistence:**
  - `OutputSetup`/`OutputBus` (`packages/looper_repository/lib/src/models/output_setup.dart`) on `LooperState`.
  - Settings keys `output_level/mute/mono/balance.<device>.<bus>`, via `loadOutputSetup`, `saveOutputBus` and `replaceOutputSetup`.
  - Session field `outputSetup`, restored at boot and re-persisted on load.
  - Each setter pushes one ring command and writes one key.
- **Bloc events:** `LooperOutputLevelChanged/MuteChanged/MonoChanged/BalanceChanged` and `LooperCutSoundPressed`. Dart `MasterBusControl` gained the bus setters and `cutSound`.

**Decisions.**
- The global master gain and limiter stay as the final stage.
- Bus level changes are instant, with no ramp.
- A disabled jack is part of the routing graph; a bus mute is a gain after the tap. A test pins the two side by side.
- Cut clears the rings inline on purpose. Deferring a slot's clear passes it dry, and a verifier showed a full-wet delay bursting the raw input at full level during the deferral.
- The speculative `setTrackOutput` was removed; the track-wide route belongs to 3c.

**Verification.**
- Tests flipped to the new behaviour: `test_click_processed_by_output_bus`, `test_count_in_click_captured_when_routed`, `test_output_fx_colors_monitors`, `test_output_fx_ch_out_4_is_bus_0`, `test_fx_bypass_drains_tail_then_settles`.
- New tests include `test_perf_master_tap_pre_level_by_default`, `test_perf_master_tap_follow_output_post_gain`, `test_output_bus_level_mute_mono_balance`, `test_cut_sound_stops_tracks_and_clears_tails`, `test_stop_drains_lane_tail_and_mute_gates_it`, `test_output_bus_honours_disabled_channels`, `test_fx_retype_mid_drain_starts_clean` and `test_perf_follow_survives_configure_and_capture_bus`.
- The golden parity test runs both capture policies, plus a run with a mismatched destination.
- **Round 1** (eight finder angles, then a verify pass) fixed:
  - A disabled channel carrying audio.
  - A retype mid-drain replaying the old ring.
  - Drain overshoot on memoryless types.
  - A capture destination hard-coded to bus 0.
  - A policy reset on device change.
  - Four ring commands per edit.
  - The compatibility layer, which was deleted.
- **Round 2** (a refute-first skeptic per fix, then four critics):
  - Three round-1 fixes were themselves wrong: the capture bus was read before arm, the `copyWith` guard was only relocated, and the spaced ring clear was worse than the inline one.
  - Several tests passed against their own reverted fix; they read calloc zeros because they never filled the delay ring. They were rebuilt and mutation-checked.
  - `packages/segno_engine/tool/build_test_lib.sh` was repaired. It had stopped compiling, so every FFI-gated Dart test had been skipping silently.
- `EngineSnapshot.copyWith` is pinned by two source-level goldens.
- Final counts, with the test lib built: `segno_engine` 306, `looper_repository` 475, `settings_repository` 152, `session_repository` 103, `performance_repository` 118, `daw_export` 100, root 2246.

**Open.**
- The bus stage and the drain values (1e-4, 50 ms, 8 s) need a listen check on the appliance.
- The offline render does not replay the bus's Mono, balance or chain.
- The Follow-output preference has no surface or setting. At the stack tip `setFollowOutput` has no caller in `lib`.
- Not recorded as answered: whether boot should restore the output setup from the last session instead of the per-device settings.

---

### 3c. Audio routing and Output setup: PR #1020

**Status:** open, review:pending (a review round is recorded, see below), ci:red.
- Feature commits: e57de47b, 3dbabd77, 4e61105b, e02ab316, ebe61cec, 6df2ed42.
- Retirement: ae44bb39.
- Review fixes: 333324fb.
- Ledger: f8b2c717, 6f7a3451.

**What it built.** One route, `openAudioRouting()` in `lib/app/segno_navigator.dart`, with a re-entrancy guard reset by `resetSegnoNavigatorForTest`.

- **Structure:**
  - `lib/looper/view/audio_routing/audio_routing_page.dart` (`AudioRoutingPage`, `AudioRoutingTab`) shows four task pills as page state.
  - It reuses `LoopPenCanvas`/`LoopSettingsFrame`.
  - Entry points: a Routing row on the desktop Settings rail, and `AudioRoutingCard` on the console Audio face Device tab. The card also carries the click level.
- **Input setup** (`input_setup_tab.dart`):
  - Pick a jack; eighteen jacks scroll past the pen's four cards.
  - Choose mono or an ordered stereo pair. A pair shows Balance, a mono jack shows Pan.
  - Trim in half-dB steps.
  - The clip tail lights on the engine's held clip flag.
  - The format lock is derived from the projection: the format freezes when either pair member feeds an armed or capturing track.
  - Dispatches the 3a input events.
- **Recording inputs** (`recording_inputs_tab.dart`):
  - A scope row picks the track, then its jacks.
  - Unchecking frees that lane in place; lanes are never compacted.
  - A new jack fills a free lane. Only a full track grows, and the growth is dispatched before the routing. A track at `kMaxLanes` refuses.
  - The lock is per track.
- **Output routing** (`output_routing_tab.dart`):
  - Live inputs route through their monitor, tracks through every lane, and the click through its own mask. A track's route is written to every lane, and lane 0 is read back.
  - Hear live (Off/Auto/On) appears only on live inputs.
  - Mask helpers in `output_setup.dart`: `outputBusMask` sets only the jacks the device has; `outputBusBits` clears both; `outputMaskDrivesBus`.
- **Output setup** (`output_setup_tab.dart`):
  - Format, level, balance and mute per destination.
  - Meters read that destination's jacks, and a muted destination meters silence.
- **Destination names:**
  - Settings key `output_name.<device>.<bus>` and `OutputsCubit` (`lib/audio_setup/cubit/outputs_cubit.dart`).
  - `outputBusLabel`/`outputName` in `lib/l10n/localized.dart`, with a jack-number fallback.
  - `routing_names_page.dart` holds the name lists: page state behind the header action, outputs listed per destination, rename through the console rename sheet, and an empty name allowed.
- **Retired:**
  - `lib/looper/view/tracks/routing_tracks_tab.dart` and `track_routing_dialog.dart`; the quantize control they carried is covered by the slice 2 Length & quantize page.
  - The console `click_output_card.dart` and the desktop `click_output_section.dart`, which became `click_volume_section.dart`.
  - The Tracks tray panel's strip.
  - 29 strings and 5 goldens.

**Decisions.**
- **Backing & click ships with the click only.** No backing player exists anywhere in the product. This was not recorded as written back to the pen.
- **The Signal face's per-jack output gate stays.** It is a structural switch with the #569 last-live-output guard, which is a different fact from a destination mute. The PR says it "needs a design answer before it can move". See the 3f gotcha: 3f removed it anyway.
- **Settings path, not a ninth tray rail row.** A ninth row broke the rail spacing test.
- **Defect fixed:** the routing meter fill was amplitude-linear under evenly spaced dB ticks.

**Verification.**
- Tests: `test/looper/view/audio_routing/audio_routing_test.dart`, `test/audio_setup/cubit/outputs_cubit_test.dart`, `test/screenshots/audio_routing_screenshots_test.dart` (six goldens for the four tasks and two name pages).
- 26 mutations, each killing only the tests that name it.
- **Review round 1** had six reviewers: correctness, removed behaviour, pen geometry, test quality, and one each on engine PRs #1013 and #1014, which had never been reviewed. It found:
  - Audio routing unreachable on the appliance.
  - The format lock checking one jack instead of both.
  - No clamping of the chosen source or destination to the open device.
  - A route saved on a wider rig that could not be cleared.
  - "Reaches nothing" tested against the raw mask.
  - Jacks beyond the device with no card.
  - A full track's cards drawn live.
  - **Input setup 96 px too low** (screen origin used instead of main-area origin).
  - Clip tail and meter cell sizes, and name row shape.
  - Two vacuous tests.
- The same round fixed slice 2 engine defects and rebased the stack onto the fixes:
  - A perf-log code collision (315 renumbered to 317, pinned by `test_plog_codes_are_distinct`).
  - Session record timing and overdub decay were write-only.
  - Of twelve adversarially verified engine findings, nine were fixed on slices 2a/2b and three refuted.
- Final counts: root 2223 passing and 35 skipped; `looper_repository` 468; `settings_repository` 155; arb files at 1086 keys each.

**Open.**
- The backing source card waits on a backing player; epic #1009 slice 5 covers backing.
- The per-jack output gate question (now a regression, see gotchas).
- No pen note is recorded for the backing departure.
- No re-review after 333324fb is recorded.

---

### 3d. The Mixer view: PR #1021

**Status:** open, review:pending, ci:red. One commit, 2bca71f4.

**What it built.**
- `StageView.mixer` in `lib/looper/cubit/tracks_state.dart` is the third stage view. The view menu is in `stage_top_bar.dart` and the instrument area in `tracks_view.dart`.
- `MixerColumn` (`lib/looper/view/mixer_column.dart`) draws four strips per bank. Each strip has Mute, Solo, FX bypass, a pan bar and a stereo meter.
  - The level marker sits on the meter: drag anywhere in the meter's height sets the level, and a double tap returns to unity.
  - A pan double tap returns to centre.
  - A long press on any Solo clears every Solo.
  - Reset mixer appears only in this view.
- `TrackStereoMeter` (`track_meters.dart`) reads 3a's `peakL`/`peakR` in its own leaf widget.
- `stage_db_scale.dart` takes the insets of the visible view.
- The strip dispatches only 3a events, so no second mixer state exists.

**Decisions** (deviations from the pen):
- **No FX edit button,** because the editor did not exist yet.
- **No Backing & click sheet:** there is no backing player and no click pan.
- **The strip scales as one piece** below the pen's 858 px height.
- The foot Mixer was split out. It is a Mixer action in #763's custom-binding vocabulary, not a fourth mode. This was recorded on #1016 (2026-09-10) and on #763. It is now #1026 part 4n, still unchecked. #763's protocol work landed as #1026 part 4d (PRs #1029/#1030).
- No pen note is recorded for these deviations.

**Verification.**
- Tests: `test/looper/view/tracks_view_test.dart`, and the golden `test/screenshots/goldens/tracks_mixer_window.png` (a panned, a soloed, a muted and an empty track).
- Five mutations: a pan writing every tick, a no-op Solo long press, one side read twice, Reset shown in every view, and a double tap not resetting.
- Counts: root 2253; arb files at 1107 keys.

**Open.**
- **The FX edit button was never added.** `mixer_column.dart` on 3f and at the stack tip still carries the "editor is slice 3f and does not exist yet" comment, although `openFx({FxDestination? destination})` now exists.
- The Backing & click sheet.
- The foot Mixer (#1026 part 4n).
- The ledger's 3d "Not verified here" still describes the foot Mixer as a fourth interaction mode; the issue comment supersedes that.

---

### 3e. FX placement and printing: PR #1022

**Status:** open, review:pending, ci:red.
- Commits: 66249962 (placement), bd6a25e0 (print), 7a29dda1 (live input), 919e337d (All tracks), eda3f9b3 (channel handling), 6ae28ad7 (stopped-track tail fix plus bus pre count), bcb258e9 (design doc), 5a53222d (whole-track render), be987759 (performance_repository fake fix).
- Ledger commits: 7eca3ac2, f114efb4.

**What it built.**

- **Placement per instance.**
  - `FxPlacement` sits on the chain entry (`track_effect.dart` in both `segno_engine` and `looper_repository`), not on `FxAddress`, because bindings persist address + slot id.
  - Chains are stored Pre-first, so the engine sees one boundary, `a_fx_pre_count`. It is pushed with its count: `le_engine_set_lane_fx_count(engine, channel, lane, count, pre_count)` and `le_engine_set_track_fx_count(..., pre_count)`.
  - Every reader clamps pre to the count it read.
  - The write boundary partitions before it clamps, so trailing Post entries are dropped first. The partition is stable.
  - Reorder across the boundary is refused.
  - A placement change removes the entry and appends it at the end of the other stage, keeping slot id, params and enable. It moves by slot id.
  - Post is the wire default and is omitted; the legacy `stage` integer is ignored on decode.
  - Setters: `setLaneEffectPlacement`, `setTrackEffectPlacement`, and `MonitorCubit.setEffectPlacement`. Events: `LooperLaneEffectPlacementChanged`, `LooperTrackEffectPlacementChanged`.
- **The print.**
  - The loop-stage wet cache (`engine_cache.c`, `le_cache_schedule_lane`) renders only the Pre prefix from the lane's dry pool and engages at the lane's loop boundary. The recording is untouched.
  - The key is `le_lane_pre_fx_fingerprint`, with channel handling folded into the print key only, not the chain hash the repository mirrors. A Post edit leaves the print standing.
  - Stop cuts Pre tails through a per-track edge (`proc_prev_state` in `mix_tracks_frame`).
- **Live input.** Record already copies the input chain onto the lane by value; placement now rides that copy. New instances on a live input are Pre.
- **All tracks chain.**
  - Setters: `le_engine_set_all_tracks_fx`, `_count`, `_param`, `_enabled`, `_chain_enabled`, `_channels`.
  - It runs after every track chain and before monitors, click and output chains join.
  - One config, with one `le_fx_state` per output bus.
  - An empty chain is bit-identical to no chain. Entries are always Post.
  - Settings key `all_tracks_fx_chain`; manifest `allTracksChain` at schema v8. Cut clears it.
- **Channel handling per entry.**
  - `FxChannels`: `input` (`FxChannelInput`), `output` (`FxChannelOutput`), `placement` -1..1 (Balance on stereo out, Pan on mono out), and `level`.
  - Setters: `le_engine_set_{lane,track,monitor_input,output,all_tracks}_fx_channels`, four values in one call.
  - Atomic publishes, read from a per-chain cache once per buffer, applied to the entry's feed so a bypass removes them.
  - The pan law moved to the shared header.
- **Whole-track Pre render** (owner direction 2026-09-10; boundary in `docs/design/2026-09-10-whole-track-pre-render.md`, committed on this branch).
  - `LE_CACHE_KIND_TRACK` / `le_cache_schedule_track` renders over the parts' prints: each part's printed material, or dry x level for a chainless part, at its level, mute and pan, summed, then run through the track's Pre run. The result is one stereo buffer, engaged at the track's read position zero.
  - **It renders only while every part's chain is wholly Pre.**
  - A Post entry on a part, a hosted plugin, a budget that does not fit, or a repeated render failure each keep the track live and report the reason through cache telemetry.
  - Engaging removes the parts from the bus; bypassing their slots is not enough.
  - The key is refolded every buffer, never memoised.
  - The cache's graveyard, LRU, budget, shutdown and job accounting were made generic over both entry classes.

**Printing rules as built:**

| Destination (`FxStage`) | New instance | Pre/Post switch | Pre handling |
| --- | --- | --- | --- |
| Live input (`input`) | Pre | yes | the Pre run is what takes record; copied to the lane at record |
| Recorded part (`loop`) | Post | yes | Pre prefix printed from the lane's dry pool, swapped at the lane loop boundary |
| Whole track (`track`) | Post | yes | rendered over the parts' prints, only while every part chain is wholly Pre |
| All tracks (`allTracks`) | Post, forced | no | none |
| Output (`output`) | Post, forced | no | none |

In every row, Post stays live, printed or not, so Post tails can drain past Stop. A cached lane now pays its Post chain's CPU.

**Decisions.**
- **First version forced the whole track to Post.** The 07:32 comment on 2026-09-10 did this and asked the owner for a call.
- **Owner answer: keep the switch** and build a non-destructive render.
- **Boundary set by adversarial review.** The first boundary put the parts' whole chains inside the render. An adversarial design review confirmed 26 objections. The decisive one: flipping the Whole track switch would change what a part's own editor promises. A stored tail region does not solve it, because the tail depends on the stop position.

**Verification.**
- New native tests:
  - Print: `test_only_a_pre_chain_is_printed`, `test_a_post_edit_leaves_the_print_standing`, `test_a_pre_channel_edit_drops_the_print`.
  - Stop tails: `test_stop_cuts_the_pre_tail_with_the_recording`, `test_stop_cuts_the_pre_tail_under_a_post_entry`, `test_stop_spares_the_post_tail_on_a_split_chain`, `test_stop_drains_a_track_tail_with_plain_parts`.
  - Channel handling: `test_fx_entry_channels_and_level`, `test_fx_entry_channels_leave_with_a_bypass`, `test_fx_entry_channel_setter_guards`.
  - All tracks: `test_all_tracks_empty_is_bit_identical`, `test_all_tracks_leaves_live_monitoring_alone`, `test_all_tracks_runs_per_destination`, `test_all_tracks_instances_are_independent`.
  - Whole track: `test_whole_track_pre_processes_the_combination` (two parts at 0.5 through a unity drive give tanh(1.0), not 2 x tanh(0.5)), `test_a_part_post_entry_keeps_the_track_live`, `test_whole_track_pre_stops_and_post_drains`, `test_whole_track_pre_edits_from_the_originals`, `test_whole_track_pre_leaves_the_recording_alone`.
- Dart: `packages/looper_repository/test/models/track_effect_test.dart`, `packages/segno_engine/test/track_effect_test.dart`, `test/audio_setup/cubit/monitor_cubit_test.dart`.
- Twenty mutations. Three tests were rewritten after a mutation survived:
  - the stage-end move needed a stage-mate;
  - the per-destination All tracks test needed a stateful effect;
  - the printability rule needed a part carrying both placements.
- Two claims were withdrawn, including a pan law reconstructed from a truncated file read, which was recovered from git before any commit.
- Defects fixed on the way:
  - A retype re-minted the slot id and powered a bypassed entry back on.
  - All-tracks settled bypasses were applied to the shared config instead of the instances.
  - The idle-track lane skip (#897) routed a stopped track's own Track-stage Post tail nowhere.
  - Cache accounting assumed one mono source.
  - `packages/performance_repository`'s fake engine stopped compiling, so its suite was silently absent (be987759).
- Counts: root 2262 passing and 35 skipped; `looper_repository` 496; `session_repository` 105; `settings_repository` 155; `segno_engine` 283.

**Open.**
- The offline performance renderer models neither the Pre tail cut nor channel handling.
- Playback transforms (Speed, Reverse, pitch preservation, Follow tempo) do not exist, so a render from originals composed with Speed is untested.
- Hardware ports and clipping are not verified.
- No code-review round is recorded on the PR itself.

---

### 3f. FX surfaces and Signal tray retirement: PR #1024

**Status:** open, review:pending, ci:red. Eleven parts in commits 30b38ea6, ff705eb0, 13b82ef4, 1788822e, 86641648, ff2de10b, 5b09279f, 87684b29, 5000a23b, 4219c3fb, and the fix 95dcea0d.

**What it built.**

1. **Destination model (30b38ea6).**
   - `FxStage` is `input / loop / track / allTracks / output`, and `FxStage.master` is gone. `output` carries the bus in `FxAddress.index`; `allTracks` uses index 0.
   - A persisted `master` binding decodes to null and goes inert.
   - The repository holds per-bus maps; for example `outputEffects(bus)`, `outputChainEnabled(bus)`, `outputFxChainFingerprint(bus)`.
   - Settings key `output_fx_chain.<bus>`, with a clear for a destination a load drops.
   - Manifest `outputChains` at schema v9. The v8 `masterChain` and the settings key `master_fx_chain` are no longer read.
   - `PerformanceOutputChain` is recorded per destination in the arm snapshot.
   - Binding pickers offer All tracks and every destination the open device has, labelled by ordinal (`Output 1`).
2. **Effects destinations page (ff705eb0).**
   - `openFx({FxDestination? destination})`.
   - `lib/looper/view/fx/fx_page.dart`, `fx_chain_strip.dart`, `lib/looper/model/fx_destination.dart` (`FxDestination`, `FxDestinationKind`, `FxWholeTrack`, `FxRecordedPart`).
   - `FxCubit` (`lib/looper/cubit/fx_cubit.dart`) holds selection only, with memory per kind.
   - A Sound type row switches between Live inputs (source card and Hear live), Recorded tracks (with All tracks beside the last track, and a part picker that resets to Whole track when the track changes), and Outputs.
   - The chain is drawn as cards joined by plain lines, with a break and no line at the Pre-to-Post boundary.
   - Writes go through each stage's own owner: `MonitorCubit` for inputs, looper bloc per-stage events for the rest.
3. **Chain ceiling (13b82ef4).**
   - `LE_FX_MAX` is 8 -> 64 (`segno_engine_api.h`); Dart `kTrackEffectMax = 64`.
   - The per-buffer snapshot arrays moved from callback locals into `le_fx_snapshot fx_snap` inside `le_engine`, with no atomics.
   - The settle sweep skips slots already parked at bypass.

   | Ceiling | Callback frame | Engine struct |
   | --- | --- | --- |
   | 8 (before) | 32,048 B | 1.27 MB |
   | 64 (naive) | 194,672 B | 4.73 MB |
   | 64 (shipped) | 7,200 B | 4.92 MB |

4. **`packages/fx_catalogue` (1788822e).**
   - Nine families, 159 presets, 66 images (6.3 MB), data and loader only.
   - `FxCatalogueLoader`/`FxCatalogue`, `FxFamily`, `FxPreset`.
   - The family is the folder, not the `type` field. Names are kept verbatim. Every numeric parameter survives the parse.
   - Artwork slugs are mapped in `kFxFamilySlugs`, not derived.
   - Loading is driven by the import manifest, checked against Flutter's asset manifest; a build without assets loads an empty catalogue.
   - It has its own CI job in `.github/workflows/main.yaml`, pinned at 100% coverage.
5. **Module table and readiness (86641648).**
   - `kFxModules` (26 modules) is in `packages/fx_catalogue/lib/src/fx_module.dart`, with `kFxUnclaimedGroups = {'Master', 'Para'}` and `fxModuleArt`. The three source vocabularies disagree (power key `Compressor`, prefix `Comp`, art `Compressor2`), so the table is hand-written.
   - `kFxModuleBuilds`, `fxModuleBuild` and `fxModuleEntry` are in `packages/looper_repository/lib/src/models/fx_module_build.dart`.
   - Six modules map: Delay, Reverb, Overdrive and Distortion (drive), Low-pass filter, Octaver.
   - `FxModuleReadiness` is `full / partial / unavailable`. An unavailable module becomes a `BuiltInEffect` of `TrackEffectType.none` (passthrough) that keeps its `module` name.
   - An unread parameter keeps the engine default.
6. **Add effects (ff2de10b).**
   - `fx_library_page.dart` returns a choice and changes nothing itself.
   - A rack becomes one entry per module in one write (`LooperLaneEffectsAppended`, `LooperBusEffectsAppended`, `LooperAllTracksEffectsAppended`, `MonitorCubit.appendEffects`). Every entry arrives bypassed and takes the destination's default placement.
   - A rack that does not fit states the slots it needs and the slots free.
   - The catalogue loads lazily on the first open of the Effects route.
7. **Effect editor (5b09279f).**
   - `fx_effect_editor.dart` and `fx_editor_parts.dart` (`FxEdits`, `FxParamControl`, `FxChannelFooter`).
   - One control per parameter, each noted "Scale unverified".
   - The Pre/Post segmented switch with its consequence line ("Recorded into loop" / "Can ring after Stop") appears only on inputs, parts and whole tracks.
   - Channel handling is one write (`LooperLaneEffectChannelsChanged`, `LooperBusEffectChannelsChanged`, `LooperAllTracksEffectChannelsChanged`).
   - `LoopOutlinedButton` now draws an inert button as disabled.
8. **Rack model (87684b29).**
   - Chain entries gain `rack` (`FxRack`: id, name, art slug) and `module`. Neither is in the fingerprint.
   - `fxChainGroups` and the transforms in `packages/looper_repository/lib/src/models/fx_chain_group.dart` are the only code that rearranges a chain.
   - Channel handling is read around a group: input on the first module, output side and level on the last.
   - A rack never straddles the loop player.
   - The rack editor is `fx_rack_editor.dart`.
   - Corrections to earlier parts: card artwork height 189 -> 138, and editor titlebars right-aligned.
9. **Rack options and reorder (in 87684b29).**
   - `fx_options_sheet.dart`: Rename (`showConsoleRenameSheet`), Reorder effects, Remove an effect, Remove rack.
   - `fx_reorder_page.dart` holds a local draft; Cancel discards it.
   - The stage is a boundary the reorder cannot cross.
   - A commit is refused if the id list no longer matches the chain.
10. **Saved sounds (5000a23b).**
    - `FxUserPreset` (`fx_user_preset.dart`) and `FxPresetsCubit` (`lib/looper/cubit/fx_presets_cubit.dart`); settings key `fx_user_presets`.
    - A save is a copy: it keeps params, channels and module names, and drops rack, slot ids and placement.
    - The name check is case-insensitive, with a Replace / Use another name prompt.
    - My presets (`fx_saved_list.dart`) lives inside Add effects.
11. **Signal tray retirement (4219c3fb, 95dcea0d).**
    - Deleted `lib/looper/view/signal/` (9 files), `fx_editor/fx_scope.dart`, `fx_plugin_state.dart`, `cache_telemetry_scope.dart`, and the indicator preference (`tracks.indicators`) with its tests and six control-centre screenshots.
    - The rail's Signal row became the Effects route, with the same position and glyph.
    - The tray now lands on Control, and `G` opens the Effects route.
    - The hosted-plugin browser was removed.
    - 95dcea0d gave Remove rack its own confirmation copy.

**Decisions.**
- **Owner calls on 2026-09-11:** the Looper X catalogue ships; the engine ceiling is raised first; the plugin browser is dropped with Signal. Plugin hosting stays in the engine, the repository and the chain model.
- **Rejected by the owner:** connector arrowheads (twice); a dropdown, modal or tooltip for Pre/Post.
- **Accepted-design rules applied:**
  - No invented mappings: reverb brightness is not wired to damping.
  - New instances start bypassed.
- **Owner call on 2026-09-13,** in slice 4: rows use the Looper X art. PR #1045 later moved `fxRackArtAsset` into `fx_catalogue` as `fxFootswitchAsset`.
- **Written to the pen:** `c/signal-domain-retired` under `11 Earlier control & capture notes`. No other 3f departure is recorded as written back.

**Verification.**
- Tests:
  - `packages/fx_catalogue/test/fx_catalogue_test.dart` (11 tests on the real files).
  - `packages/looper_repository/test/models/fx_module_build_test.dart` (11).
  - `fx_chain_group_test.dart` (36).
  - `test/looper/view/fx/fx_page_test.dart`.
  - `test/looper/cubit/fx_presets_cubit_test.dart` (9).
  - `test/screenshots/fx_screenshots_test.dart` (11 screenshots).
  - Native `test_fx_chain_runs_the_full_ceiling`, which fills a chain to `LE_FX_MAX` and refuses the next slot.
- 22 mutations. Three vacuous tests rewritten; one of them had a fixture with default channel handling, which hid the mutation it was meant to catch.
- Defects fixed on the way:
  - `settings_repository`'s suite stopped compiling, so it was silently absent.
  - Two tests stubbed the extension `chainEntriesAt`.
  - FX goldens had captured half-loaded pages before artwork loaded; fixed with `runAsync`.
- Counts: root 2081 passing and 35 skipped, after the Signal tests left. All 21 package suites green. Native suite in all five variants, plus ASan, telemetry-off and the C++ header shim.

**Open.**
- No rack-level bypass bit: rack power writes every pedal, so turning a rack off and on loses per-pedal bypass.
- Import presets, Export all and per-card Export are inert until the USB export domain is built.
- My presets has no original artwork.
- 20 of the 26 modules are passthrough. `Para` is an evidence gap. Parameter scales are unverified (`reference-gates.md`).
- Editor titlebars lack the pedal-assignment chip; the pen draws it but the pedal-binding surface is not built.
- **Hosted plugins:** they cannot be added. The new editors draw parameter controls only for `BuiltInEffect`: `_Parameters` in `fx_effect_editor.dart` returns an empty box for a `PluginEffect`. The issue scope asked for descriptor controls for built-ins and plugins. The sources record no decision about plugin parameters beyond dropping the browser.
- The Mixer FX edit button (see 3d).
- No code-review round is recorded.

---

### Cross-part gotchas

- **Output gate UI removed.**
  - 3c kept the per-jack output gate on purpose; 3f deleted `signal_cards.dart`, its only dispatcher.
  - At the stack tip, `LooperOutputEnabledToggled` is dispatched only from tests.
  - Boot still restores stored disabled outputs (`loadOutputEnabled` in `audio_bootstrap.dart`).
  - The Device tab's `audioNoOutputsBanner` still says "Tap a greyed output to turn it back on", but no such control exists.
- **Unrelated files in 333324fb.** This 3c review commit also changes `macos/Podfile` (platform 10.15 -> 12.0), `macos/Podfile.lock` (drops the `desktop_multi_window` pod) and `macos/Runner.xcodeproj/project.pbxproj`. Its message does not mention them. The same three files are uncommitted edits in the main checkout.
- **Local test runs:**
  - Build `packages/segno_engine/tool/build_test_lib.sh` and export `SEGNO_ENGINE_LIB` before trusting a Dart test count; FFI-gated tests skip silently otherwise.
  - Run every package suite after an interface change or a removal. `performance_repository` (3e) and `settings_repository` (3f) each stopped compiling, and neither the root analyzer nor the root suite reaches package tests.
  - Four fake engines must track the engine interface: `packages/looper_repository/test/helpers/fake_audio_engine.dart`, `packages/performance_repository/test/helpers/fake_performance_engine.dart`, `packages/session_repository/test/helpers/fake_session_engine.dart` and `test/helpers/fake_audio_engine.dart`. `mock_audio_engine.dart` is in `segno_engine/lib`.
- **Snapshot fields:** every new field needs the ABI field-name set in `engine_snapshot_test.dart` and a `copyWith` parameter; two source-level goldens check the latter.
- **Composed mix facts:** facts the repository composes (level x balance, image + track pan) must be projected and saved from its own caches, never read back from the engine.
- **Wire codes:**
  - Ring commands 58 to 67 are taken by 3a/3b.
  - `LE_PLOG_*` values are on-disk codes. Duplicate C enum values compile silently, so pick the next free number and extend `test_plog_codes_are_distinct`.
  - A new atomic op in an engine header reaches VST3 C++ translation units; check it with `clang++ -U__clang__` inside `extern "C"`.
- **Engine rules not to undo:**
  - Cut clears rings inline.
  - Every reader of `a_fx_pre_count` clamps to the count it read.
  - An engaged whole-track render removes the parts from the bus.
  - The whole-track key is refolded every buffer.
  - The Post chain stays live on a printed lane.
  - `rack` and `module` stay out of the fingerprint.
  - The snapshot arrays stay in `le_fx_snapshot`, off the callback stack.
  - A track carrying a Track-stage chain is not idle for the #897 skip.
  - Passthrough modules use chain slots against `LE_FX_MAX`.
- **Test honesty:**
  - Mutation-check each new test by reverting the fix it pins.
  - Delay-ring tests must pre-roll past the ring length.
  - Per-instance state needs a stateful effect.
  - Fixtures need non-default values.
- **Widget tests:**
  - A state push through a mocked bloc stream needs two `tester.pump()` calls.
  - Asset artwork in goldens needs `tester.runAsync`.
  - `chainEntriesAt` is an extension, so do not `when()` it.
  - `[...list]..insert(to, list.removeAt(from))` mutates the original list.
  - Pen-sized rows overflow the 800x600 test surface; wrap them in `ShrinkToWidth`.
- **Pen geometry:** `LoopSettingsFrame` children use main-local coordinates (pen tile y - 168), not screen-local (tile y - 72). This caused the 3c 96 px error.
- **Intentional data drops on upgrade:**
  - Old `master` bindings decode to null.
  - The v8 `masterChain` and settings `master_fx_chain` are not read, so an existing master chain is dropped.
  - Solo is never persisted.
- **Stale records:**
  - The memory notes cite pre-rebase hashes for 3a/3b (3d18d119, 462af371, 6157f005); use the branch hashes above.
  - The 3c memory note says the #1013/#1014 findings are unfixed; the ledger records nine fixed and three refuted.


## 4. Slice 4, parts 4a to 4e: Press/Hold, Pedals setup, Custom controls, protocol v4 and LED colour (#1026, #763)

This section covers PRs #1027, #1028, #1029, #1030, #1031, #1032 and #1034, and issue #763. External pedals (4f) and later parts are covered elsewhere.

### Status at a glance

Every PR is open, unmerged, and carries `stage:in-review` and `autonomy:merge-gate`. `ci:red` on all of them means CI never ran, not that it failed. `.github/workflows/main.yaml` only triggers on `pull_request: branches: [master]`, so a PR based on another feature branch gets no checks. The tests listed below were run locally and reported in the PR bodies.

| Part | PR | Branch -> base | Head | Review label | Areas |
|---|---|---|---|---|---|
| 4a + 4b | #1027 | `claude/segno-slice4-assignments` -> `claude/segno-slice3f-fx-surfaces` | b89342e2 | review:pending | console, pedal |
| 4c | #1028 | `claude/segno-slice4c-pedals-setup` -> `claude/segno-slice4-assignments` | f93a4b6d | review:pending | console, pedal |
| 4d (wire) | #1029 | `claude/pedal-protocol-v4-763` -> `claude/segno-slice4c-pedals-setup` | 3fd9bf05 | review:pending | pedal |
| 4d (app) | #1030 | `claude/custom-controls-mode-763` -> `claude/pedal-protocol-v4-763` | 27efe48a | review:pending | console, pedal |
| 4e (wire) | #1031 | `claude/pedal-v4-colours-763` -> `claude/custom-controls-mode-763` | 424e12d0 | review:pending | pedal |
| 4e (app) | #1032 | `claude/pedal-led-colours-1026` -> `claude/pedal-v4-colours-763` | 1e1dbc60 | review:clean | console, pedal |
| #1033 follow-up | #1034 | `claude/pedal-face-art-1033` -> `claude/pedal-led-colours-1026` | ef50473b | review:clean | console, pedal |

The local branches match `origin` for all seven.

### How the parts were numbered

- #1026 was mapped against the code first, then split into lettered parts. The current issue body lists 4a to 4n.
- #1027 started out as "slice 4 parts 1 and 2". Both its PR body and `docs/plan/2026-09-09-segno-implementation-ledger.md` still use those names (headings "Slice 4 part 1" and "Slice 4 part 2"). The issue checklist calls them 4a (Press/Hold) and 4b (targets by identity).
- When #1028 was written, LED colour was 4d and External pedals was 4e. Its body still says "The LED colors context and the External pedals button are absent until parts 4d and 4e build them".
- Custom controls, the fourth mode from #763, was then inserted as 4d. Every later part moved down one letter: LED colour became 4e, External pedals 4f, MIDI Learn formats 4g, and the performance operations 4h to 4n. The issue body before this edit is not saved locally. The old letters from 4f onward are inferred from the one-letter shift.
- 4d is two PRs: #1029 (wire) and #1030 (app).
- The 4e checkbox names only #1032. #1031, the v4 colour bytes that 4e needs, is labelled only "Part of #763". The memory note counts both as 4e.
- #1034 is not a lettered part. It is the follow-up for issue #1033.
- #763's plan (`docs/plan/2026-08-25-feat-pedal-custom-mode-protocol-v4-plan.md`, merged via #847) has its own slices 1 to 5:
  - Slice 1 (codec) is #1029. Slice 2 (firmware render) was also done in #1029.
  - Slices 3 and 4 (app mode and action targets) are #1030.
  - Slice 5 (an assignment tab on `lib/pedal/view/pedal_assignment_page.dart`) was never built. #1028's Custom controls context took its place.
  - The v4 widening in #1031 is not in the plan's slice list. It came from the owner revisiting D2 on 2026-09-11.

### The model these parts built

**Settings and state**
- `ControlState.pedalSetup` (`PedalSetup`) replaced `ModeSwitchStyle`. It is persisted as an opaque string under `pedal.setup` through `SettingsRepository.loadPedalSetup` / `savePedalSetup`.
- The old key `pedal.mode_switch_style` and `lib/control/mode_switch_style.dart` were deleted, with no migration. A stored old value is ignored.
- The only writer is `ControlCubit.setPedalSetup`. It calls `_invalidateGestures()`, emits, and saves `setup.encode()`.

**`PedalSetup` (`lib/control/binding/pedal_setup.dart`)**
- `modePress` (default `InteractionMode.mute`) and `modeHold` (nullable, default `InteractionMode.custom` since #1030; `fx` in #1028).
- `recordHold`: `RecordHold.none` or `undoRecording` (default).
- `trackHold`: `TrackHold.none`, `armOverdub` (default) or `clearTrack`. One value covers all four track switches.
- `custom`: `Map<PedalBindingKey, ControlGesturePair>`, keyed like the FX remap. Track switches are keyed per bank; Rec/Play, Stop, Undo and Clear are keyed without a bank. MODE and BANK (`PedalBindingKey.unbindable`) are refused by `withCustom`.
- `palette`: `PedalPalette`, added in #1032.
- `customFor(button, bank:)`, `withCustom`, `clearedCustom()` (keeps the Track controls and the palette), `hasCustomAssignments`.
- `encode()` is byte-stable because custom keys are sorted by button index and then bank.
- `PedalSetup.decode` never throws. A blob that is empty or cannot be parsed decodes to `const PedalSetup()`. A present blob without `modeHold` decodes to no hold. Entries this build cannot parse are dropped.
- JSON shape: `{"modePress":"mute","modeHold":"custom","recordHold":"undoRecording","trackHold":"armOverdub","custom":[{"button":"track1","bank":0,"press":"<action key>","hold":"<action key>"}],"palette":{"customs":[{"number":1,"rgb":<int>}],"leds":{"<PedalButton name>":"<entry key>"}}}`. Empty parts are omitted.

**The shared action catalogue (`lib/control/binding/control_action.dart`)**
- Types: sealed `ControlAction` with `ModeAction`, `CommandAction`, `TrackPedalAction`, `SelectTrackAction` and `TrackOperationAction`; `ActionScope` with `SelectedTrackScope`, `AllTracksScope` and `FixedTrackScope(channel)`; `TrackOperation` (mute, solo, clear, undo, redo); `ControlCommand`.
- Functions: `controlActionCatalogue()`, `controlActionsIn(group)`, `controlActionGroups()`. Labels live in `control_action_labels.dart` (`controlActionLabel(l10n, names, action)`, `recordHoldLabel`, `trackHoldLabel`).
- Keys are the stored identity; labels never are:
  - `mode:tracks|mute|fx|custom`
  - `command:record-play|stop|undo|redo|clear-all|cut-sound|record-performance`
  - `bank:next`
  - `track:<0-7>`, `select-track:<0-7>`
  - `direct:<op>:<selected|all|0-7>`
- `direct:clear:all` is refused in `tryParse` and left out of the catalogue: Clear All is `command:clear-all`, one grouped edit.
- `ControlActionGroup` declares `loopModes`, `fx`, `backing` and `sessions`. All four are empty through the end of this range, so a picker skips them.
- The eight performance operations with no engine behind them are absent on purpose.
- The accepted catalogue source is `docs/design/pedal-action-catalogue.js`, which is untracked and exists only in the main checkout.

**ControlCubit press path (`lib/control/cubit/control_cubit.dart`)**
- `_handleEvent`:
  - `ButtonPressed` goes to `_onPress`.
  - `ButtonReleased` calls `_gestures.of(button).cancel()` if `_takeLocked()` is true, otherwise `_gestures.release(button)`. Either way it then calls `_releaseBinding(button)`.
- `_onPress` returns immediately when the take lock is on. Otherwise:
  1. In `InteractionMode.custom`, every switch except MODE and BANK goes to `_armCustom`.
  2. In FX mode, a bound switch goes to `_armBoundHold` if it has a hold, else `_pressBinding`. Stop still arms `_armStopRestore`.
  3. Every other case goes through the per-button switch:
     - Undo: `_armUndo`, not in FX.
     - Rec/Play: `recPlay()`, then `_armRecordHold()`.
     - Stop: `stop()`, or `_armStop()` in FX.
     - MODE: `_armMode()`.
     - BANK: `toggleBankWithCursor()` only.
     - Clear: `_onClear()`, not in FX.
     - Track switches: `trackPressed(channel)`, then `_armTrackHold`.
- `_HoldGesture.press(threshold, generation, onHold, onTap?)`:
  - The threshold is `pedal.long_press_ms`, default 500 ms.
  - The hold fires when the threshold passes and discards the tap.
  - `release(generation)` runs the tap only if the generation still matches.
- `_Gestures` keeps one gesture per `PedalButton`. `cancelAll()` increments the generation.
- `_invalidateGestures()` runs `cancelAll()` and `releaseAllMomentary()`. It is called from `setPedalSetup`, `setMode`, `setGlobalBindings`, `applySessionBindings` and `_onBindStatus` (unbind).
- `_runAction(ControlAction)` is the one interpreter of the catalogue. Later external and MIDI parts call it too.

**LED contract (#1032)**
- `PedalStateFrame.isLit(button)` decides whether an indicator is lit. `colorFor(button)` / `pedalColors` decide its hue.
- The firmware twin is `indicatorFor(button)` in both sketches. The on-screen twin is `_indicator(surface, frame, button)` in `lib/pedal/view/pedal_plate.dart`.
- Screens read the pushed frame from `PedalRepository.lastFrame`. They never re-project one.

---

### 4a + 4b. Press and Hold as separate actions; the selected-track scope (PR #1027)

`claude/segno-slice4-assignments` -> `claude/segno-slice3f-fx-surfaces`. Open, review:pending, ci:red (not run). Commits: ab09dfb4 (Press/Hold), b89342e2 (scope).

**What it built**
- **Holds on FX remap bindings.** `PedalBinding` gained `holdTarget`, `holdBehavior`, `holdScope` and `scope`, plus `hasHold`, `decodeHoldTarget()` and `copyWith(clearHold:)`.
  - JSON keys: `holdTarget` / `holdBehavior` / `holdScope`, written only when a hold exists. `scope` and `holdScope` are omitted when `fixed`, so older encodings are unchanged.
- **Hold eligibility.** `PedalBindingKey.holdable` is the four track switches only. `PedalBinding.canHold(key, behavior)` also refuses a momentary press.
  - A persisted hold on an ineligible switch is dropped in `fromJson`, and the press is kept.
  - Changing a press to momentary drops its hold.
- **Deferred press.** A bound switch that has a hold moves its press to the release (`_armBoundHold`). Firing the hold discards the tap.
- **One place to cancel.** The four hand-wired hold fields (undo, MODE, BANK, Stop-in-FX) were replaced by the `_Gestures` registry, with a generation counter and the one cancel point `_invalidateGestures()`.
- **Scope beside the target.** New `lib/control/binding/binding_scope.dart`:
  - `BindingScope.fixed` / `selected`. `fromName` falls back to `fixed`.
  - `resolveBindingAddress(address, scope, cursor)` repoints only `FxStage.loop` and `FxStage.track`, and keeps the lane. Input, output and allTracks are used as written.
  - `ControlCubit._scoped(target, scope)` resolves when the action fires, not at press.
- **Two bugs fixed.** Unbinding the pedal left hold timers armed. The take lock covered presses but not releases. `_handleEvent` now cancels the gesture on a locked release but still restores a held momentary.

**Decisions**
- Rec/Play and Stop keep immediate contact. Undo, Stop, MODE and BANK keep their system long-press. Clear gets no hold. All of these come from the accepted design, controls 1 and 3.
- A track's identity is its engine channel, because tracks are never reordered. No new id was added.
- "Target following" is simply resolving at dispatch. A pending hold reads the cursor when it fires, and the momentary restore captures the resolved target.
- The all-track scope was deferred to the catalogue. #1028 added it as `AllTracksScope`.
- controller_repository was not changed. Several actions on one control was moved to 4f (external) and 4g (MIDI).
- The gesture rules are not in `controlInvariants`, because invariants check settled states and a hold is timing between states (recorded in the ledger).

**Verification**
- Tests: `test/control/binding/binding_scope_test.dart`, `test/control/binding/pedal_binding_hold_test.dart`, `test/control/control_cubit_test.dart` (+265 lines). That is 18 model tests and 10 cubit tests.
- Root suite 2110 passing, 35 skipped; analyze and bloc lint clean.
- Five mutations, each caught by the test named for it: a press that never defers, an invalidation that cancels nothing, a lock that stops at the press, a resolver that never repoints, and a hold resolved at press.
- No /code-review round is recorded.

**Open items**
- Physical footswitch evidence: not verified.
- review:pending.
- The implementation ledger documents only this PR's two parts. Nothing from 4c onward was added to it.

---

### 4c. Pedals setup, Layout A, and the shared action catalogue (PR #1028)

`claude/segno-slice4c-pedals-setup` -> `claude/segno-slice4-assignments`. Open, review:pending, ci:red (not run). Commits:
- 8123a162 (feature)
- b6ab43b9 (test: a track hold stays out of FX mode)
- f93a4b6d (perf: `PedalSetup.props` is an ordered field list instead of `encode()`; the Track controls map always shows bank A)

**What it built**
- **The page.** `PedalSetupPage` (`lib/control/view/pedal_setup/pedal_setup_page.dart`):
  - Route `segno/pedal-setup`, opened by `openPedalSetup()` in `lib/app/segno_navigator.dart`.
  - Entry point: the row `Key('pedal_open_setup')` at the top of `PedalTrayBody`, the Control face's Pedal tab. The old FX-hold switch row was removed from that tab.
  - Pen insets: `_left` 100, `_controlsTop` 120, `_mapTop` 218, `_editorTop` 724.
- **Contexts** (`PedalSetupContext`):
  - `tracks` (Track controls): MODE press and hold pickers, the Rec/Play hold, and one group hold for the four track caps, which are selected together via `_selectedGroup`. Stop, Undo, Clear and Bank are dimmed and show what they do (`pedalSetupFixedNote`).
  - `custom` (Custom controls): every switch except MODE and BANK, each with a press/hold pair from the catalogue. Track caps get one pair per bank, and BANK pages the map only in this context.
- **Widgets.** `PedalSetupMap` / `PedalSetupCap` (`pedal_setup_map.dart`), `PedalSetupEditor` / `PedalSetupField` / `PedalSetupEditorFrame` (`pedal_setup_editor.dart`), and `showPedalChoicePicker<T>` with `PedalChoiceGroup` / `PedalChoiceResult` (`pedal_choice_picker.dart`). #1035 later added `showControlActionPicker`.
- **Draft.** `_draft` is local and nullable. It is forked from the live setup on the first edit.
  - Save calls `control.setPedalSetup(draft)`. Cancel drops the draft.
  - Clear custom assignments asks for confirmation (`showPedalClearDialog`), then stores `_cleared` and offers Restore.
  - The page has no `PopScope`, so Back discards an unsaved draft.
- **MODE, Rec/Play and track holds in the cubit.**
  - `_armMode` with no hold enters `modePress` on contact. With a hold it arms a gesture. `_enterMode(mode)` does `setMode(state.mode == mode ? record : mode)`.
  - `_armRecordHold` runs `undo(channel)` with the channel captured at press. `_armTrackHold` / `_runTrackHold`: `armOverdub` calls `_looper.record` only if the track has content; `clearTrack` calls `_looper.clear`.
  - Neither is armed in FX mode.
  - BANK now only pages.
  - `toggleMode()` (keyboard `M`, on-screen chip) keeps a cycle and is not driven by the setup.
- **Removed.** `_fxReturn`, `_pedalModeTap`, `_toggleFxHold`, `_armBank`, `setModeSwitchStyle`.

**Decisions**
- `ModeSwitchStyle` was retired into the MODE pair, so that only one place decides what MODE means. A press or hold enters the mode it names and leaves it if the rig is already there, so nothing a foot can do strands the rig.
- Side effect, recorded on #763: the foot lost its only way to arm a performance recording (it was the MODE hold) until #1030.
- Catalogue keys are identity. A key that does not parse reads as unassigned.
- **Departures from the pen**, recorded in a `c/ Implementation · slice 4c` note in the pen's `08 Pedal setup & LEDs` section:
  - Caps drawn as simple shapes instead of the metal art. Replaced by #1034.
  - Setup opened from the Control face's Pedal tab instead of a Settings tile grid. A ninth tray rail row was tried and reverted because it removed the spacer above Brightness that `settings_tray_test` checks.
  - LED colors context and External pedals button absent. Built in #1032 and #1035.
  - Mode picker offers Exit, Mute and FX. Custom was added in #1030; Tuner is not built.
  - Double press (Solo) field deferred to the optional controls.
  - None is the first item of the first picker group instead of its own tab.
- No commit in the stack touches `segno-ui.pen`. The note exists only in the main checkout's uncommitted pen and was not re-read for this handoff. It has not been updated for #1032 or #1034.

**Verification**
- Tests: `test/control/binding/control_action_test.dart`, `test/control/binding/pedal_setup_test.dart`, `test/control/pedal_setup_page_test.dart`, `control_cubit_test.dart` (rewritten for the pair), `packages/settings_repository/test/settings_repository_test.dart`. `ModeSwitchStyle` tests were removed from `control_face_test.dart`.
- Screenshots: `test/screenshots/pedal_setup_screenshots_test.dart`, with goldens `pedal_setup_tracks`, `pedal_setup_tracks_group`, `pedal_setup_custom_bank_b`, `pedal_setup_picker` and `pedal_setup_clear`. Goldens `control_center_control_pedal`, `control_center_control_pedal_bank_b` and `control_center_tray` were regenerated.
- Root suite 2152 passing, 35 skipped. All 21 package suites green. `dart analyze --fatal-infos` clean on the app and settings_repository; bloc lint clean.
- 11 mutations. One survived (no test covered the FX guard on the track hold), and b6ab43b9 adds that test.

**Open items**
- review:pending.
- Tuner mode and the Double press (Solo) field are not built. The sources do not record where Tuner is tracked.
- The `fx`, `loopModes`, `backing` and `sessions` catalogue groups are empty.
- Physical footswitch: not verified.

---

### 4d, wire half. Protocol v4 unreserves the mode field's fourth value (PR #1029)

`claude/pedal-protocol-v4-763` -> `claude/segno-slice4c-pedals-setup`. Open, review:pending, ci:red (not run). Commit 3fd9bf05. Part of #763, plan slice 1 (with slice 2 included).

**What it built**
- **C, both copies identical.** `firmware/segno_pedal/pedal_protocol.{h,c}` and `hardware/firmware/segno_pedal_32u4/pedal_protocol.{h,c}`:
  - `PEDAL_PROTOCOL_VERSION_V4 0x04`, and `PEDAL_PROTOCOL_VERSION` (newest) set to V4.
  - `PEDAL_MODE_CUSTOM = 3`, `PEDAL_MODE_COUNT = 4`.
  - `pedal_encode_frame` accepts V1 to V4 and writes custom as `PEDAL_MODE_PLAY` below v4.
  - `pedal_decode_frame` accepts up to V4 and rejects mode 3 below v4.
- **Dart.** `PedalMode.custom`, `PedalCodec.protocolVersionV4`, and `protocolVersionMax` set to V4, with the same degrade and rejection rules in `packages/pedal_repository/lib/src/pedal_codec.dart`. The codec's default encode version stays v2 (the unknown-firmware floor).
- **Mode LED colour.** Amber was added in three places: `modeColor` in both sketches and `_modeColor` in `pedal_plate.dart`. #1032 removed all three (see there).
- **Fixtures.** `custom_mode_v4.syx` and `custom_mode_v3.syx`, from `goldenFrames()` / `explicitVersionGoldenFrames()` in `test/helpers/golden_frames.dart`. They are generated by `packages/pedal_repository/tool/generate_golden_fixtures.dart`, which also writes `MANIFEST.md`.

**Decisions**
- D2 as approved on 2026-08-26 at the time: zero growth, 17-byte payload. A spare-value approach was impossible because every deployed v3 decoder rejects mode 3 and would blank the pedal.
- Custom falls back to mute below v4, so an un-reflashed pedal shows the wrong mode LED but keeps its LEDs.
- No app-side mode in this PR.
- `PedalCubit.selectFirmwareVersion` has no UI caller, so a real pedal still encodes at v2. Only the simulator, which uses the highest version, renders custom.

**Verification**
- `bash firmware/test/run_tests.sh` green against both copies, including the custom round trip, the version gate (a v4 frame with its version byte changed to v3), and the downgrade twin.
- Existing fixture bytes are unchanged.
- `pedal_repository` suite green, with `pedal_codec_test.dart` extended. `test/pedal/view/pedal_plate_test.dart` now checks every mode's colour, not only FX.
- Root suite green; analyze clean.

**Open items**
- Not verified on real LEDs.
- The console's actual pedal controller is a Pico 2 / RP2350 on console board v2, linked over UART (Pico uart0 GP16/17 to Pi uart3 GPIO8/9) and flashed over SWD from Pi GPIO24/25. It has no firmware in the repo and no UART `PedalTransport` exists. When written, that firmware needs its own `indicatorFor` (originally recorded as `modeColor`), and `run_tests.sh` will not catch drift in it.
- review:pending.

---

### 4d, app half. Custom controls, the fourth mode (PR #1030)

`claude/custom-controls-mode-763` -> `claude/pedal-protocol-v4-763`. Open, review:pending, ci:red (not run). Commit 27efe48a. Part of #763 (plan slices 3 and 4) and #1026 part 4d.

**What it built**
- **The mode.** `InteractionMode.custom` in `lib/looper/model/interaction_mode.dart`:
  - Excluded from `bootDefaults`; `bootDefaultFromToken` turns a stored `custom` into `record` (R12).
  - `setMode(custom)` clears `excluded` and `parkedResume` and has no other side effects.
  - `toggleMode()` now cycles record -> mute -> fx -> custom -> record.
- **Dispatch.**
  - `_armCustom(button)` reads the pair for the active bank, captured at press. Press only: `_runAction` on contact. With a hold: a gesture whose tap (the press) runs on release.
  - An unassigned switch does nothing. MODE and BANK keep their normal handling.
  - `_runAction` covers `ModeAction` -> `_enterMode`, `CommandAction` -> `_runCommand`, `TrackPedalAction` -> `selectTrack` + `_recAdvance`, `SelectTrackAction` -> `selectTrack`, and `TrackOperationAction` -> `_runTrackOperation` for each channel in `_channelsIn(scope)`.
  - The scope is resolved when the action runs.
  - `command:record-play` / `command:stop` run the Tracks-mode actions (`_recAdvance` / `_recStop` on the cursor), because in custom mode the switches' own actions do nothing.
- **Built-in paths do nothing in custom mode:** `recPlay()`, `stop()` and `trackPressed()`. On screen, `TrackColumn`, `WaveTrackRow` and `TracksCommands` digit keys only select the track.
- **LEDs.** The `projectTrackLed` custom case returns `PedalTrackLed.blue` when the switch driving that channel has a non-empty pair for that bank. `projectFrame` maps to `PedalMode.custom`.
  - New invariant `custom-led-mirrors-assignment` in `lib/control/invariants.dart`. `empty-track-dark` now skips custom mode.
- **Defaults and theme.** The MODE default is now Mute on the press and Custom on the hold (`PedalSetup.modeHold = InteractionMode.custom`). `ModeAction` token `custom` was added. Readout word `readoutFunctionCustom` (`console_readout_view.dart`). Mode colour amber (`SurfaceTheme`, outline `ledAmber`). Meters use the mute colour table. New l10n strings for accessibility labels and plate LEDs (`a11yModeCustom`, `a11yTrackTileCustom`, `pedalSimLedAssigned` / `pedalSimLedUnassigned`).

**Decisions**
- An unassigned switch does nothing rather than guessing, because custom mode has no contextual defaults.
- The LEDs report whether the switch carries an assignment, not track state, because most catalogue actions have no on/off state to show.
- On-screen tiles do not run footswitch assignments.
- **Departures from #763's plan:**
  - D4 said the MODE stomp cycles through custom. Since #1028 the pedal's MODE is a press/hold pair; only the keyboard and chip cycle.
  - D1 approved FX targets plus named app actions. Only named app actions exist; `ControlActionGroup.fx` is empty.
  - The plan's "new persistence key" for custom bindings became the `custom` list inside `pedal.setup`.
- Closes the performance-recording gap from #1028 (`command:record-performance`).

**Verification**
- Tests: `control_cubit_test.dart` (+305 lines), `test/fuzz/control_sequence_fuzz_test.dart`, `test/looper/view/tracks_view_test.dart`, `pedal_setup_test.dart`, `pedal_setup_page_test.dart`; golden `pedal_setup_tracks.png` regenerated.
- Fuzzer: custom is reachable through the existing `_ToggleMode` action, so no new action type was added. Two corpus cases that tapped MODE to walk the old three-stop cycle were rewritten to use `_SetMode`.
- Root suite 2193 passing, 6 skipped, with the engine test library built so FFI tests run. 21 package suites, firmware suite, native suite and bloc lint green.
- Four mutations, three caught. The survivor reads the pair live at dispatch instead of capturing it at press. It changes nothing because `setPedalSetup` retires every pending gesture. The doc comment on `_armCustom` now says the capture is kept for consistency, not as the enforcement.

**Open items**
- FX targets in the Custom map (D1); rack targets are deferred to #535.
- The manual firmware-version picker from D3 has no UI.
- Physical feel and the mode LED on real hardware: not verified.
- review:pending.

---

### 4e, wire half. v4 carries a colour per footswitch; decoder length bound (PR #1031)

`claude/pedal-v4-colours-763` -> `claude/custom-controls-mode-763`. Open, review:pending, ci:red (not run). Commit 424e12d0. Part of #763.

**What it built**
- **30 bytes appended at v4:** one RGB triplet per footswitch, indexed by `PedalButton` / `PEDAL_BTN_*`.
  - The v4 payload is 47 bytes and the packed frame 60 bytes; v3 and below stay at 26.
  - C: `pedal_color` struct, `pedal_frame.pedal_colors[PEDAL_BTN_COUNT]`, `PEDAL_PAYLOAD_LEN_V4`, `PEDAL_PACKED_MAX`, and `PEDAL_FRAME_MAX_BYTES` raised from 32 to 64.
  - Dart: new `PedalColor` in `packages/pedal_repository/lib/src/pedal_color.dart` (a plain r/g/b value type, not Flutter's `Color`), plus `PedalStateFrame.pedalColors` (asserts 10 entries), `colorFor`, `defaultPedalColors`, `tracksPerBank`.
- **Length rules.** A v4 frame must carry exactly the v4 payload; a truncated v4 frame is rejected. Below v4, colours decode as `PedalColor.defaultColor`.
- **Security fix, predates v4.** `pedal_unpack7` wrote into a fixed stack buffer using a length taken unchecked from the wire. Both C copies now reject `packed_len > PEDAL_PACKED_MAX` before unpacking. Dart applies the same check (`_packedMax`), which there limits work rather than preventing an overflow.
- **Sanitizers.** `run_tests.sh` now builds the contract test with `-fsanitize=address,undefined`. With the guard removed, the suite reports `stack-buffer-overflow` in `pedal_unpack7`.
- **Fixtures.** `pedal_colors_v4.syx` / `pedal_colors_v3.syx` use ten distinct hues. `custom_mode_v4.syx` grew from 26 to 60 bytes. Every pre-v4 fixture is byte-identical.

**Decisions**
- Owner call, 2026-09-11 (comment on #763): D2 was widened. Its premise (six single LEDs, #792) had been stale since #930 changed the faceplate to ten 8-LED colour pills. v4 was widened instead of adding a v5 because v4 has not been flashed anywhere. The non-goal "no payload growth" was lifted for this change only.
- Raw RGB instead of a palette index: exact colours, a small cost at this frame rate, and no palette state on the pedal that could go stale.
- How configured colour combines with a fixed pedal's own signal was left open here and answered in #1032.

**Verification**
- Firmware suite green against both copies under the sanitizers, with new test cases for the colour array, a truncated v4 frame and an over-long body.
- `pedal_codec_test.dart` +71 lines. Root suite green; analyze and bloc lint clean.
- Three mutations, two caught. Removing the Dart bound cannot fail a test, because Dart cannot overflow there; the check is covered in C under ASan instead.

**Open items**
- No gate compiles the sketches (#1032 compiled them by hand).
- review:pending.

---

### 4e, app half. The ten indicators take the performer's colours (PR #1032)

`claude/pedal-led-colours-1026` -> `claude/pedal-v4-colours-763`. Open, **review:clean**, ci:red (not run). Commits: 29e5f89e (feature), 1e1dbc60 (fixes from review). Part of #1026 and #763.

**What it built**
- **Palette model** (`lib/control/binding/pedal_palette.dart`):
  - `PedalPaletteColor`: eight built-ins (white E6EEF9, amber EFBC72, red EE6B70, orange EF9666, green 7ACB9E, cyan 73CFDF, blue 82AAFF, violet B19AFA), defined in `PedalColor`.
  - Sealed `PedalPaletteEntry`: `BuiltInPaletteEntry` (key is the colour name) and `CustomPaletteEntry(number)` (key `custom:N`).
  - `PedalPalette(customs, choices)`: `entryFor`, `colorFor`, `colorOf`, `frameColors`, `withChoice` (choosing the default removes the entry), `withCustom`, `nextCustomNumber` (lowest free), `isEmpty`, `toJson` / `fromJson`.
  - There is no way to remove a mixed colour in the model or the editor.
- **Stored in `PedalSetup.palette`.** `clearedCustom()` keeps it.
- **Page.** New context `PedalSetupContext.leds` covers all ten switches with no bank. `PedalLedEditor` (`pedal_led_editor.dart`) shows all swatches, plus Add and Edit color. `showPedalColorDialog` (`pedal_color_dialog.dart`) is a Hue/Saturation/Brightness editor with a live swatch and hex readout; `pedalColorFromHsv` converts. `PedalColorDisplay.display` (`lib/common/pedal_color_display.dart`) converts to a Flutter `Color`.
- **Projection.** `projectFrame` sets `pedalColors: overlay.pedalSetup.palette.frameColors`.
- **Lit rules** in `PedalStateFrame.isLit`:

  | Switch | Lit when |
  |---|---|
  | Rec/Play | `globalColor` is red or amber (a live take) |
  | Stop, Undo | never |
  | MODE | `mode != PedalMode.rec` (dark in Tracks) |
  | Track 1-4 | `trackLeds[activeBank*4 + slot] != off` |
  | Clear | `clearFadeActive` |
  | Bank | `activeBank == 1` |
  | any | never on the goodbye frame |

- **Firmware.** `indicatorFor(button)` replaces `ledColor` and `modeColor` in both sketches. `run_tests.sh` now compares `indicatorFor globalColor scaled` token by token.
- **Default colour.** `PEDAL_COLOR_DEFAULT_*` changed from 0xFF to 0xE6/0xEE/0xF9, matching `PedalColor.white`, and `custom_mode_v4.syx` was regenerated.
- **Plate.** `_ledColor` and `_modeColor` were deleted from `pedal_plate.dart` and replaced by `_indicator`. The amber mode LED from #1029 no longer exists on either side; amber remains only as the on-screen mode colour.
- **`PedalRepository.lastFrame`** (`ValueListenable<PedalStateFrame>`) is published on every `pushState`, whether or not a pedal is bound. `PedalSetupPage` reads it through `ValueListenableBuilder`. The map shows the draft palette but takes lit state from the rig.
- **Restore fix.** Restore after Clear used to put back the whole draft, overwriting a colour picked after the clear. It now puts back only the cleared assignments (`_cleared` is a `Map<PedalBindingKey, ControlGesturePair>`), as `docs/design/2026-09-08-pedal-closure-pass.md` requires.

**Decisions**
- State decides lit; the palette decides hue. Sources: `accepted-behavior.md` section 4 ("LEDs represent function state ... Color is configurable on all ten") and the pen scenes `03 / Pedals / LED colors` and `04 / LED colors — Toggle active`.
- A custom colour is a reference, so editing it changes every switch that uses it.
- A new colour opens in the middle of the HSV space, because white has no hue or saturation to start sliders from.
- Stated consequence, told to the owner and **not ruled on**: a lit track indicator no longer shows playing versus recording, and the default palette is white on all ten. A rule where recording overrides the configured colour would be a one-line precedence rule. Recorded on #1026 (comment 2026-09-12).
- Superseded plan item: #763's acceptance criterion "MODE LED says custom distinctly" no longer holds. MODE is lit in every mode except Tracks, in the performer's colour.

**Verification**
- Tests:
  - `packages/pedal_repository/test/pedal_color_test.dart`, `pedal_state_frame_test.dart` (group "indicator state")
  - `test/control/binding/pedal_palette_test.dart`, `pedal_setup_test.dart`, `test/control/control_projection_test.dart`
  - `test/control/pedal_color_dialog_test.dart`, including an HSV -> RGB round trip for every built-in and every corner of the RGB cube
  - `pedal_setup_page_test.dart` (group "LED colors"), `pedal_plate_test.dart`
- New goldens: `pedal_setup_leds`, `pedal_setup_leds_custom`, `pedal_setup_color_editor`. 68 screenshot goldens passing.
- Root suite 2200 passing, 35 skipped; `pedal_repository` 199 passing.
- Firmware suite green under ASan/UBSan. Both sketches compiled by hand: 32u4 17020 bytes, UNO 9654 bytes.
- Five mutations, five caught.
- **Review round (1e1dbc60):**
  - The map re-projected a frame from `LooperBloc` state plus the control overlay. `projectFrame` runs the invariant checks, and `stored-intent-playable` checks the pair, so a clear arriving while the screen was open threw inside `build`. Fixed by reading `lastFrame`.
  - A lit pill had a dark rim.
  - A doc comment claimed the hex value could be typed in; nothing offers that.
  - The drift-gate comment was repaired.

**Open items**
- Owner ruling on a recording hue.
- Physical LEDs: the console's pills have no driver, and the standalone pedal has indicators for only seven of its ten switches. How the eight hues look on a WS2812 at stage distance is a bench question.
- The Pico 2 firmware must implement `indicatorFor`.

---

### Follow-up to #1033. The Pedals setup map draws the footswitch (PR #1034)

`claude/pedal-face-art-1033` -> `claude/pedal-led-colours-1026`. Open, **review:clean**, ci:red (not run). Commits: e05c109e (feature), ef50473b (fixes from review). Closes #1033 when merged.

**What it built**
- `lib/common/pedal_face.dart`:
  - `PedalFace(selected, legend)`, authored in an 84 x 114 box (`artSize`), with `namePlate` rect, `labelInk`, and `widthFor(height)`.
  - `PedalFacePainter` draws: tapered body with a four-stop gradient, two hinges, left and right rolled edges, a rubber pad with 30 grips on a 6 x 5 grid, and a trapezoid nameplate. The selected state uses brighter metal and a lit edge.
- `PedalSetupCap` now draws `PedalFace`. Dimmed switches are an `Opacity` of `surface.disabledOpacity` over the face, and the LED pill stays separate.
- Four design sources committed (about 41 KB): `docs/design/pedal-hardware-widget.js`, `docs/design/pedal-hardware/README.md`, `geometry.json`, `labels.json`.
- `test/theme/token_adoption_test.dart` allowlists the art file, because the metal colours are the hardware's own.

**Decisions**
- Every outline was transcribed from the JS study's path constants. No SVG dependency was added.
- The nameplate is app text, not the `labels.json` ink outlines. Those exist only for TRACK1 to TRACK4, and the map shows TRACK 5 to 8 on bank B.
- The faceplate simulator (`lib/pedal/view/pedal_plate.dart`) is untouched and still draws simplified switches.
- Root causes recorded on #1033:
  - The pencil MCP returns every path's `geometry` as `"..."`, so the pen's outlines cannot be read.
  - `docs/design` is untracked, so a worktree cannot see the study.
  - 4c recorded the simplification only in a source comment instead of the pen.

**Verification**
- `test/common/pedal_face_test.dart`:
  - "every outline the study draws is quoted in the port": reads the JS file and fails if any of its seven outlines is missing from the Dart source.
  - Grip grid, proportions, repaint only on selection change, legend placement.
- Coordinates under each quoted outline are checked only by the Pedals setup goldens, which run on the author's machine only.
- All eight `pedal_setup_*` goldens regenerated and checked by eye. Root suite 2208 passing, 35 skipped; analyze and bloc lint clean.
- One mutation (a changed coordinate), caught by the transcription test.
- **Review round (ef50473b):** body stroked after the rolled edges (wrong paint order), nameplate scaled on one axis only, outlines rebuilt on every paint, and 30 grip shaders per face (300 per repaint with ten faces).

**Open items**
- The rest of `docs/design` (226 MB, untracked) is the owner's call and has not been asked.
- The simulator should eventually use this painter.
- Stale text: the `PedalSetupCap` doc comment still says "Shapes, not an illustration", and the pen's `c/ Implementation · slice 4c` note still lists geometry caps as a departure.

---

### Issue #763 (custom pedal mode + protocol v4): where it stands

Open, and still the umbrella for #1029 to #1032. None of them closes it.

- **Directions approved 2026-08-26:**
  - D1: FX targets plus named app actions; rack targets later with #535.
  - D2: zero-growth v4. Revised 2026-09-11 to add the 30 colour bytes.
  - D3: manual version picker now.
  - D4: custom joins the MODE cycle and is excluded from boot.
- **Built:** the v4 wire (both C copies, Dart codec, fixtures), `InteractionMode.custom` with dispatch and LEDs, named app actions through the shared catalogue, and the per-footswitch colours.
- **Not built:**
  - FX targets in the Custom map (`ControlActionGroup.fx` is empty).
  - UI for `selectFirmwareVersion`, so real pedals stay at v2.
  - Identity discovery and inbound SysEx.
  - Pico 2 firmware and a UART `PedalTransport`.
  - Rack targets (#535).
- **Dependency:** the foot half of the Mixer (#1016 part 3d, now #1026 part 4n) enters the Mixer from a custom pedal assignment. It needs a catalogue action, not a fifth wire mode (comment 2026-09-10).

---

### Gotchas for this area

- **Stale sources.**
  - The memory note's line "Amber is the mode colour in all three sites" and the plan's slice 2 describe #1029 only. #1032 removed `modeColor` and `_modeColor`; amber remains only as the on-screen mode colour (`SurfaceTheme`).
  - The ledger covers only 4a/4b.
  - The pen note and the `PedalSetupCap` doc comment predate #1034.
- **Two scope types.** `BindingScope` (fixed/selected, on FX remap `PedalBinding`s, #1027) and `ActionScope` (selected/all/fixed channel, on catalogue actions, #1028) are different types. Only `ActionScope` has all-tracks.
- **Two hold rules.**
  - FX remap: `PedalBindingKey.holdable`, the four track switches, not momentary.
  - Custom controls: `ControlGesturePair` allows a hold on any of the eight switches except MODE and BANK. In Custom mode, a hold on Rec/Play or Stop moves that switch's press to the release.
- **Two mode tokens.** `ModeAction.token` says `tracks` where `InteractionMode.token` says `record`. Use the first for catalogue keys and the second for the default-mode setting.
- **`modeHold` decoding.** A setup saved by a #1028 build stores `modeHold: "fx"` and keeps it. Only a missing or unparseable blob gets the Custom default. A present blob without `modeHold` decodes to no hold.
- **Every setup change goes through `setPedalSetup`.** It retires pending gestures. A new path that changes what switches mean must call `_invalidateGestures()`. Release handling must respect `_takeLocked()`.
- **Do not project frames in widgets.** Calling `projectFrame` in a widget can throw the invariant assert in debug. Read `PedalRepository.lastFrame`. A `ValueListenable` getter on `ControlCubit` fails bloc lint (`avoid_flutter_imports`, `prefer_void_public_cubit_methods`).
- **`PedalSetup.props` must stay a field list, not `encode()`.** Equality runs on every state emit.
- **The two protocol copies must be byte-identical.** Edit `firmware/segno_pedal/` and copy the files to `hardware/firmware/segno_pedal_32u4/`.
  - Changing the default colour means changing `PedalColor.white`, `PEDAL_COLOR_DEFAULT_*` in both copies, and regenerating fixtures with `packages/pedal_repository/tool/generate_golden_fixtures.dart`.
  - `run_tests.sh` checks the protocol files and the sketches' `indicatorFor` / `globalColor` / `scaled`. It does not compile the sketches and cannot cover a future Pico 2 firmware.
- **Nothing selects v4 for a real pedal.** On hardware, custom falls back to mute and the colours are not sent. Only the simulator shows v4 behaviour.
- **Design sources are only in the main checkout.** Most of `docs/design` (including `pedal-action-catalogue.js` and the pedal UX docs) is untracked, and `segno-ui.pen` edits are uncommitted. A worktree sees neither. The pencil MCP cannot return path geometry.
- **Goldens run only on the author's machine.** `pedal_setup_*` goldens are skipped elsewhere, and they are the only check on the face outline coordinates. Regenerate them and check by eye after any change to the map.
- **Fuzzer.** Custom is reached through `_ToggleMode`. MODE on the pedal is a pair, not a cycle, so a corpus case that taps MODE to walk through modes is wrong.
- **Tray layout.** A ninth tray rail row does not fit (`settings_tray_test`). Pedals setup is opened from the `pedal_open_setup` row on the Control face's Pedal tab.
- **CI.** Stacked PRs get no CI. Before merging, retarget each PR to master in order and let CI run.


## 5. Slice 4 part 4f: External pedals (CTRL 1 / CTRL 2)

Part 4f of #1026 is seven stacked PRs, #1035 to #1045. All are open with `stage:in-review`, `autonomy:merge-gate`, `review:clean` and `ci:red`. They are red because they are stacked: repository CI runs only after a PR is retargeted to master. All checks listed below were run locally. #1026's comments of 2026-09-13 mark 4f complete. Nothing physical has been verified. No firmware sends these messages, the console board's controller (Pico 2 / RP2350) has no firmware in the repo, and there is no UART `PedalTransport`.

Accepted contract: `docs/handoff/segno-app/accepted-behavior.md` section 4 items 6 to 8, `docs/design/2026-09-06-external-pedals-ux.md`, `docs/design/2026-09-07-external-function-assignments-ux.md`, `docs/design/expression-ux-study.js`, and `docs/design/external-switch-study.js`, which #1035 committed.

### Wire protocol (console board to segno)

The CTRL jacks are inputs on the console board, not MIDI devices. They arrive on the same 3-byte link as the ten footswitches and the encoder. They go through `pedal_repository`, **not** `controller_repository`.

| Input | Wire shape | C symbols (both protocol copies) | Dart symbols |
|---|---|---|---|
| External switch | Note on/off. Notes **10 to 13**: ctrl1First=10, ctrl1Second=11, ctrl2First=12, ctrl2Second=13. NoteOn with velocity 0 means open. | `PEDAL_EXT_CTRL1_FIRST` … `PEDAL_EXT_CTRL2_SECOND` = `PEDAL_BTN_COUNT + 0..3`, `PEDAL_EXT_COUNT = 4` | `PedalExternalSwitch`, `PedalExternalSwitchNote.firstNote = 10` / `.note` / `.fromNote`, `.position` (0 or 1). Event: `ExternalContactChanged(switchId, closed:, timestamp:)` |
| Expression pedal | Absolute CC. CTRL 1 = **0x11 (17)**, CTRL 2 = **0x12 (18)**. The value is the raw reading, 0..0x7F. | `PEDAL_EXPRESSION_CTRL1_CC`, `PEDAL_EXPRESSION_CTRL2_CC`, `PEDAL_EXPRESSION_MAX 0x7F`, `pedal_encode_expression(cc, raw, channel, buf)` (clamps) | `PedalExpressionJack`, `PedalExpressionJackCc.firstCc = 0x11` / `maxValue` / `fromCc`. Event: `ExpressionMoved(jack, raw:)`, where the codec has already divided `raw` into 0..1 |
| Encoder (existing) | Relative CC 0x10 | `PEDAL_ENCODER_CC` | `PedalCodec.encoderCc` |

- **Protocol copies:** `firmware/segno_pedal/pedal_protocol.{h,c}` and `hardware/firmware/segno_pedal_32u4/pedal_protocol.{h,c}`. Tests `test_external_switch_notes` and `test_expression_ccs` are in `firmware/test/test_pedal_protocol.c` and run via `firmware/test/run_tests.sh` against both copies.
- **Numbers pinned on both sides:** the Dart test `packages/pedal_repository/test/pedal_expression_jack_test.dart` pins the same literals. No test can compare the C and Dart copies directly.
- **Single pedal:** uses only the first switch of its jack's pair. The state frame addresses no external switch.
- **Why 7 bits:** segno's native capture drops SysEx, so nothing wider than a CC can arrive. A span near the 10% calibration minimum leaves about 13 distinct positions. If the bench shows stepping, the recorded fix is a 14-bit MSB/LSB pair on the wire; the app cannot fix it.
- **Link-up report (added in #1041's header comment):** the board must send each jack's current position once when the link comes up, then on change. A jack that has reported nothing reads as "not connected". A pedal pulled out later cannot be reported.
- **Path:** `MidiControllerSource.activity` → `_nativeTransport` (`native_pedal_repository.dart`) → `PedalRepository._onRaw` → `PedalCodec.decodeMessage` (`_decodeNote`, `_decodeExpression`) → the events stream → `ControlCubit._handleEvent`. `ExpressionMoved` also updates `PedalRepository.expressionPositions`, a `ValueListenable<PedalExpressionPositions>` that is reset to `none` on unbind. The codec ignores the MIDI channel.

### Persisted model

| Settings key | Content |
|---|---|
| `pedal.setup` (`SettingsRepository.loadPedalSetup` / `savePedalSetup`) | A `PedalSetup` JSON. Key `external` holds an `ExternalPedalSetup`. It is omitted when empty and survives Clear custom assignments. |
| `pedal.external_on` (`loadExternalSwitchStates` / `saveExternalSwitchStates`, added in #1043) | A JSON list of the `PedalExternalSwitch.name`s that are logically ON. Kept apart from the setup so that Cancel on the setup screen cannot undo a stomp. |

- **`ExternalPedalSetup`** (`lib/control/binding/external_pedal.dart`):
  - Holds `jacks: Map<ExternalJack, ExternalJackSetup>`, containing only non-empty jacks.
  - Methods: `forJack`, `withJack` (drops an empty jack), `isEmpty`.
  - `props` are ordered by `ExternalJack.values`, so map insertion order does not affect equality.
- **`ExternalJackSetup`:**
  - Fields: `type` (`ExternalJackType.expression | singleSwitch | dualSwitch`, default `singleSwitch`), plus `single`, `dualFirst`, `dualSecond` and `expression`. Every type's assignments are kept side by side.
  - Methods:
    - `switchAt(index)` and `withSwitch` operate on the **active** type only.
    - `isEmpty` counts the calibration and the switch hardware.
- **`ExternalSwitchSetup`:**
  - Fields: `hardware` (`ExternalSwitchHardware.momentary | latching`), `gestures` (`ControlGesturePair`, JSON keys `press` / `hold`), `change` (the single action of a latching switch), and `controls` (`ExternalControls`, added in #1043).
  - Methods: `closureAction`, `isEmpty` (a switch set to latching is not empty), `copyWith(clearChange:)`.
- **`ExternalExpressionSetup`** (`lib/control/binding/external_expression.dart`):
  - Fields: `calibration`, and `mappings` (at most one per target; `fromJson` drops a repeat).
  - Methods: `mappingFor`, `withMapping` (replaces in place), `withoutMapping`, `copyWith(clearCalibration:)`.
- **`ExpressionCalibration`:**
  - Fields: `heel`, `toe`. Raw 0..1 readings; `toe < heel` is allowed.
  - `minimumSpan = 0.1`, `span`, `isUsable`.
  - `positionOf(raw)` returns `(raw - heel) / (toe - heel)` clamped to 0..1, or null when the span is too short.
  - `fromJson` rejects an end outside 0..1 rather than clamping it.
- **`ExpressionMapping`:**
  - Fields: `target: ControlValueTarget`, `heel` (default 0), `toe` (default 1). `toe < heel` inverts the control.
  - `valueAt(position)`.
  - A target that does not decode drops the row.
- **`ExternalControls`** (`lib/control/binding/external_controls.dart`):
  - Fields: `activations: List<ExternalActivation>` and `parameters: List<ExternalParameter>`, one entry per target.
  - `ExternalActivation`: `target: FxBindingTarget` (`FxChainTarget` / `FxSlotTarget`) and `condition: ExternalCondition` (`on` / `off` / `held` / `released`; `readsContact` is true for held and released).
  - `ExternalParameter`: `target: ControlValueTarget`, `active`, `inactive` and `condition: ExternalValueCondition` (`onOff` / `heldReleased`). `fromJson` drops a row with no numeric values.
- **`ControlValueTarget`** (`lib/control/binding/control_value_target.dart`):
  - A sealed type with subtypes `FxParamTarget(address, slotId, param)`, `TrackVolumeTarget(channel)` and `MasterGainTarget`.
  - `canonicalString()` is the identity and the persisted form; `tryParse` never throws.
  - Git history puts its origin at PR #415. The 4f PR bodies call it "part 4b's continuous model".
  - It is resolved by the `ControlValueResolver` extension on `LooperRepository` (`control_value_resolver.dart`): `availableValueTargets`, `valueTargetResolves`, `readValueTarget` (added in #1044) and `writeValueTarget`, which returns false and writes nothing when the target is gone and never repoints it.
  - Effect on/off goes through `FxBindingResolver.setBindingEnabled`.

---

### PR #1035: CTRL jack model, switch types and actions
`claude/external-pedals-1026` -> `claude/pedal-face-art-1033` · open · labels `area:console`, `area:pedal`, `review:clean`, `ci:red`. Commits: e08c1ccc, then review fix b1a37fbe.

**What it built**
- The model classes above (the switch half), plus `PedalSetup.external`.
- **Entry point:** an External pedals button on the Pedals setup row (`Key('pedal_setup_external')`, `pedal_setup_page.dart`). It calls `openExternalPedals()` in `lib/app/segno_navigator.dart`, route `segnoExternalPedalsRouteName = 'segno/external-pedals'`, guarded against stacking duplicates.
- **`ExternalPedalPage`** (`lib/control/view/pedal_setup/external_pedal_page.dart`):
  - CTRL 1 / CTRL 2 buttons and type buttons.
  - Button 1 / Button 2 hit targets on the art.
  - Press and Hold fields for momentary hardware, or one Change field for latching, with a note saying why.
- **Draft handling:** the page keeps its own `_draft`. Save calls `ControlCubit.setPedalSetup(state.pedalSetup.copyWith(external: …))`, Cancel drops the draft, and leaving the page discards it. A Save elsewhere cannot commit it.
- **Art:**
  - Widgets: `ExternalPedalArt` and `ExternalPedalArtwork` (`external_pedal_art.dart`). The pen box is 580 x 722 and the hit target is 108.
  - Measurements: switch and indicator centres are measured in the source raster and placed as fractions of it.
  - Assets: `assets/hardware/external_single.webp` and `external_dual.webp`, 284 KB in WebP against 2.6 MB of PNGs, listed in `pubspec.yaml`.
- **Shared action picker:** moved into `showControlActionPicker` (`pedal_choice_picker.dart`: `PedalChoice`, `PedalChoiceGroup`, `PedalChoiceResult`) so the built-in map and the jacks use the same picker.
- **`PedalSetupField`:** gained `width`, `height`, `buttonHeight` and `valueFontSize` parameters. The external editor uses width 506.
- **Track pedal actions:** "Track N pedal" (`TrackPedalAction`) and "Select track N" (`SelectTrackAction`) for all eight channels come from #1028's catalogue, so an external switch can carry Track 5/6 regardless of bank.

**Decisions**
- A jack keeps every type's assignments, as the accepted design requires.
- Hardware type is a setting. A latching switch carries one action, and the screen explains why rather than offering a Hold that can never fire.
- Expression is in the model but was not offered in the type picker until #1041, so no type opens an empty panel.
- The artwork is the design study's generated, unbranded art.

**Verification**
- New tests: `test/control/binding/external_pedal_test.dart` (13 model tests) and `test/control/external_pedal_page_test.dart` (9 screen tests).
- Root suite: 2234 passing, 35 skipped.
- Goldens: `external_pedals_single.png`, `_dual.png` and `_latching.png` are new; the `pedal_setup_*` goldens were regenerated for the new button.
- **Bug caught by the screen test:** a switch set to latching with no action was dropped on write. Hardware now counts toward "not empty".
- **Review fix b1a37fbe:**
  - The dual pedal had lost its second contact indicator.
  - Added `test/control/external_pedal_art_test.dart`, which parses the `artwork` object in `docs/design/external-switch-study.js` and compares raster size, switch centres and indicator centres with the app's values. The study file is committed with it.
  - Dropped the unused `ExternalJack.fromName`.

**Open items**
- The contact dots are fed `contacts: const {}` in `_body` of `external_pedal_page.dart`, with a comment saying no transport exists. That was still true at the stack tip, even after #1036 added dispatch. No source records this as an open item.
- No dispatch test runs Track 5/6 from an external switch while the plate is on Bank A. `TrackPedalAction(4)` appears only in model round-trip tests.

### PR #1036: external switch dispatch through `_runAction`
`claude/external-dispatch-1026` -> `claude/external-pedals-1026` · open · labels `area:console`, `area:pedal`, `review:clean`, `ci:red`. Commits: 97975749, then review fix cafd2a3b.

**What it built**
- The external switch Note numbers in both C headers and in `pedal_external_switch.dart`, and `ExternalContactChanged`: one event for both edges.
- **`ControlCubit._onExternalContact(switchId, closed:)`:**
  - `_externalContacts` records what the wire reports, independent of the assignment. A repeated state is ignored.
  - `_externalSetupOf(switchId)` resolves the switch under the jack's **active** type using an exhaustive `switch`, not index arithmetic.
  - Latching: runs `setup.change` on every change.
  - Momentary with no hold: runs the press on contact.
  - Momentary with a hold: `_armExternalPress` waits for the release. Reaching the threshold (`_longPress`, from `loadPedalLongPressMs`) runs Hold and consumes the release.
  - All actions go through `_runAction`, the one interpreter.
- **Shared gesture registry:** `_Gestures` is now keyed by `Enum` (`_byControl`) instead of `PedalButton`, so plate and jacks share one gesture state machine and one cancellation generation.
- **Save:** `setPedalSetup` calls `_invalidateGestures()`, which retires a pending hold.
- **Take lock:** `_takeLocked()` refuses a jack in the same way it refuses the plate.

**Decisions**
- Only the active type dispatches.
- Link drop (`_onBindStatus`) clears `_externalContacts`. Otherwise a switch still held across an unplug is swallowed on reconnect. This was found in review.
- The wire enum lost its `jack` getter so the two packages cannot drift by index.

**Verification**
- Root suite: 2246 passing, with 9 new dispatch tests in `test/control/control_cubit_test.dart`, group `external pedals (part 4f)`.
- `pedal_repository`: 206 passing, including `packages/pedal_repository/test/pedal_external_switch_test.dart`. Every external note is rejected by the footswitch decoder and the reverse.
- Firmware contract suite green under sanitizers.
- Three mutations, all caught: the duplicate-state guard, the active-type guard, and a note overlap in the C header.
- The review round added tests for the take lock on a jack and for clearing the contact set on unplug.

**Open items:** none beyond the part-wide ones below. Hardware is untested.

### PR #1039: expression wire numbers, calibration, value dispatch
`claude/external-expression-1026` -> `claude/external-dispatch-1026` · open · labels `review:clean`, `ci:red`. Commits: 9951ef64, then review fix 4b8be459.

**What it built**
- **Wire and codec:** the expression CCs and `pedal_encode_expression` in both C copies; `PedalExpressionJack`, `ExpressionMoved`, and `PedalCodec._decodeExpression`, which normalizes to 0..1.
- **Models:** `ExpressionCalibration`, `ExpressionMapping` and `ExternalExpressionSetup`, plus `ExternalJackSetup.expression`.
- **`ControlCubit._onExpressionMoved(jack, raw)`:**
  - Maps the wire jack to the app's `ExternalJack` by name.
  - Returns early unless the jack's type is `expression`.
  - Returns when `calibration?.positionOf(raw)` is null.
  - Otherwise writes every mapping at `mapping.valueAt(position)`.
- **`_applyValueTarget(target, value)`:** the shared continuous write. It is used by both `_applyControllerValue` (learned MIDI CC) and expression. It calls `writeValueTarget` and keeps the `_masterGain` accumulator in step, so the next encoder turn does not jump the gain back.

**Decisions**
- 7 bits, one message (reasons in the wire section).
- Raw readings go on the wire so the app can calibrate. Reversed wiring needs no special case.
- A span under 10% positions nothing. The threshold is a design-study assumption, not a measured electrical requirement.
- A calibrated but unassigned jack is not empty.
- A target that has disappeared is skipped, never repointed.
- Expression is deliberately **not** gated on `_takeLocked`. That lock stops a take from starting behind the power-off route, and a sweep starts nothing.
- The calibration-suppression rule was deferred to #1041, because nothing could set it yet.
- A codec test that used "encoder CC + 1" as an unrelated CC was fixed, since 0x11 is now expression.

**Verification**
- New tests: `test/control/binding/external_expression_test.dart`, `packages/pedal_repository/test/pedal_expression_jack_test.dart`, and the `an expression pedal` group in `control_cubit_test.dart`.
- Root suite: 2280 passing. `pedal_repository`: 214 passing. Firmware suite green, including the CC-collision and clamp checks.
- **Mutations, all caught:** the active-type check, the unusable-travel check, reversed travel (both a sorted-ends and an unsigned-distance implementation), named jack resolution, the master-gain accumulator, the take-lock asymmetry, duplicate-target drop, the expression half of `isEmpty`, and the codec clamp.
- **Review fix 4b8be459:**
  - Out-of-domain calibration ends are rejected.
  - `_writeValueTarget` was renamed to `_applyValueTarget`.
  - The Dart literals were pinned.

**Open items**
- Filed #1040: one MIDI input is captured at a time, and the pedal path reads Notes 10 to 13 and CC 17/18 from whichever device is open. The product question is whether a third-party controller is used alongside the board or instead of it.
- Smoothing and resolution are unspecified in the design. Bench stepping would call for a 14-bit pair.

### PR #1041: expression screen
`claude/expression-screen-1026` -> `claude/external-expression-1026` · open · labels `review:clean`, `ci:red`. Commits: 69ea159c, then review fix 1f6b563d.

**What it built**
- **Type picker:** now offers Expression. Art: `assets/hardware/external_expression.webp`.
- **One page, four bodies:** `ExternalPedalPage` has four states (`_ExternalView.main | calibrate | destinations | controls`) and one draft.
  - Back steps through them.
  - Save and Cancel show only on `main`.
- **Panels:**
  - `ExpressionPositionPanel`: the meter shows the raw reading. The number shows the position within the taught travel, or nothing if untaught. The panel reads "not connected" when `expressionPositions` is null for the jack.
  - `ExpressionCalibrationPanel`: capture heel and toe, then Use calibration, which refuses a span under `minimumSpan`.
  - `ExpressionControlsPanel`: mapping rows plus Heel and Toe `LoopSlider`s.
  - `ExpressionDestinationPicker` and `ExpressionControlPicker` (`expression_target_picker.dart`).
- **Catalogue** (`lib/control/binding/expression_catalogue.dart`):
  - Types: `ExpressionDestination`, `ExpressionControlGroup`, `ExpressionControl`.
  - Functions: `expressionDestinations(l10n, trackNames, looper)`, `expressionTargetName`, `expressionRowName`, `expressionKindLabel`.
- **Calibration flow:**
  - `ControlCubit.setCalibrating(ExternalJack?)` sets `_calibratingJack`, which suppresses dispatch.
  - `_openCalibrate` sets it **before** the view opens.
  - It is cleared by `_leaveCalibrate`, `_useCalibration` and `dispose`. It is deliberately not cleared on a link drop, because the view is still open when the cable returns.
  - Captures are staged in page state (`_captureHeel`, `_captureToe`). Use calibration puts them into the draft and Save commits them.
  - Captures are discarded when the jack position goes null, which happens on unbind.
- **Header obligation:** the link-up report requirement was added to both protocol headers.
- **Provenance:** `docs/design/external-pedal-art/generation.json` is now tracked; the PNG sources stay untracked.

**Decisions**
- A track's fader and its whole-track FX chain are one destination.
- Destination kinds reuse `FxDestinationKind` and the Effects page's strings.
- A control that is already swept is shown and refused, not hidden.
- Repointing a mapping keeps its endpoints.
- A control the rig has lost keeps its row and says it is unavailable.
- **Not built in this PR:**
  - The pen's 52 x 68 row illustration. At the time, the Looper X art was considered rejected for shipping; #1045 reverses this.
  - Double-tap endpoint reset and encoder editing. No slider on this console implements either, and the app's reset idiom is an explicit button.

**Verification**
- New tests: `test/control/external_expression_page_test.dart`, `test/control/binding/expression_catalogue_test.dart`, and additions to `packages/pedal_repository/test/pedal_repository_test.dart`.
- Root suite: 2309 passing. `pedal_repository`: 219 passing.
- Five new goldens, all checked by eye: `external_pedals_expression_empty`, `_expression`, `_expression_calibrate`, `_expression_destinations`, `_expression_controls`. The three switch goldens were regenerated.
- Mutations, all caught: calibration suppression and its lifting, captures cleared on link drop, Calibrate needing a reading, Use calibration refusing a short travel, and repointing keeping endpoints.
- Rendering bugs found in the goldens:
  - The meter fill was invisible because `FractionallySizedBox` was given only a width.
  - Add control showed a bare plus because `LoopOutlinedButton.icon` replaces the label; `leadingIcon` is the one that sits in front of it.
- **Review fix 1f6b563d:** repointing a mapping to the control it already has no longer moves its row to the bottom. Rows are keyed by `canonicalString()` rather than its hash.

**Open items:** double-tap reset and encoder editing. No issue was filed; #1026 says it is worth one when the encoder-focus model is taken up.

### PR #1043: external button drives effects and parameters (dispatch)
`claude/external-controls-1026` -> `claude/expression-screen-1026` · open · labels `review:clean`, `ci:red`. Commits: f2bd9229, then review fix 1562b8e9.

**What it built**
- The `ExternalControls` model on `ExternalSwitchSetup.controls`, and the `pedal.external_on` settings key.
- **`ControlCubit` state:**
  - `_externalOn`: the logical ON state, restored at load and saved on change by `_setExternalOn`.
  - `_externalSuppressed`: momentary contacts that must lift before they count again.
- **`_applyExternalControls(setup, onBefore/onAfter/heldBefore/heldAfter)`:**
  - Edge-triggered: it writes only controls whose condition changed.
  - Activations go through `_looper.setBindingEnabled`; parameters go through `_applyValueTarget`.
  - LEDs are re-projected only if a `setBindingEnabled` write succeeded.
- **Rules:**
  - With no Hold, the press flips ON on contact.
  - With a Hold, only a completed short press flips ON, and running the Hold does not.
  - The tap is armed even when there is no press action.
  - Held and Released follow the contact without waiting for the threshold, and are skipped on latching switches.
  - On a latching switch, ON equals the contact.
- **`_endExternalHolds()`:** applies Released. It runs from `_onBindStatus` (disconnect) and from `setPedalSetup`, where it runs before the new setup is emitted, so the old setup's Released applies. On Save, held momentary contacts are added to `_externalSuppressed`.

**Decisions**
- **Storage departs from the design:** the design keeps an effect's activation rule on the rack. This app has no rack activation rule, so the binding lives on the button, as footswitch and MIDI bindings already do. Removing it stops future writes and leaves the bypass flag unchanged. If a rack-owned rule is ever built, this binding moves onto it.
- The ON state is stored apart from the setup.
- Saving, opening the screen or connecting writes nothing.

**Verification**
- New tests: `test/control/binding/external_controls_test.dart` (13 model tests), 14 dispatch tests in the `a button's controls` group, and additions to `packages/settings_repository/test/settings_repository_test.dart`.
- Root suite: 2337 passing. `settings_repository`: 157 passing.
- Mutations, all caught: suppressed contact after Save, hold ending on Save, hold ending on unplug, Hold also flipping ON, tap left unarmed without a press action, Released read from a latching switch, ON not restored.
- **One mutation survived:** an extra "is the effect still in the rig" lookup changed nothing, because `setBindingEnabled` already refuses a missing target. The lookup was removed.
- **Review fix 1562b8e9:** a take lock now ends a hold that began before it (applies Released) and suppresses a closure it refused. Before the fix, the release after the lock wrote Released for a hold that never began.

**Open items:** none recorded beyond the part-wide ones.

### PR #1044: button Controls panel
`claude/external-controls-panel-1026` -> `claude/external-controls-1026` · open · labels `review:clean`, `ci:red`. Commits: 4ea276de, then review fix fdc92b4f.

**What it built**
- **Actions / Controls tab:** added to the button editor (`_showControls` on `ExternalPedalPage`).
- **`ExternalControlsEditor`** (`external_controls_editor.dart`):
  - Effect rule: On / Off / Held / Released, with an explanation line. Parameter rule: On/Off or Held/Released, and two value sliders labelled Off/On or Released/Held.
  - On a latching switch, Held and Released are shown and refused, with the reason.
  - A lost control shows "Unavailable".
- **Adding a control happens inside the editor**, with the art still visible (`_buttonPick: destinations | controls`):
  - The destination step reuses `ExpressionDestinationPicker` at one column.
  - The control step is `ExternalControlTargetList`: effects first, named "· Activation", then parameters, each naming its effect.
  - `expressionDestinations` now also returns `ExpressionActivation`s.
  - A new parameter starts with both values at the current rig value, read with `readValueTarget` and `LooperRepository.masterGain`, which is new.
  - Moving a value edits the draft only.
- **Shared widgets:**
  - `ControlRowTile` and `ControlRowList` (`control_row_list.dart`) are used by expression sweeps, button controls and both pickers. The list keeps the open row in view.
  - `ScrollMoreHint` (`scroll_more_hint.dart`) draws the design's overflow arrow. It is non-focusable, excluded from semantics, and does not take touches.

**Decisions**
- Adding a control happens in the editor, not over the page, as the pen draws it.
- The 68 x 68 row illustration was left out and recorded on #1026 as an open decision. #1045 resolves it.

**Verification**
- New tests: `test/control/external_controls_page_test.dart` (11 widget tests), plus `test/control/binding/control_value_resolver_test.dart` (3 resolver tests).
- Root suite: 2355 passing. `looper_repository`: 548 passing.
- Goldens: `external_pedals_controls`, `_controls_parameter` and `_controls_pick` are new; the switch goldens were regenerated.
- Mutations, all caught: Held refused on latching, starting value read from the rig, open row kept in view, Back stepping out of the picker.
- `looper_repository` reports ten infos in `fx_chain_group_test.dart`. They predate this PR.
- **Review fix fdc92b4f:**
  - `ControlRowList` now reveals the open row only when the selection or the item count changes. The expression list rebuilds on every pedal report, and was scrolling the user back.
  - Changing jack or type now closes an open picker.

**Open items:** none beyond the part-wide ones.

### PR #1045: row pictures from the Looper X catalogue art
`claude/external-row-art-1026` -> `claude/external-controls-panel-1026` · open · labels `review:clean`, `ci:red`. Commit: 1e8ba6f0.

**What it built**
- **`expressionTargetArt(looper, target)`** in `expression_catalogue.dart`:
  - An `FxParamTarget` or `FxSlotTarget` draws its module's stomp image, `fxModuleArt(module)`.
  - An `FxChainTarget` draws `fxFootswitchAsset(rack.art)`, but only if every entry in the chain belongs to one rack (`_rackArt`).
  - Faders, master gain and targets gone from the rig draw nothing.
  - The `art` field was added to `ExpressionControl` and `ExpressionActivation`.
- **Sizes, passed through the shared `ControlRowTile`:**

  | List | Size |
  |---|---|
  | Expression sweeps | 52 x 68 |
  | Button controls and the button control picker | 68 x 68 |
  | Expression control grid | 42 x 54 |

  An image that fails to load keeps its space.
- **Asset path helper:** `fxFootswitchAsset` moved into `packages/fx_catalogue/lib/src/fx_family.dart`. `fx_chain_strip.dart` and `fx_page.dart` now call it.

**Decisions**
- **Owner call, 2026-09-13:** use the Looper X factory images for row pictures "for now", and never generate artwork. This overrides the earlier "rejected for shipping" note for row pictures; do not raise it again as a blocker. Rows the pen draws without a picture stay without one.

**Verification**
- Five catalogue resolution tests in `expression_catalogue_test.dart`.
- One widget test: a row draws its pedal and a fader row draws none.
- Five goldens regenerated and checked by eye.
- Root suite: 2363 passing. `fx_catalogue`: 20 passing.
- Mutations caught: dropping the one-rack rule, and a row not passing its picture to the tile.

**Open items:** the three pedal illustrations from #1035 and #1041 are generated art (provenance in `generation.json`). The owner's "no generated artwork" call was made about row pictures, and no source records a ruling on these three.

---

### Open items for 4f as a whole

- **#1040:** single MIDI input capture. Needs a product call. Part 4g's mapping engine carries device identity so either answer works.
- **Double-tap endpoint reset and encoder editing of values:** in the accepted design, absent from every slider on the console. No issue filed.
- **Contact indicators on the jack art:** they are never fed. `_externalContacts` is private to the cubit and the page passes `const {}`. Not recorded in any PR.
- **Reconnect writes to targets:** the design says "Saving or connecting does not jump to the current pedal position". Saving writes nothing. Reconnecting does write: `_onExpressionMoved` dispatches every `ExpressionMoved`, including the link-up report the header now requires. No guard or test for this was found in the code at the stack tip, and no source records it.
- **Controller arbitration:** an expression pedal and a learned CC on one parameter have no arbitration beyond "last write wins". The design says this still needs specification.
- **Simulator:** `SimulatorPedalTransport` and the faceplate have no way to inject jack contacts or expression positions, so the jacks can only be exercised in tests.
- **Instruments:** accepted item 8 says instrument note, chord and sustain actions use the same system. Instruments do not exist yet.
- **Console board firmware:** the real board controller (Pico 2) has no firmware. When written, it must send notes 10 to 13, CC 0x11/0x12, and the link-up report. The firmware suite checks only the two existing copies.

### Gotchas specific to this area

- **Wrong package:** the jacks go through `pedal_repository` and `ControlCubit._handleEvent`, not `controller_repository`. The slice-4 issue body's "controller repository + app" is inaccurate for 4f.
- **MIDI Learn:** #1047 found that Learn could capture the jacks' Notes and CCs. `isPedalProtocolInput` (`pedal_protocol_traffic.dart`) now claims `PedalExternalSwitchNote.fromNote` and `PedalExpressionJackCc.fromCc`. Any new wire number must be added there too.
- **Map wire enums by name:** map `PedalExternalSwitch` / `PedalExpressionJack` to `ExternalJack` with an exhaustive `switch`, never by `index`. They are declared in different packages.
- **Clear `_externalContacts` and `_externalSuppressed` on link drop,** but keep `_externalOn`.
- **Continuous writes go through `_applyValueTarget`.** Calling `writeValueTarget` directly desynchronizes `_masterGain` from the encoder. As of the local branch `claude/midi-old-model-removal-1026`, the MIDI engine wiring also uses `_applyValueTarget`.
- **Take lock:** switch paths honour `_takeLocked()`, expression does not, and a refused momentary closure must go into `_externalSuppressed`.
- **Save:** end external holds before `emit`, so the old setup's Released applies.
- **Live positions come from `PedalRepository.expressionPositions`,** not `ControlState`. Any list that rebuilds on pedal reports must not re-scroll on every rebuild (the `ControlRowList` rule above).
- **Switch art coordinates are measured, not hand-copied.** Change `docs/design/external-switch-study.js` and `ExternalPedalArt.artwork` together, or `external_pedal_art_test.dart` fails.
- **`LoopOutlinedButton`:** `icon` replaces the label; use `leadingIcon`. Give a meter fill `heightFactor: 1` when using `FractionallySizedBox`.
- **Branch hygiene:** twice in this part (#1039, #1043), the next commit landed on the previous PR's branch because the worktree was still checked out on it. Each needed a reset and force-push. Run `git branch --show-current` and create the new branch before committing.
- **Goldens:** `test/screenshots/external_pedal_screenshots_test.dart` goldens run only on the author's machine. Regenerate and check them by eye after any UI change.


## 6. Part 4g: MIDI Learn formats, the mapping engine and the MIDI controls page

Part 4g of #1026 replaces the old MIDI control model. It does not add to it. Under the accepted design, one mapping has one source (device, channel, explicit format) and any number of controls, and a mapping can be disabled without losing it. Mappings are edited on a new MIDI controls page, and a controller does nothing until it is mapped. The work is five stacked pieces. The full research, pen exports and drafted PR bodies are in `part-4g-midi/` in the main checkout (untracked, so a git worktree cannot see it). Read `HANDOFF.md` there first.

| Piece | PR | Branch -> base | Commits | Labels / state |
| --- | --- | --- | --- | --- |
| Formats + Program Change | #1047 | `claude/midi-formats-1026` -> `claude/external-row-art-1026` (#1045) | `37789aa7` | open; `stage:in-review`, `autonomy:merge-gate`, `ci:red`, `review:clean` |
| Mapping engine | #1048 | `claude/midi-mapping-engine-1026` -> `claude/midi-formats-1026` | `280f116f` | open; same four labels |
| Cubit wiring | #1049 | `claude/midi-engine-wiring-1026` -> `claude/midi-mapping-engine-1026` | `bb3ba109`, `63d8d7b5` | open; same four labels |
| PR A: the page | none | `claude/midi-controls-page-1026` -> `claude/midi-engine-wiring-1026` | `5a9679af`, `2b9e39c9`, `efa5a24f` | local, unpushed; worktree `/private/tmp/claude-501/-Users-Tomas-Documents-Work-opensource-loopy/1a736a10-cdfb-4daa-ad93-3176a9204d1d/scratchpad/wt-4fe` |
| PR B: old model removed | none | `claude/midi-old-model-removal-1026` -> `claude/midi-controls-page-1026` | `3876f578` (rebased onto `efa5a24f`) | local, unpushed; worktree `scratchpad/wt-4ff` |

The whole stack is `ci:red` until the #1011 CI gate is fixed. The two local branches were never pushed because the `gh` token expired. Only the first three branches exist on `origin`.

### 4g.1 Formats and Program Change: PR #1047, `claude/midi-formats-1026` -> `claude/external-row-art-1026`, review:clean, ci:red

**What it built**
- **Native Program Change.**
  - The parser in `packages/segno_engine/src/midi/midi.c` reports `LE_MIDI_PROGRAM = 4` (`le_midi_internal.h`) for `0xC0`. It has one data byte and its value is always 0, so the ring, drain and callback keep one message shape. A stray second byte is never read as a value.
  - `midi_backend_linux.c` forwards `SND_SEQ_EVENT_PGMCHANGE`; the program number is in `value`, not `param`. CoreMIDI already framed one-data-byte messages.
  - Dart carries it as `ControllerSourceKind.midiProgram`. The old 7-bit bindings neither learn nor dispatch it.
- **Formats module:** `packages/controller_repository/lib/src/midi_protocol.dart`.
  - `MidiProtocol`: `standard`, `cc14`, `nrpn`, `bankProgram`, `relative`.
  - `MidiSource`: `device`, `kind`, `number`, `channel` (null means all channels), `protocol`, `parameter`, `bank`. Methods `isValid`, `sameAs`, `overlaps`, `footprint`, `toJson` / `fromJson`; constant `maxWord = 16383`.
  - `MidiControlEvent`.
  - `MidiDecoder.feed(device, message, protocol)` and `reset(device)`. The decoder is told the format and returns only complete readings; nothing is inferred from one byte.
- **Decoder receiver rules:**
  - A 100 ms freshness window (`_fresh`), with a fresh pair needed for each update.
  - RPN selection and the NRPN null selection cancel NRPN.
  - Data Increment and Decrement discard pending data.
  - A partial bank invalidates the bank before it.
  - Partial state is kept per device, channel and protocol, and reset per device.
- **Overlap:** refused across formats when two sources share any raw footprint, on channels that meet, on the same device. For example, a CC 53 knob and a 14-bit CC 21/53 knob cannot both be mapped. Distinct NRPN parameters and banked Programs stay independent.
- **Learn hygiene:** `isPedalProtocolInput` (`packages/pedal_repository/lib/src/pedal_protocol_traffic.dart`) now also claims the CTRL jacks' external switch Notes 10-13 (#1036) and the expression CCs 0x11/0x12 (#1039). Before this, a MIDI binding learned from a jack would run beside the pedal setup's own assignment.

**Decisions**
- The receiver rules are the design's "prototype contracts". The design says they need validation on physical controllers.
- Program Change is carried for the new formats only, not for the old bindings.

**Verification**
- Every worked Learn example in the design document is a test, copied exactly: 14-bit `CC21=64, CC53=1` -> 8193/16383; NRPN `99=2, 98=3, 6=64, 38=7` -> parameter 259, 8199/16383; Bank `0=2, 32=4, Program 8` -> bank 260, program 8; relative `CC22=127` -> one step down.
- Test files: `packages/controller_repository/test/midi_protocol_test.dart`, `packages/pedal_repository/test/pedal_protocol_traffic_test.dart` (its "CC 17 is a third-party controller" test was corrected), `packages/midi_client/test/midi_controller_source_test.dart`, `packages/segno_engine/src/test/test_midi_core.c`.
- Suites: `controller_repository` 101, `midi_client` 55, `pedal_repository` 220, root 2363 passing and 35 skipped. Native suites pass.
- Mutations, all caught: the freshness window, the fresh pair per update, RPN cancelling NRPN, the partial bank, cross-format overlap, device identity and the jack notes. The device-identity mutation survived at first. The test now compares sources across formats, where only the device check separates them.

**Open items**
- The Linux ALSA `PGMCHANGE` case is not compiled by the Mac native suite; only CI's Linux job builds it. With the stack red, that result is not recorded.
- The receiver rules have not been validated on a physical controller.

### 4g.2 Mapping engine: PR #1048, `claude/midi-mapping-engine-1026` -> `claude/midi-formats-1026`, review:clean, ci:red

**What it built** (pure Dart, nothing read it at this point)
- **Model:** `packages/controller_repository/lib/src/midi_mapping.dart`.
  - `MidiBehavior`: `continuous`, `momentary`, `toggle`, `trigger`. `MidiEdge`: `press`, `release`.
  - Sealed `MidiControl`, with two kinds:
    - `MidiParameterControl{key, low, high}`: values 0..1; either may be the larger, which is how a control inverts a parameter.
    - `MidiActionControl{key, trigger}`.
  - `MidiMappingProblem`: `noSource`, `noControls`, `actionNeedsButton`, `behaviorDoesNotFit`, `programHasNoRelease`.
  - `MidiMapping{id, source, behavior, controls, enabled}`, with `defaultBehavior`, `problem` and `copyWith`.
  - `MidiMappingSet`, with `conflictWith(source, {exceptId})`, `withMapping` (throws on a problem or an overlap), `withoutMapping`, `byId`, `fromJson` and `toJson`.
- **Engine:** `midi_mapping_engine.dart`.
  - Constructor: `MidiMappingEngine(clock, read, step)`.
  - Methods: `setMappings`, `setControlEnabled`, `pause`, `resume`, `connectionChanged`, `learn`, `resetDecoder`, `receive`.
  - It returns sealed `MidiOutput` values (`MidiParameterWrite(key, value)`, `MidiActionRun(mappingId, key)`, `MidiActionEnd(mappingId, key)`) rather than writing. Control keys are opaque strings, so the package does not depend on the looper.
- **Runtime rules:**
  - A knob writes nothing until it takes over: its value lands within one step of the parameter's value, or crosses it.
  - A relative control moves from the current value by the step, in the direction its range runs, clamped to the range.
  - A button is down while any channel it listens on is down. A toggle flips on press. A press action is ended on release. A Program is always a press and never released.
  - Control off, disabling, deleting, pausing the device, or a disconnect ends every hold: momentary parameters return to Released and held actions end. None of these runs an action.
  - A reconnect clears contacts, takeover state and toggle latches.
  - `learn` ignores a Note release and a relative reading with a delta of zero.

**Decisions**
- Overlap is refused even against a disabled mapping, so the disabled mapping can be turned back on.
- A learned source starts with the behavior that fits it (`defaultBehavior`).
- Departure from the prototype's implementation, not from its design: a toggle writes its parameters only when the latch moves, not again on release. Writing again on release would reset a value the performer changed on screen since the press. This is recorded only in the PR body and commit message.

**Verification**
- `packages/controller_repository/test/midi_mapping_engine_test.dart`; the package has 135 passing tests, 34 of them for the engine and model.
- Every mutation was caught except one: the engine's early filter by device. It is redundant, because the source comparison after it already refuses other devices, and #1047 tests that comparison.

**Open items:** none recorded for this PR itself. The gaps below were found in #1049's wiring.

### 4g.3 Cubit wiring: PR #1049, `claude/midi-engine-wiring-1026` -> `claude/midi-mapping-engine-1026`, review:clean, ci:red

**What it built**
- **Undebounced stream:** `MidiDeviceRepository.messages` (`packages/midi_device_repository/lib/src/midi_device_repository.dart`).
- **Engine in `ControlCubit`** (`lib/control/cubit/control_cubit.dart`):
  - Field `_midi`. Its `read` goes through `ControlValueTarget.tryParse` and `_looper.readValueTarget`; its `step` is `(_) => 0.01`.
  - `_midiDevice` is the open device id while it is connected. That id is the identity a mapping's source must name to dispatch.
  - `_onMidiMessage` either feeds Learn or calls `_midi.receive`.
  - `_applyMidi` sends parameter writes through the shared value-target path (so the master-gain encoder accumulator stays in step) and actions through `_runAction`, with the take lock and the power-off refusal.
- **Settings** (`packages/settings_repository`):
  - `loadMidiMappings` / `saveMidiMappings` store a JSON blob under `midi.mappings`.
  - `loadMidiControlEnabled` / `saveMidiControlEnabled` store `midi.control_enabled`, default `true`.
  - The doc comment states that mappings are global to the rig, not to a session.
- **State and methods as shipped in #1049** (PR A replaces some of these):
  - State: `ControlState.midiMappings`, `midiControlEnabled`, `midiLearn` (`lib/control/binding/midi_learn.dart`).
  - Methods: `saveMidiMapping`, `deleteMidiMapping`, `setMidiMappingEnabled`, `setMidiControlEnabled`, `startMidiLearn(protocol, {editingId})`, `endMidiEdit`.
- **Commit `63d8d7b5`:** `MidiMappingSet.fromJson` drops stored entries that are invalid, have a duplicate id, overlap another entry, or have a `problem`. Without this, one bad stored entry made every later `withMapping` throw, so no mapping could be edited.

**Decisions**
- The new set starts empty. The old bindings kept working until PR B, so both paths ran side by side.
- The stream is undebounced, a constraint from #1047's review. The 30 ms footswitch debounce drops half of a 14-bit or NRPN pair.
- Only one MIDI input is captured at a time (#1040). A mapping from a device that is not the open one does not dispatch, and device identity keeps that correct whichever way #1040 is decided.

**Verification**
- Tests: 15 new cubit tests in `test/control/control_cubit_midi_test.dart`, plus `midi_device_repository_test.dart` and `settings_repository_test.dart`.
- Suites: root 2378 passing and 35 skipped; bloc lint clean over 267 files.
- Mutations, all caught: pedal traffic refused by Learn, the take lock, Learn ending with its device, a disconnect releasing a hold, Save refusing an overlap, Control off releasing holds, and Learn releasing holds when it starts. The last one survived at first; its test now checks that the hold returns to Released.

**Found after the PR (all fixed in PR A):**
- A device that disconnected while Learn was open stayed paused forever: `_onMidiConnection` cleared Learn without calling `resume`.
- Opening the editor without Learn did not pause the device.
- Save emitted state before the settings write finished and did not report whether it succeeded.

### 4g.4 PR A, the MIDI controls page: local `claude/midi-controls-page-1026` -> `claude/midi-engine-wiring-1026`, unpushed, no PR number

- **Planned title:** `feat(midi): the MIDI controls page`.
- **Planned labels:** `stage:in-review`, `autonomy:merge-gate`, `ci:red`, `review:pending`.
- **Body:** `part-4g-midi/pr-a-body.md`.
- **Size:** 48 files, +5607/-136.

**What it built**

**Commit `5a9679af`: the editor session in the cubit**
- **Session state:** `MidiEdit{device, learn, learnTimedOut}` (`lib/control/binding/midi_edit.dart`, exported from `lib/control/control.dart`) is stored in `ControlState.midiEdit`, which replaces `midiLearn`; clear it with `copyWith(clearMidiEdit: true)`. `MidiLearn{protocol, reading}` has `isListening`.
- **Session methods:**
  - `beginMidiEdit({device})` pauses the device, which ends its holds. It resumes a previous session's other device and ends any Learn.
  - `startMidiLearn(protocol)` is a no-op without a session, or when the session's device is not the connected one. It resets the decoder and starts the timeout; the constructor parameter `midiLearnTimeout` defaults to 15 s.
  - `_onMidiLearnTimeout` sets `learnTimedOut`.
  - `cancelMidiLearn()` keeps the device paused.
  - `endMidiEdit()` always resumes the device.
- **Paused-after-disconnect fix:** the editor stays open across a disconnect, and a listening Learn hears the device when it returns.
- **Write-first, one at a time:**
  - `_serialMidiWrite` chains each write on `_midiWrites`.
  - `_persistMidiMappings` writes settings first and only then calls `_midi.setMappings` and emits. A failed write is logged and changes nothing.
  - `setMidiControlEnabled` follows the same order.
- **Additions to `controller_repository`:** `MidiSource.withChannel`, `MidiMappingSet.nextId`, and `MidiSignalLevels` (`packages/controller_repository/lib/src/midi_signal_levels.dart`). `MidiSignalLevels` has its own decoder and the methods `feed(device, message, sources)`, `lastOf(source)` and `reset(device)`.

**Commit `2b9e39c9`: the page**
- **Route** (`lib/app/segno_navigator.dart`): `segnoMidiControlsRouteName = 'segno/midi-controls'`, a `_midiControlsOpen` guard, `openMidiControls()`, and the reset in `resetSegnoNavigatorForTest`.
- **Entry point:** a `ConsoleRow` with key `control_open_midi` (strings `controlMidiControlsRow` / `controlMidiControlsSub`) under the Pedal setup row in `lib/control/view/pedal_tray_body.dart`.
- **Page files:** `lib/control/view/midi_controls/`.
  - `midi_controls_page.dart`: `MidiControlsPage`, with an in-page `_MidiView` enum (`list`, `editor`, `destinations`, `parameters`, `channel`, `format`). Back steps through the views.
  - `midi_device_cards.dart`, `midi_mapping_rows.dart`, `midi_source_panel.dart`, `midi_control_cards.dart`, `midi_choice_grid.dart`, `midi_segmented.dart`.
- **Editor rules:** `lib/control/binding/midi_mapping_draft.dart`. `MidiMappingDraft` has `of`, `learned`, `withChannel`, `withBehavior`, `withControl`, `repointing`, `without`, `withRange`, `withTrigger`, `toMapping(newId)`, `conflictIn`, `canSaveIn`, `carriesActions`, `drivesActions`, `offersKnobOrButton` and `offersButtonBehavior`. The draft lives in the widget.
- **Source names and "Received" lines:** `lib/control/binding/midi_labels.dart`.
- **Overlap:** computed from the draft, not carried by Learn, because the channel can still change.
- **Meters:** the page subscribes to `MidiDeviceRepository.messages` itself and feeds `MidiSignalLevels`, so a moving fader redraws only the meters.
- **Device cards:**
  - Each card shows Connected, Connecting, Disconnected or Could not open, and Available for the other inputs.
  - A tap calls `MidiSetupCubit.select(id)`.
  - The rows show the mappings of the input in use.
- **What the performer sees:** the list, with a power button per row that saves at once, MIDI control On/Off and Add mapping; No mappings; Controller disconnected; the editor source panel (format, Received readout, channel, Learn and Cancel Learn, the overlap with Edit existing mapping, Knob / fader or Button, Momentary or Toggle); the control cards (From/To, Off/On, Released/Held or Value, When: Pressed | Released, Change control or Repair control); the pickers; and the notices. `HANDOFF.md` section 7 and `research-pen-spec.md` give the full spec.
- **Strings:** `app_en.arb` +428 lines, `app_es.arb` +84.

**Commit `efa5a24f`: review fixes.** Five parallel reviewers produced 26 candidates. Each was checked against the code, and each fix has a test that fails without it.
- Every Learn start refuses a format that carries no press while the mapping drives actions, not only the format picker. Before, Cancel Learn followed by Learn another control could learn a 14-bit or relative source that Save then refused, with nothing on screen saying why.
- Opening a picker stops a listening Learn. A Learn that already heard its control keeps its Received readout.
- `saveMidiMapping` keeps the saved mapping's `enabled`, so a power-button write still in flight is not undone.
- A Save, Delete or MIDI control switch that finishes after the performer opened another editor no longer closes that editor or writes a notice into it.
- Choosing Button again no longer turns a Toggle into Momentary.
- The meters:
  - keep their readings through a visit to the editor;
  - drop a half pair on disconnect;
  - store the last whole `MidiControlEvent` instead of a fraction. `levelOf` was replaced by `lastOf`.
- Each `Semantics` wrapper that hid its `InkWell` now carries the tap, so screen readers can press every control.
- Smaller fixes:
  - the Repair control notice now says that Save keeps the change;
  - None in the action picker returns to the editor;
  - the list's notices sit under the rows in the warning style;
  - a disabled row uses the theme's disabled opacity;
  - the two behavior groups have their own accessible names;
  - the unused `MidiEdit.editingId` was removed.

**Decisions**
- **Departures from `segno-ui.pen`**, listed in the drafted body:

  | # | Pen | Built | Why |
  | --- | --- | --- | --- |
  | 1 | Settings grid MIDI tile (`gVIpz`) | Control face row | The app has no ten-tile Settings home |
  | 2 | Controls / Sync top-bar tabs | Crumb "SETTINGS / MIDI" | MIDI Sync is not built |
  | 3 | USB / DIN on device cards | Input status | `MidiDevice` reports no transport; one input at a time (#1040) |
  | 4 | In-page Performance actions grid | Shared `showControlActionPicker` | One action catalogue for every picker |
  | 5 | Values in the parameter's own units | Percentage of range, as on External pedals | Not stated beyond matching External pedals |

- **Defaults taken from `HANDOFF.md` section 5 that the body does not list:**
  - Mappings stay in app settings (`midi.mappings`, global to the rig), although `accepted-behavior.md` item 9 has session recall restore musical MIDI assignments.
  - The relative step is still a fixed `0.01` for every parameter; the design says the target's step.
- **Recording status:** the body says the departures are "Recorded on #1026 as well". That note has not been posted, and nothing records a write-back to the pen. Pencil needs a manual File > Save, and the computer-use tools were disconnected. Until both happen, the departures exist only in the local PR body.

**Verification**
- **Suites:** root 2468 passing, plus `packages/controller_repository`.
- **Static checks:**
  - `dart analyze --fatal-infos` is clean apart from ten existing infos in `packages/looper_repository/test/models/fx_chain_group_test.dart`, a file this branch does not touch.
  - `bloc lint lib` is clean.
- **Tests:**
  - `test/control/control_cubit_midi_test.dart`: session, timeout, failed write, write order, Edit existing, disconnect and reconnect, Save keeping `enabled`.
  - `test/control/binding/midi_mapping_draft_test.dart`, `test/control/binding/midi_labels_test.dart`.
  - `packages/controller_repository/test/midi_signal_levels_test.dart`.
  - `test/control/midi_controls_page_test.dart`: 40 `testWidgets` at `efa5a24f`; the body says 41.
  - `test/control/midi_controls_parts_test.dart`: 6 tests.
- **Screenshots:** `test/screenshots/midi_controls_screenshots_test.dart` produces 13 goldens at 1920x1080, `goldens/midi_controls_{list,empty,disconnected,knob,button,cc14,relative,learn,conflict,channels,formats,destinations,parameters}.png`, compared by eye with pen sections 26 and 53. `control_center_tray.png`, `control_center_control_pedal.png` and `control_center_control_pedal_bank_b.png` were regenerated for the new row.
- **Mutation checks**, as listed in the body:
  - the session: resume on close, pause on open, the other device resumed;
  - write-first, serialized writes, and the decoder reset on Learn;
  - the timer cancel on capture;
  - Learn start, applying the learned control, and Save while listening;
  - resume on Cancel and on leaving the page;
  - save and delete failure handling, and the action and format refusals;
  - the device filter, the action offer, the missing warning and the timeout message;
  - Edit existing, Change control and the card tap;
  - the channel copy, `nextId`, and the signal levels.

**Open items**
1. **Push and open the PR.** Run `gh auth login`, then `git -c credential.helper='!gh auth git-credential' push`. Open the PR with the four planned labels and `Part of #1026`, and run `/code-review` before setting `review:clean`.
2. **Post the #1026 note** with the section 5 decisions and the five departures, and write the departures back to the pen (geometry plus a `c/` note).
3. **Not built, listed in the body:**
   - encoder editing and double-tap reset of a range (there is no shared encoder-focus model);
   - the held-instrument rule (instruments slice);
   - Pan and balance targets (`ControlValueTarget` has only `FxParamTarget`, `TrackVolumeTarget` and `MasterGainTarget`).

   The Program-only Value slider was built even though no pen screen draws it.
4. **Not in the body:**
   - the MIDI Sync tab (epic #1009 slice 6);
   - USB/DIN transport;
   - the per-target relative step;
   - moving mappings into session recall.
5. **`ControlCubit.close()` and holds.** It cancels the Learn timer and the subscriptions but does not end engine holds. `HANDOFF.md` asked for a check of what a close during a hold leaves persisted; no result is recorded.
6. **#1040** still needs an owner call.

### 4g.5 PR B, old model removed: local `claude/midi-old-model-removal-1026` -> `claude/midi-controls-page-1026`, unpushed, no PR number

- **Planned title:** `refactor(midi): the old MIDI binding model and fixed CC scheme are removed`.
- **Planned labels:** the same four as PR A.
- **Body:** `part-4g-midi/pr-b-body.md`. Its line "Stacked on the MIDI controls page PR" needs PR A's number.
- **Size:** 78 files, +389/-8703.

**What it built**
- **`controller_repository`, deleted:** `controller_repository.dart` (`ControllerRepository`), `controller_mapping.dart` (the fixed CC 80-86 scheme), `looper_action.dart`, `controller_event.dart`, `controller_binding.dart`, `controller_binding_event.dart`, `controller_binding_set.dart`, `controller_source.dart`, `simulated_controller_source.dart`, and the six old tests with `test/helpers/fake_controller_source.dart`.
- **`controller_repository`, trimmed and moved:**
  - `controller_input.dart` loses `MappingTrigger` and the `trigger`, `channelTrigger` and `isPress` getters. `RawControllerInput` and `ControllerSourceKind` stay.
  - `BindingBehavior` moves into `lib/control/binding/pedal_binding.dart`, its only user.
  - The `fake_async` and `mocktail` dev dependencies are dropped.
- **`midi_client`:** `MidiControllerSource` loses the debounced `inputs` stream and `implements ControllerSource`, and delivers every message on one stream.
- **App wiring:**
  - `lib/app/run_segno.dart` and `lib/app/view/app.dart` lose the repository and simulated-source wiring. Nothing in the app had ever disposed `ControllerRepository`, so no disposal path is lost.
  - `ControlCubit` (-672 lines) and `ControlState` lose the old binding, learn and simulate paths.
  - `LooperBloc` loses its controller subscription, `_onControllerEvent`, `_toggleMetronome` and `_cancelPendingArms`; `lib/looper/view/looper_page.dart` is updated.
  - `settings_repository` loses the `controller.mappings` load and save. The stored blob is never read again, with no migration.
- **UI:**
  - Deleted: `lib/control/view/midi_tray_body.dart`, `lib/control/control_tab.dart`, `lib/control/binding/controller_learn.dart`, `lib/audio_setup/view/midi_learn_section.dart`.
  - `control_tray_panel.dart` becomes one body with the Pedal setup and MIDI controls rows.
  - `settings_tray_cubit.dart` / `settings_tray_state.dart` lose the tab.
  - `audio_settings_section.dart` drops EXTERNAL MIDI CONTROL.
  - 66 strings are deleted from both locales.
- **Added:** `ControlCommand.tapTempo('command:tap-tempo')` in `lib/control/binding/control_action.dart`. It is dispatched in `_runAction` as `_looper.tapTempo()`, with label `actionTapTempo`.
- **Docs:**
  - `docs/MIDI_FOOT_CONTROLLER.md` is rewritten for the page.
  - `docs/PROGRESS.md` and `docs/RUNNING_ON_RPI.md` are updated.
  - In `packages/segno_engine/src/core/segno_engine_api.h`, the MIDI block comment now lists Program Change and no longer mentions CC 80-83. Only the comment changed, and no ffigen regeneration is recorded.
  - `.github/cspell.json` adds `NRPN`, and the package descriptions are rewritten.

**Decisions**
- AGENTS.md says not to keep backward compatibility, and the accepted design reserves no CC scheme.
- Tap tempo is added because the fixed scheme was the only external path to it, and the accepted catalogue lists `command:tap-tempo`. The fixed scheme's click toggle and cancel-arm have no entry in the accepted catalogue, so they are removed with it.
- The old reference-counted "two momentary controls on one target" behavior is deliberately not ported; the engine restores each mapping's own Released value.

**Verification**
- **Suites:** root 2380 passing, plus `controller_repository`, `midi_client`, `midi_device_repository`, `settings_repository` and `pedal_repository`.
- **Ported tests** in `test/control/control_cubit_midi_test.dart`:
  - "Tap tempo reaches the engine";
  - "master gain keeps the encoder accumulator in step";
  - "a parameter gone from the rig writes nothing and throws ...";
  - "a knob value holds when the controller disconnects".
- **Deleted tests:** `test/control/control_cubit_controller_test.dart`, `test/audio_setup/view/midi_learn_section_test.dart`, `test/looper/bloc/midi_looper_integration_test.dart`, the MIDI groups in `control_face_test.dart`, and the old cases in `looper_bloc_test.dart`.
- **Goldens:** `control_center_control_midi.png` and `control_center_control_midi_device.png` are deleted; the three control center tray goldens were regenerated and compared by eye.
- **Static checks:** `dart analyze --fatal-infos`, `bloc lint lib` and cspell are clean.
- **Review:** no independent review of this commit is recorded.

**Open items:** push, open the PR, run `/code-review`, and post on #1026, as for PR A.

### Gotchas specific to MIDI control

- **Use the undebounced stream.** Always read `MidiDeviceRepository.messages`. Until PR B lands, the debounced `inputs` stream still exists, and it drops half of a 14-bit or NRPN pair.
- **Both paths run until PR B lands.** A device test on #1049 or PR A still has the CC 80-86 scheme and `controller.mappings` bindings dispatching.
- **One input, and pedal numbers are claimed on every device.** The app captures one MIDI input (#1040), and a mapping from any other device never dispatches. `isPedalProtocolInput` takes no device or channel, so Learn skips the footswitch Notes, Notes 10-13, the encoder CC and CCs 0x11/0x12 from every controller. Only Learn filters them; dispatch does not.
- **Check before `withMapping`.** `MidiMappingSet.withMapping` throws. Check `problem` and `conflictWith` first. `fromJson` silently drops bad entries.
- **Overlap rules.** Overlap is refused against disabled mappings and across formats (shared footprint, channels that meet, same device).
- **bloc lint and return values.** `bloc lint` refuses public cubit methods and getters that return values. The MIDI methods therefore return `Future<void>`, and the page tells a save from a failure by reading `state.midiMappings` afterwards.
- **`tester.runAsync` hang.** A cubit method that chains on a stored future (`_serialMidiWrite` on `_midiWrites`) hangs inside `tester.runAsync`.
- **Late async results.** Save, Delete and the MIDI control switch can finish after the editor changed. Check that the same editor is still open before closing it or showing a notice (fixed in `efa5a24f`).
- **Two Learn rules to repeat on every new path.** Any new way to start Learn must repeat the press-less format refusal while actions are mapped. Any new picker must stop a listening Learn.
- **ARB files** contain duplicate keys. Edit them as text, never through a JSON round trip.
- **Widget tests:**
  - Stub `messages`, `connections`, `activity` and `connection` on a mocked `MidiDeviceRepository`.
  - Close stream controllers unawaited in `tearDown`.
  - A bloc push needs two pumps.
  - Pen-sized rows overflow the 800x600 test surface.
  - Artwork in goldens needs `tester.runAsync` with `precacheImage`.
- **`Semantics` wrappers** that contain an `InkWell` must carry the tap themselves, or screen readers cannot press the control.
- **Research line numbers are stale.** The reports in `part-4g-midi/` cite line numbers against `63d8d7b5`, which PR A and PR B have moved. Grep before relying on them.
