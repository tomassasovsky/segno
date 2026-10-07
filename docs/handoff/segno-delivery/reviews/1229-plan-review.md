Model: Claude Opus (subagent), in-session

# Review of PR #1237 (claude/foot-surfaces-plan-1229 at 0a61a90ba): Foot surfaces plan, #1229

## Scope

- `docs/plan/2026-10-06-feat-foot-surfaces-plan.md` (the only file in the PR, +795).
- Its `file:line` claims, checked against trunk `097e1ef68`. Branch-qualified claims were checked on:
  - PeelP3 `c79280778`;
  - LibP5 `cd721f202`;
  - the Settings plan `c0458eec8`;
  - the Recording plan `57a5324b8`;
  - PR #912 `15401db9d`.
- The pen: the main checkout's `segno-ui.pen`, read only through the pencil MCP and never saved. I read every screen in the brief:
  - section 10: `PRSrG`, `hmEBj`, `uEukr`, `noDGu`, `ri60q` and note `MV9wz`;
  - section 04: `J8U51x` and `WmJsF`;
  - section 23, screens 1 to 5: `o9d3X`, `lDOKf`, `d9CLS`, `sMhKO` and `ta3Fj`;
  - 24/1 `nGtjy`, 19/02 `U2bRH`, 19/06 `uRKTE`, 20/03 `E7kQV`, 20/05 `dgedL` and 20/06 `owAnd`.
- `accepted-behavior.md` §4 (`:286-309`), the issues #692, #601, #884, #873 and #909, the Library P5 review (`library-p5-in-session/review.md`) and the Library P4 review.

## Runs

- Scratch worktrees for trunk `097e1ef68` and the plan head `0a61a90ba`, both removed afterwards.
- `git merge-tree --write-tree 097e1ef68 origin/fix/tuner-callback-latency-909` reports `CONFLICT (content): Merge conflict in packages/segno_engine/src/core/engine_private.h`. PR #912's base `4d0408fc4` is an ancestor of the trunk, and so is `origin/master`.
- CI on PR #1237: every reported check is green, spell check included.
- The PR changes no code, so I ran no suites and no mutations. Every finding below comes from tracing trunk code.

## Verified correct (traced)

- **§1 boundary.**
  - These `file:line` claims hold on the trunk: modes and `bootDefaults`, the `setMode` and `_invalidateGestures` spans, and the face switch (`tracks_view.dart:219-225`).
  - The `_HoldGesture` shape (`control_cubit.dart:72-120`), `_armGesture` (`:2690-2703`) and the external-jack site (`:467`) also hold.
  - So do the FX dispatch (`:2374-2437`), `_armStop`/`_armStopRestore`/`_armBank`, `_armCustom` (`:2450-2462`), `_togglePerformanceRecordAccepted` (`:2818-2825`), `takeLocked` (`app_runtime.dart:154-155`) and the tuner and monitor-mute lines.
  - On the native side: `LE_CMD_SET_TUNER_INPUT` (`engine_process.c:3509-3525`), `mon_mut` (`:4950`, `:5408`), the tuner tap before the lanes (`:6805`), the monitor-mute plog (`:3887-3892`) and the boot value -1 (`engine.c:799`).
  - Only the cross-plan citations drift (L10).
- **D1 is consistent with the pen.**
  - The #692 Candidate A notes (`Jq4Fp` `c/stage-fx` and the later overlay and option notes) all sit in `02 EARLIER APPLICATION`.
  - `01 CURRENT UX` › 10 › 03 `Performance / FX` (`noDGu`) is a full pedal map: chain names, Toggle/Hold detail lines, Exit lit, and Rec/Play, Stop, Undo and Clear at opacity 0.3.
  - Replacing the Tracks-column re-dress follows the pen.
  - `fxTarget` and `inputNames` are never passed in `lib` (only `test/looper/view/tracks_view_test.dart:1003-1187` uses them), which confirms the #884 diagnosis.
- **D2 (native tuner mute) is the right shape.**
  - OR-ing a mask into `mon_mut` reuses the existing mute path. That path also feeds `perf_tap_monitor_frame(…, 0, 0)` for a muted captured input (`:5408-5410`), so the monitor stem matches what was audible.
  - Lane capture reads `in_c` and is unaffected.
  - The detector taps `in_c` before the monitors.
  - Disarm clears the mask in the same command, and boot and configure zero it, so the mask cannot outlive the tuner.
  - It never touches `a_muted`, so a saved, Session-captured or perf-logged monitor mute cannot pick up a temporary mute. That is exactly the separation the brief asks for.
  - The literal values in `test_tuner_mute_literal` and `_keeps_monitor_mute` (0.3, 0.7, 0.9) are right for the fixture `test_monitor_mute` uses, which has unity gain at centre pan. See L3 for one missing arm step.
- **Pen geometry.**
  - Pending Hold: `IBL3g` is 159.16 x 3 at (20.92, 221), track `#303b4b` and fill `#a8c7fa`, and the held hint is `#d2e3ff`.
  - FX held contact `ri60q`: the held pedal's `Hold` detail is `#d2e3ff`.
  - Tuner 23/1: reference block 418 x 120 at (0, 90), reading block 852 x 279 at x 868, note 120 px, direction 27, cents 21. The Stop words (`Unmute input`/`Input muted`, `Mute input`/`Input audible`), `Hold · 440 Hz`, `Inputs 1–4` dimmed with one page, and `Inputs 17–18`/`Next inputs` with two `—` pedals all match.
  - 20/03 puts `Stop recording` on **Stop**, so §6's correction of Recording Part 13 is right.
  - `uEukr` does dim Record/Play (Hold · Peel), Stop and Undo (Hold · Redo), as the plan says.
- **Settings Part 6 contract.**
  - Part 6's four deliverables match the Settings plan's `:550-566`: a foot surface over the app-wide `TunerCubit`, no `TrayPanel` under `lib/tuner` or `test/tuner`, tray-free tuner tests, and `openSegnoSettings` instead of `SettingsTrayCubit`.
  - The plan also catches the third tray user, `foot_reverse_view.dart:85`, which the Settings plan misses.
  - See M3 for the gap this leaves.
- **Notice policy against Reverse P3 and PeelP3.**
  - Reverse on the trunk splits `recorded` and `busy`. An empty track is disabled and silent. A busy recorded track stays enabled and is refused with a notice (`foot_reverse_view.dart:337-340`, `control_cubit.dart:2139-2148`).
  - PeelP3's listener is not gated on the mode, and `TrackOperation.peel` reports its refusal from any mode.
  - Rules 1 and 2 of §3 match both. Exceptions are H1 and M4.
- **D6 matches the Recording plan.**
  - Its guard table row `sessionApply (Open, New loop)` says "a running take is finished first: today's `disarmAndFinalize`" (Recording plan `:601`).

## Findings

### H1. High: Part 3 leaves assigned Fade and Reverse refusals silent from every mode but their own

- **Where:**
  - Plan Part 3, "Refusals" (`:374-386`), and the criterion "Fade, Reverse and Peel keep their own toast and add none".
  - Trunk:
    - `control_cubit.dart:2645-2656`, where `_runTrackOperation` for `fade`/`reverse` returns `result.isOk` and reports nothing;
    - `control_foot_fade.dart:66-75` and `control_foot_reverse.dart:45-54`, where the reporters return unless `state.mode` is fade or reverse;
    - `tracks_view.dart:139-160`, where both listeners are gated on the mode.
- **The false premise:** the plan treats Fade and Reverse like Peel: "Operations that already report their own refusal keep their toast". On the trunk only the face methods report (`:2147`, `:2161`). An assigned Fade or Reverse goes through `_runAction` → `_runTrackOperation`, and nothing reports a refusal there.
- **Scenario:**
  1. Custom track 1 has Press = Fade on Track 3.
  2. Track 3 is recorded, and the fade write is refused, for example while the fade settings await recovery (`FootFadeActions.toggle` returns `EngineResult.invalid`).
  3. Part 3 excludes Fade from `assignedActionFailure`, and `footFadeFailure` is neither bumped nor shown outside Fade mode. The stomp does nothing and says nothing.
- **Why it matters:** this breaks §3 rule 3, D10 and owner rule 3. The plan's own criterion cannot pass as written.
- **Fix:**
  - Either do what PeelP3 did: report the refusal inside `_runTrackOperation` for `fade` and `reverse` from any mode, and drop the mode gate on those two listeners;
  - or let Fade and Reverse bump `assignedActionFailure`.
  - Add the Custom-mode Fade and Reverse refusal cases to Part 3's tests.
- **Related:** `_fireCustomAction` returns before `_runAction` for an `UnavailableAction` (`control_cubit.dart:2473`). A notice hooked only into `_runAction` misses "an unavailable target", which Part 3 lists explicitly (L9).

### H2. High: the FX face ignores bindings on Rec/Play, Stop, Undo and Clear, so it misreports pedals that act

- **Where:**
  - Plan Part 2, Model (`:299-301`): "Stop: `All FX off` …; Rec/Play, Undo, Clear: unavailable (inert today)".
  - The §3 table: "Rec/Play, Undo and Clear have no action in FX and stay dimmed and silent".
- **Trunk:**
  - `PedalBindingKey.unbindable` holds only MODE and Bank (`pedal_binding.dart:68-71`).
  - FX `_onPress` looks up a binding for every button before the switch: a bound Rec/Play, Undo, Clear or Stop runs its binding, and Stop keeps the restore hold (`control_cubit.dart:2378-2397`).
  - The assignment page binds these switches (`test/pedal/view/pedal_assignment_page_test.dart:239`, `:269`, `:277`), so this is a real configuration.
- **Scenario:**
  1. The user binds Clear to a Master reverb chain, momentary.
  2. In FX mode the physical Clear switch holds the reverb on, and its LED follows.
  3. The face draws Clear at 0.3 opacity with no caption, and an on-screen tap does nothing, because `PerformancePedal` drops contacts when `!enabled` (`performance_pedal.dart:93`).
  4. A bound Stop reads `All FX off` while its tap runs the binding and no panic.
- **Fix:** project a binding on all eight bindable switches with the same title and Toggle/Hold rules as the track switches. Fall back to the dimmed or panic caption only when unbound. Test a bound Rec/Play and a bound Stop.

### M1. Medium: D3's captions misdescribe the FX panic, and "clear current actions" is a design call, not a caption

- **Where:**
  - Plan D3 (`:741-742`) and Part 2 (`:299`): Stop is `All FX off` with hint `Hold · Restore FX`.
  - Trunk: `_sweepTrackChains` (`control_cubit.dart:1916-1923`) flips only Track-stage chains. Disable skips chain-less tracks. Enable force-enables every track chain.
- **Scenario:**
  1. Pedal 1 is bound to `Master · Reverb` and pedal 2 to `Input 1 · Gate`, the target kinds the #692 rework was about.
  2. A Stop tap leaves both on while the face says `All FX off`.
  3. A Stop hold turns on a track chain the user had deliberately bypassed in the FX dock, while the face says `Restore`.
- **Why the reading is in question:**
  - Accepted §4's FX row says "clear current actions". That reads as clearing the actions the pedals made active, not as sweeping track chains.
  - The pen dims Stop on 10/03.
  - Keeping the behaviour satisfies rule 1, but the words have to say what it does.
- **Fix:**
  - Caption what the code does, for example `Track FX off` and `Hold · All track FX on`.
  - Or put "what Stop clears in FX" to the owner as Q3 and keep this part at `merge-gate` until answered.
  - Write the deviation into the pen with a `c/` note (L-note under M6).

### M2. Medium: Part 7 neither inherits nor names the #1216 capture-loss fix, and adds a second guard

- **Where:**
  - Plan Part 7, Dispatch (`:638-646`).
  - The LibP5 review, Finding 2 (`library-p5-in-session/review.md:96-101`), inherited from LibP4 Finding 2: New loop or Open during a capture drops the take, or fails as a save.
  - `origin/claude/library-1178-p4` is still `74e977324` and LibP5 is still `cd721f202`, so the fix has not landed.
  - Plan §1.6 and Part 7 do not mention the finding.
- **Problems:**
  1. **The guard is in the wrong layer.** Control refuses while a track "is capturing or has a pending arm", then bumps a pulse that an app-level listener turns into `SessionCubit.newLoop()` later. The check and the act are separated by a stream hop and by `_preserveOutgoing`'s fingerprinting and save, which `newLoop` runs before anything else (LibP5 `session_cubit.dart:465-468`). The guard has to sit inside `newLoop`, under `runExclusive`, where the Library button gets it too.
  2. **The two paths could disagree.** The #1216 fix may instead "end the capture … before preservation" (the review's first option). If it does, the foot path refuses with `Finish recording first.` while the Library button ends the take. That is two rules for one operation (rule 4).
  3. **The success toast fires for the Library button too.** D7's toast is keyed on `SessionOutcome.newLoop` in a listener, so it also fires for the Library button's New loop, which D7 says keeps its sheet only. That is two notices for one cause.
- **Fix:**
  - List "#1216 with its Finding 2 fixed" as Part 7's dependency.
  - Let `newLoop` own the capture rule with a typed refusal, and have the foot path map that refusal to its toast. Keep the Control-side check only as an early fast path that uses the same predicate.
  - Show the `<name> stays in your Library.` toast only for a New loop that this listener started, for example with a request id carried into `SessionState`.

### M3. Medium: after Settings Part 6, a default install cannot reach the Tuner at all

- **Where:**
  - Plan Part 6, Tray (`:579-582`), and the hardware criterion "MODE Hold → Tuner" (`:624`).
  - Settings Part 6: "the tuner is reached only by its foot function".
  - Trunk `PedalSetup` defaults: `modePress = mute` and `modeHold = custom` (`pedal_setup.dart:143-148`), and the Custom map is empty.
- **Scenario:**
  - A console with default pedal setup updates through Part 6 and Settings Part 6. The tray handle that opened the tuner is gone, and no switch, External input or MIDI control carries `Tuner`.
  - The tuner the player used yesterday has no route, and nothing says so. That breaks rules 1 and 3.
  - The pen's example Custom map does carry it (`uEukr`, Pedal 2 `FX` / `Hold · Tuner`), but nothing installs that map.
  - The hardware criterion only works after a manual reassignment of MODE Hold.
- **Fix:** state the default route. Either:
  - seed `Hold · Tuner` on an *empty* Custom slot for installs whose map is empty, as the pen draws (rule 1: only where nothing is assigned);
  - or keep one touch entry until a foot route exists.
  - Or put this to the owner as Q3/Q4.
- In any case, rewrite the hardware criterion with its setup step.

### M4. Medium: the plan breaks its own notice policy for stale, unavailable and saving switches

- **Where:**
  - Part 2: a stale binding is "disabled", while "a stomp on a stale binding" gets `footFxUnavailable` (`:294-296`, `:313-315`).
  - Part 3: a switch is "enabled when Press or Hold is assigned **and available**", while an unavailable target gets a notice (`:355-357`, `:374-377`).
  - Part 8: `Saving recording` is "unavailable" but "a physical press still gets a notice" (`:683`, `:690`).
- **Trunk:** `PerformancePedal` drops a contact when `!enabled` (`performance_pedal.dart:93`). The same cause is therefore silent on screen and notified by foot.
- **Part 8 contradicts §3 rule 2 directly:** a busy target stays enabled and a press shows the toast. Reverse follows that rule (`foot_reverse_view.dart:337-340`: "A busy recorded track still admits the stomp").
- **Fix:**
  - Keep stale, unavailable and saving switches **enabled**, drawn with their real words. The caption can be dimmed if the pen wants it.
  - Then on-screen and physical contacts both reach the dispatcher and give the one notice.
  - State this in §3 so PeelP3 and the later faces follow it.

### M5. Medium: PR #912 is an unowned prerequisite that already conflicts with the trunk and will conflict with Part 4

- **Where:** plan §6 (`:771-772`) and Part 6's last hardware criterion.
- **Facts:**
  - PR #912 is open, `autonomy:blocked-verify`, and based on `master`. It was last updated 2026-08-29.
  - A merge-tree onto `097e1ef68` conflicts in `engine_private.h`.
  - Part 4 adds `a_tuner_mute_mask` in the same tuner block of that header (`:1509-1521`), and #912 rewrites that block.
- **Impact:**
  - The foot Tuner exists to stay armed while loops play, and that is exactly the load #909 measures.
  - Shipping Part 6 without #912 makes the per-frame `memmove` and the unamortised YIN pass part of normal performance on the Pi 5.
  - Whichever of the two lands second has to resolve the conflict by hand.
- **Fix:**
  - Add a Part 0: rebase #912 onto the trunk and retarget it.
  - Order Part 4 after Part 0, or state that Part 4 rebases onto it.
  - Make "#912 on the trunk" a merge gate for Part 6, not only a hardware note.

### M6. Low: pen write-back is left to the PR text

- **Where:** D3 and Part 3's `uEukr` departure are "recorded in the PR for the owner to write into the pen" (`:388-391`, `:741-742`).
- **The rule:** a shipped departure is written back into the pen, geometry and `c/` note, not left only in a PR. The Settings plan at least named the note it owes (`c/ Interim · Settings destinations`).
- **Fix:** name the `c/` notes owed in sections 10 (`noDGu`: Stop and Bank captions; `uEukr`: Hold-only switches) and 01 (`PRSrG`: the cue's absence on Tracks/Mute, Q1), with who adds them.

### L1. Low: Part 1's hardware criterion cannot happen

- **Where:** Part 1 says "hold MODE on the foot Mixer: the bar fills over 800 ms".
- **Trunk:** MODE on the Mixer is `exit, immediate: true` (`foot_mixer.dart:161-164`), and `_onMixerPress` dispatches it on contact (`control_foot_mixer.dart:19-21`). Fade is the same (`foot_fade.dart:160`).
- **Fix:** use Undo on the Mixer (tap steps down, hold resets to unity).

### L2. Low: Part 1 uses the wall clock and can emit after close

- **Wall clock:** `pendingHolds` stores `DateTime.now()` instants, and the view computes `(now - start) / threshold`. The Pi has no RTC, and NTP steps the clock after boot.
  - **Fix:** use a monotonic `Stopwatch` elapsed time, or publish only the fact that a hold is pending and let the widget's controller own the timing.
- **Emit after close:** `onSettled` fired from `cancel()` during `close()` must not emit.
  - **Fix:** guard it on `isClosed`.

### L3. Low: Part 4's mask clamp and one native test

- **The clamp:** `mask & ((1u << in_channels) - 1)` is undefined behaviour at 32 inputs (`LE_MAX_CHANNELS 32`). The trunk guards the same idiom (`engine_process.c:3555-3557`); copy that guard.
- **The test:** `test_tuner_mute_keeps_monitor_mute` does not arm the tuner. The plan's own handler stores 0 for a mask while disarmed, so the expected 0.7 would fail.
  - **Fix:** arm input 2 first.

### L4. Low: the repository's remembered mask must clear on disarm

- **Where:** Part 4 has `LooperRepository.setTunerMute` remember the mask and re-send it on restart. `disarm()` is only `setTunerInput(-1)`.
- **Effect:** the native side is safe, because it stores 0 when disarmed. The Dart-side mask and `LooperState.tuner.muteMask` stay stale.
- **Fix:** clear the mask in `setTunerInput(-1)`.

### L5. Low: Part 5's interim tray arms from a widget and breaks a Settings criterion

- **Where:** Part 5 says "The tray face keeps working: until Part 6 it arms through `LooperRepository.setTunerInput` directly".
- **Layering:** a widget would call a repository, which breaks the layering.
- **Cross-plan clash:** Settings Part 5's criterion "arms TunerCubit" (Settings plan `:541`) fails once this Part 5 removes `arm`/`disarm` from `TunerCubit`.
- **Fix:** sequence the two plans explicitly, or keep thin `arm`/`disarm` on `TunerCubit` until Part 6.

### L6. Low: Part 5 shows the old input's pitch under the new input's name

- **Where:** Part 5 has `TunerCubit` start the 1.2 s stale hold on an input mismatch.
- **Effect:** for 1.2 s after a switch, the face shows the previous input's pitch under the new input's name.
- **Why it is wrong:** a mismatch means the reading belongs to another input; it is not "no signal".
- **Fix:** clear the reading at once on a mismatch.

### L7. Low: Part 2's #873 test expects the wrong text

- **Where:** the expected `Track 2 · lane 1`.
- **Trunk:** `fxStageLabel` renders `pedalAssignStageLoop` = `{trackName} lane {lane}` (`app_en.arb:1558`). That gives `Track 2 lane 1`, or the track's own name when it has one (#526).
- **Fix:** correct the expected text.
- **Also delete:** the `fxTarget` and `inputNames` cases in `test/looper/view/tracks_view_test.dart:1003-1187` go with the removed fields.

### L8. Low: Part 3's face cannot compute the LED state from `ControlState`

- **Where:** Part 3 sets `selected = _physicalCustomStates`.
- **The gap:** that state reads private cubit fields (`_customLastActions`, `_customActiveKeys`, `_pressedButtons`, `control_cubit.dart:3349-3392`), so `projectFootCustom(PedalSetup, ControlState, …)` cannot compute it.
- **Fix:** publish the lit map in `ControlState`, emitted next to `_pushProjected`. Otherwise the "cannot disagree" promise has no mechanism.

### L9. Low: `UnavailableAction` never reaches `_runAction` in Custom

- **Where:** `_fireCustomAction` returns at `control_cubit.dart:2473`, before `_runAction`.
- **Fix:** add the Part 3 notice at that return too, or the "unavailable target" row stays silent from Custom.

### L10. Low: some cross-plan citations point at other branches or other text

The plan says un-prefixed lines are on the trunk. These are not:

| Citation in the plan | What it actually points at |
| --- | --- |
| Library plan `:251-252` and D14 `:491-495` | LibP5 lines. On the trunk, D14 is `:424-428`. |
| Recording plan Parts 8 and 9 `:1000-1092` | Part 8 starts at `:1011` and Part 9 ends at `:1103`. |
| Recording plan "D9 `:635-660`" | The held-take text. D9 is at `:577`. |

### L11. Low: Part 8 bypasses the recorder cubit's failed-save state

- **Where:** Control calls the repository's `saveHeld()` directly.
- **The gap:** the Recording plan sets `Held(saveFailed: true)` inside the recorder cubit's own `saveRecovered` catch (Recording plan `:1095`). A failed foot retry therefore leaves the Record performance page without the 20/06 line.
- **Fix:**
  - Either carry `saveFailed` in the repository status, or route the foot retry through the cubit's method.
  - Confirm that the Recording plan allows arming a new take while one is held (Part 8's "absent drive arms a new take").

## Notes

- **The owner's #692 comment.** On 2026-08-26 the owner said "KEEP the track waveform visible behind FX cells … do NOT hide it". The current pen supersedes this with 10/03. Quote the #692 history in the PR so the owner sees that the FX face removes the waveforms that ruling kept.
- **Pen 04 versus the trunk binding model.**
  - Pen 04 (`J8U51x`, `WmJsF`) models activation per rack: On or Off latched, Held foot down, Released foot up. A pedal can carry several racks, which is why 10/03 titles pedal 1 `FX A1`.
  - The trunk `BindingBehavior` has only toggle and momentary, one target per key.
  - The face's Toggle/Hold line is right for the trunk model. `Released` and multi-rack titles wait for the E5-8 redesign; say so in Part 2's non-goals.
- **`FxChainLookup`** is an extension on `LooperRepository` (`packages/looper_repository/lib/src/fx_chain_lookup.dart:6`), not a type. "`projectFootFx(…, FxChainLookup)`" needs a concrete parameter, such as the repository or a name resolver, to stay a pure projection.
- **Goldens.** Adding the 3 px bar slot to `PerformancePedal` moves every existing face golden (Mixer, Fade and Reverse). Regenerating them on the author's machine belongs in Part 1's criteria.
- **Tuner D5 and the pen.** The plan's `Not monitored` detail is not drawn in pen 23, which draws only `Input muted` and `Input audible`. Name its source, the study, or drop it.

### The planner's questions

- **Q1 (a pedal strip on Tracks and Mute for the Pending Hold cue): no, not in this plan.**
  - Accepted §4 says Mute "stays on the normal track columns".
  - Pen 10/01 draws Tracks as a full pedal map (`hmEBj`), and the app has never built it. A strip would be a partial, unapproved version of that face.
  - The gap is real. The approved proposal is drawn on Tracks' MODE (`Mute`, `Hold · Custom`), the hold every default user meets. Record it in the pen (M6) and give the owner the choice of building 10/01 as its own piece of work. A strip invented here would be a second Tracks design.
- **Q2 (keep the performance recording running across New Loop by foot): keep D6 for this plan, but not silently.**
  - Finishing is the Recording plan's decided rule for every `sessionApply` (`:601`) and what the Library button does. A foot-only exception would give one operation two rules (rule 4).
  - New Loop keeps the chains, tempo and device (Library D9), so continuing the capture is plausible for recording a whole gig. That has to be decided once, for both New Loop paths, in the Recording plan's guard table, with the engine's events log checked across an apply.
  - The on-stage problem to fix now: on the trunk, finishing a capture opens the completion sheet (`tracks_commands.dart:449-457`). A foot New Loop mid-set would open a dialog over the new loop. Part 7 should say what appears. Prefer the persistent recording indicator or a toast over a sheet on the foot path.

Verdict: Request changes. H1 and H2 are factual errors against the trunk. M1–M5 need plan text before the build starts.

## Delta review (da5c89bf9)

### Scope

- `0a61a90ba..da5c89bf9`: two commits.
  - `1cf85d879` applies the review and the owner decisions.
  - `da5c89bf9` records the Part 1 and Part 4 builds.
- Checked against the trunk `097e1ef68`.
- Checked against PeelP3's current head `73f941d86`, including `456654207` ("an assigned Fade or Reverse that reaches no track says so").
- Checked against the #912 port `c54865297`, whose conflict resolution I read with `git show --remerge-diff`.

### Previous findings, re-checked

| Finding | Status | Evidence |
|---|---|---|
| H1 | Resolved by dependency. | Part 3 now depends on #1233. #1233's head really does report assigned Fade and Reverse from any mode (`_reportAssignedRefusal` in `_runAction`'s `TrackOperationAction` arm), and its listeners are no longer gated on the mode. A generic counter covers the rest, including the `UnavailableAction` early returns. |
| H2 | Resolved. | All eight bindable switches are projected. Unbound Rec/Play, Stop, Undo and Clear are dimmed, as `noDGu` draws them. The tests include a bound Rec/Play and a bound Stop. |
| M1 | Resolved by owner decision. | See DM1 for what is still missing from the plan text. |
| M2 | Resolved. | There is one `newLoop` path with no capture rule in Control. The toast is scoped to its request. The dependency on Finding 2's fix is named. |
| M3 | Resolved in principle (D11). | See DM2 for the gaps. |
| M4 | Resolved. | §3 rule 2 is rewritten: a switch with an action stays enabled. Parts 2, 3 and 8 follow it. |
| M5 | Resolved. | Part 4 is built on the port. Part 6 is merge-gated with a `merge-base` check. See DN1. |
| M6 | Resolved. | The write-back list W1–W6 names a coordinator owner. |
| L1–L11 | Resolved as mapped in §9. | I checked L1 (Undo on the Mixer), L3 (the 32-input guard and arming in the test), L4, L7 (`Track 2 lane 1`), L8 (`customLit`) and L9 (the early-return bumps) in the text. |

The answers to Q1 and Q2 are recorded as O1 and O2. Part 7's handling of O2 is better than either option I offered: the `sessionApply` stop cause shows a toast instead of the completion sheet, for every session apply.

### New findings

#### DM1. Medium: the owner's Q3 decision is not in the plan, and its two commands have no part

- **Where:**
  - §7 still lists Q3 as open, with "Recommended default, built in Part 2 unless the owner says otherwise".
  - Part 2 removes the panic (`:340-341`, `:357-358`), but its model, tests and success criteria never add `Track FX off` / `Track FX on`.
- **What is missing:** the two `ControlCommand` values, their membership in `ControlActionGroup.fx` (`control_action.dart:63-65`, empty today), labels and l10n, `_runCommand` cases, catalogue round-trip tests and the LED state.
- **Effect:** a builder following Part 2's criteria ships the removal without the replacement.
- **Fix:**
  - Record the owner's call as O3.
  - Move the commands into Part 2's work list, tests and criteria.
  - Keep `_sweepTrackChains`: the removal note "when nothing else uses it" (`:358`) would delete what the new commands need.
  - Also remove the FX arm of `ControlCubit.stop()` (`control_cubit.dart:1741-1742` calls `panicTrackChains()`). Nothing in `lib` calls `stop()`, but it is public and tested.
  - Caption `Track FX on` for what it does: it turns every track chain on, and does not restore the previous state.
- **Rule 3:** Q3 announces the removal only in a release note, while D11 uses a one-time in-app notice for a smaller change. A player whose FX Stop stomp stops working on stage gets no word. Give it the same one-time notice on the first FX entry after the update, or record that the owner accepted release-note-only.

#### DM2. Medium: D11's seeding can overwrite a malformed setup and re-seed after the user removes it

- **Where:** Part 6, "Default route": "an existing install gets it only where that Hold is empty … written to `pedal.setup` once".
- **Problems:**
  1. **There is no "seeded" marker.** If the rule is "seed where the Hold is empty", a player who deliberately removes `Hold · Tuner`, or uses "Clear custom assignments", gets it back at the next boot, with the notice again. That is a silent behaviour change each boot.
  2. **A malformed or uncertain setup is not excluded.** The trunk keeps a malformed setup inert "until a confirmed Save replaces those bytes deliberately" (`control_state.dart` `pedalSetupUnavailable`, and `pedalSetupPersistenceUncertain`). Seeding must not write `pedal.setup` while either flag holds, or it replaces bytes the user never chose to overwrite.
- **Fix:**
  - Persist a one-shot `pedal.tuner_default_seeded` flag, set on the seeding attempt whatever its outcome.
  - Skip seeding when either flag is set.
  - Test removal-then-reboot and malformed-setup-then-boot.

#### DL1. Low: two places in the plan disagree on goldens

- §9's Notes row says "goldens regenerated in Part 1".
- §10's build record says no golden moves, which is correct: I confirmed the 5 + 3 + 8 px slot in `performance_pedal.dart`.
- **Fix:** make the two agree.

#### DL2. Low: Part 3 names the wrong method for #1233's fix

- **Where:** Part 3 says #1233 reports "inside `_runTrackOperation`".
- **Actually:** PeelP3 `456654207` reports in `_runAction`'s `TrackOperationAction` arm, and only when no channel accepted.
- **Fix:** correct the citation so the builder hooks the generic counter beside the right code.

#### DN1. Note (process): the #912 port has no PR

- `claude/tuner-latency-909-trunk` (`c54865297`) has no pull request. PR #1248 targets it, so merging #1248 lands nowhere near the trunk.
- The port's conflict resolution in `engine_private.h` is sound by my reading: both types are kept, and the tuner members appear once. P4's native suite also passes on it.
- But the port has had no review or CI of its own, and Part 6's gate (`merge-base --is-ancestor origin/claude/tuner-latency-909-trunk HEAD`) only checks ancestry.
- **Fix:** open a PR from the port into the trunk, `autonomy:blocked-verify` as #912 was, and have the gate name that PR's merge.

### Delta verdict

Request changes. DM1 and DM2 are small text changes. Everything else in the delta is sound.

## Delta review (ff4cf38ec)

### Scope

- `da5c89bf9..ff4cf38ec`: five commits.
  - `b6453beef` records O3.
  - `86b82a28d` applies DM1, DM2, DL1 and DL2, the P1 review and the P4 review.
  - `573476fc9` fixes spelling.
  - `f52556057` and `ff4cf38ec` record the Part 2 build.
- Read in full as a diff.

### Earlier findings, re-checked

| Finding | Status | Evidence |
|---|---|---|
| DM1 | Resolved. | O3 is recorded, and §7 has no open questions. Part 2 now lists `trackFxOff`/`trackFxOn` (`command:track-fx-off`/`-on`) in `ControlActionGroup.fx`, with en/es labels, `_runCommand` cases and catalogue tests. `_sweepTrackChains` is kept. `panicTrackChains`, `restoreAllTrackChains` and the FX arm of `stop()` are removed. `Track FX on` is described as "all on, not a restore". The one-time in-app notice (`fx.stop_change_notice_shown`) and its tests are in. I confirmed all of this in the P2 code (`foot-p2-in-session/review.md`). |
| DM2 | Resolved. | `pedal.tuner_default_seeded` is set at the first attempt, whatever the outcome, so a removed `Hold · Tuner` never returns. Seeding is skipped, with the flag left unset, while `pedalSetupUnavailable` or `pedalSetupPersistenceUncertain` holds. It is written through the confirmed `setPedalSetup` path. |
| DL1 | Resolved. | §9 now says no golden moves in Part 1. |
| DL2 | Resolved. | Part 3 cites `_runAction`'s `TrackOperationAction` arm (PeelP3 `456654207`). |
| P4 L1 | Resolved. | Part 5 removes `TunerCubit`'s mismatch re-push of `setTunerInput`, explaining why under D12, and tests that the cubit never calls it on a mismatch. |
| D13 (new) | Sound. | MODE in FX exits on contact to `_fxReturn`, as pen `noDGu` draws (`Exit`) and accepted §4's foot Exit requires. Custom already behaves this way. The configured MODE pair no longer runs in FX. See P2 L3: the one-time notice could mention that in one clause (rule 3). |

The P1 review's M1, L1 and L2 are applied in Part 1 and §10.

### New findings

None against the plan text. P2's code-level findings are in its own review.
- M1: the FX face watches the whole `LooperBloc`.
- M2: titles use the effect type, not the rack name the pen draws.
- L1–L3.

### Delta verdict

Approve.
