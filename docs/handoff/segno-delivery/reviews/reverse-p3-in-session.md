Model: Claude Opus (subagent), in-session

# Review of origin/claude/reverse-1162-p3 (c6a101a7b): Foot Reverse surface, mappings and Tracks marker (#1162 Part 3)

## Scope

- Branch `origin/claude/reverse-1162-p3` at `c6a101a7b`: `a02e09b69` (surface), the merge of trunk `68ed3f957`, and `c6a101a7b` (power-off test). Diff against `68ed3f957`: 39 files, +2131/-64.
- Reviewed against `docs/plan/2026-10-05-feat-foot-reverse-plan.md` (section 3, Part 3 and "Part 3 as built"), AGENTS.md, the owner rules, and the pen `segno-ui.pen` section "13 Performance · Reverse". I read the pen through the pencil MCP and did not save it.
- Covered: `InteractionMode.reverse`, the model, actions and cubit part, the LED and physical mask, `TrackOperation.reverse` through Custom, CTRL and MIDI, the overdub refusal (`overdubRefusals` to the record-refusal toast), `takeLocked` gating, `FootReverseView`, the `_ReverseMarker` overlay, and l10n.

## Runs

All runs used my own worktree at `c6a101a7b` with a fresh TMPDIR per native run.

| Suite | Result |
|---|---|
| Native plain | ALL PASSED x5, rc 0 |
| Native ASAN (`-fsanitize=address -g`) | ALL PASSED x5, rc 0 |
| Native `-DLE_CALLBACK_TELEMETRY=0` | ALL PASSED x5, rc 0 |
| App `flutter test` | +3368 ~49, all passed |
| `packages/looper_repository` (`SEGNO_ENGINE_LIB` set) | +805, all passed |
| `packages/session_repository` | +122, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues found |
| `bloc lint lib test packages` | 0 issues, 830 files |

- Part 3 has no native diff. The native runs confirm the base only.
- Focused JSON run of the Reverse files plus `tracks_screenshots_test.dart`, `control_action_test.dart` and `app_test.dart`: 171 tests, 165 passed, 6 skipped, 0 failed.
  - The four `foot_reverse_*` goldens ran on this machine, which has the screenshot fonts, and matched.
  - So did `tracks_reverse_marker.png`.
- Composition check:
  - The branch merges cleanly into the current trunk (`56033baf0`) and with Part 2 (`5a9803915`).
  - On a trunk + P3 + P2 merge commit, analyze and bloc lint are clean.
  - The same merge passes the app suite (+3372 ~49), looper_repository (+807) and session_repository (+126).

### Mutation run

Each mutation was applied in a probe worktree and checked against the targeted suites. 22 attempted, 13 killed, 9 survived.

| Mutation | Result |
|---|---|
| `_runTrackOperation` reverse arm returns false | killed |
| `overdubRefusals` never emitted | killed |
| overdub toast uses the #1146 title | killed |
| LED drops `hasContent` | killed |
| LED always off | killed |
| `_slotless` false for Reverse | killed |
| `_takeLocked` removed from `_reverseEditable` | killed |
| `FootReverseActions.toggle` skips availability | killed |
| all-tracks Reverse run sequentially | killed |
| custom "lit" uses any instead of every | killed |
| marker always visible | killed |
| marker a11y label dropped | killed |
| track pedal ignores the active bank | killed |
| `sessionTransitionActive` removed | survived |
| visit-identity check in `_reportReverseFailure` removed | survived |
| session-revision check in `_reportReverseFailure` removed | survived |
| `trackPressed` reverse arm made inert | survived |
| `available` ignores `pending` | survived |
| marker ignores `hasContent` | survived |
| Exit no longer bypasses the editable gate | survived |
| Undo role changed to Stop | survived |
| `toggleMode` stays in Reverse | survived |

## Verified correct (traced)

- **Every Record press reaches `LooperRepository.record`.** This covers the pedal (`_recAdvance`), the Reverse surface Rec/Play, MIDI and External (`_runAction` → `_recAdvance`), the on-screen bloc (`looper_bloc.dart:40`) and the Rec-mode switch paths (`control_cubit.dart:1645, 1823-1827, 2907`).
- **The overdub refusal is reported in every mode.** `record()` wraps `_record()` and emits on `overdubRefusals` only for `EngineResult.reversed` (`looper_repository.dart:2937-2943`). The #1146 retry only arms for EMPTY tracks, so a reversed refusal is never retried; `record_retry_test` asserts this. `app.dart` shows the existing record-refusal toast with the Reverse title, gated off while the power UI is up.
- **`takeLocked` gates every entry.**
  - `_reverseEditable` covers the surface, `trackPressed` and the semantic activation.
  - `_pressBinding` (`:3113`), `_fireCustomAction` (`:2467`), `_fireExternal` (`:497`), the external contact path (`:446`) and MIDI (`control_midi.dart:587`) gate the assigned path before `_runAction`.
  - The new power-off test kills the `_takeLocked` mutation.
- **LED and physical mask.**
  - In Reverse mode a track LED is blue only for `hasContent && reversed`.
  - The slot-less mask now treats Fade and Reverse alike through `_slotless`.
  - The `PedalMode.custom` wire mode is mirrored in `invariants.dart`.
- **Tracks marker.**
  - It reads `track.hasContent && track.reversed` from the repository projection, so it survives Exit.
  - The forward layout is untouched. `git diff 68ed3f957 c6a101a7b -- test/screenshots/goldens` changes only `pedal_setup_picker.png`, which is expected because the mode picker lists Reverse. Every existing Tracks golden is byte-identical.
- **Pen fidelity.** The pen's screen 01 (Reverse / Playback direction) texts match the app: "Reverse", "Playback direction", "Forward", "Reverse", "Empty", "Switch bank", "All tracks" and "Exit". The as-built note documents the departures (REV meta-row marker instead of the pen's "‹ Reverse" pedal caption, display-case names, 24 px detail).
- **No boot into Reverse.** `bootDefaults` stays `[record, mute]`, so `bootDefaultFromToken('reverse')` coerces to Record.

## Findings

### Medium 1. The REV marker paints over the layers figure in Spanish and with multi-digit counts

**Where:** `lib/looper/view/track_column.dart:683-716` and `:730-770` (`_ReverseMarker` with `FractionalTranslation(-1, 0)`).

**What happens.** REV takes no layout space. It is drawn leftward from the FX slot into whatever gap `MainAxisAlignment.spaceBetween` happens to leave after the layers figure. Nothing guarantees that gap is at least as wide as REV plus 12 px.

**Probe.** I ran a real-font probe in `tracks_screenshots_test.dart` on this machine, at 1920x1080 with 4 columns and track 2 reversed. It compares the right edge of `tracks_layers_1` with the left edge of `tracks_reverse_1`:

| Locale | Bars / layers | Layers right edge | REV left edge | Overlap |
|---|---|---|---|---|
| en | 1 / 1 | 825.9 | 848.6 | clear |
| en | 128 / 12 | 847.0 | 848.6 | 1.6 px gap, touching |
| es | 16 / 1 | 850.2 | 848.6 | overlaps |
| es | 16 / 12 | 858.3 | 848.6 | overlaps ~10 px; reads "12 capaREV" |
| es | 128 / 12 | 863.2 | 848.6 | overlaps ~15 px |

- Crops are saved beside this file: `rev-overlap-es-16bars-12layers.png` and `rev-touch-en-128bars-12layers.png`.
- In a narrower desktop window, `ShrinkToWidth` collapses the `spaceBetween` gaps first, so the overlap gets worse. An Ahem-font probe at 1280x800 and 1024x600 overlapped in every case.

**Why the tests miss it.** The branch's own geometry test (`tracks_view_test.dart`, "a forward track holds the marker width") checks only English, 1 bar and 1 layer.

**Failure scenario.** A Spanish-locale player with a 16-bar loop and a few overdub layers reverses track 2. The Tracks meta row then reads "16 compases 12 capaREV": the unit is overwritten and the marker is illegible.

**Suggested fix.** Either give REV a real slot that is invisible while forward (the plan's original "opacity 0 while forward so the row never reflows", section 3) and write the extra slot back into the pen, or anchor REV somewhere with guaranteed room. Then add the probe matrix above as a test: `es` locale, 16 and 128 bars, 12 layers, asserting `rev.left >= layers.right`.

### Medium 2. A recorded track that is overdubbing or has a pending arm reads "Empty"

**Where:**
- `lib/control/model/foot_reverse.dart:119-123` defines `available = hasContent && !isCapturing && !pending`.
- `lib/looper/view/foot_reverse_view.dart:254-259` (`_directionWord`) maps every `!available` track to `readoutStateEmpty`.
- `:323-329` passes `detailIcon: null` and `enabled: false` for those tracks.

**Probe.** I added a widget test with track 1 OVERDUBBING at 48000 frames and track 2 PLAYING with `pending: true`. Both overview cells render `[TRACK n, Empty]`. The pedals read "Empty" too and are disabled.

**Failure scenario.**
1. On the Reverse surface, the player presses Rec/Play on a forward cursor track. This is allowed: it is `_recAdvance(state.cursor)`.
2. The track starts overdubbing, or arms a quantized overdub.
3. Its overview cell and pedal now say "Empty" until the pass ends. Pressing the pedal does nothing and gives no notice.

**Why it matters.** This breaks owner rule 3 (no silent behaviour changes), because the surface misstates the material. The Fade precedent uses `available = hasContent` only (`foot_fade.dart:228`), so this is a Reverse-only regression. It also departs from plan decision 1 ("Toggle while the track writes ... refused with a receipt and a notice"). Section 3 instead says "refusing unavailable tracks ... without a notice", so the plan contradicts itself and the build took the silent reading.

**Suggested fix.**
- Split the model into `hasContent` (word and icon) and `available` (can toggle now).
- Render a busy recorded track with its real direction word, dimmed.
- Choose explicitly between a silent no-op and the failure toast for a stomp on a busy track, and record the choice in the plan.
- Add a test for overdubbing and pending tracks. The `available-ignores-pending` mutation currently survives.

### Low 3. `trackPressed` has a live Reverse arm that no production path reaches

**Where:** `lib/control/cubit/control_cubit.dart:1807-1808`.

**What happens.** In Reverse mode, the physical track pedals route through `_onPress` → `_onReversePress` (`:2358-2361`) and never reach `trackPressed`. The on-screen Tracks columns are replaced by `FootReverseView`, so they cannot reach it either. The only callers are tests: the new power-off test calls it to assert nothing toggles.

**Why it matters.** Fade's arm is `break`, and the custom arm's comment says on-screen surfaces call `trackPressed` for selection. If any surface calls it in Reverse mode in future, a tap would toggle direction rather than select. The `trackpressed-inert` mutation survives the whole suite.

**Suggested fix.** Make the arm inert like Fade, or name the caller it serves and test that path.

### Low 4. Test gaps around the refusal-report and editable guards

Every mutation in this group survived the suite:

- **Session-transition gate.** Removing `!_fxPersistence.sessionTransitionActive` from `_reverseEditable` (`control_foot_reverse.dart:9`) changes nothing in the suite.
- **Visit identity.** Removing the `identical(visit, _surfaceVisit)` check (`:47`) also passes, because the existing "not after the visit ended" test is caught by the mode check. Nothing covers Exit and re-entry while a refusal is still in flight.
- **Session revision.** Nothing covers a session revision change during the toggle (`:49`).
- **Exit while locked.** No test pins the Exit bypass (`:13-16`): Exit must work while the surface is not editable.
- **Undo and Clear inertness.** "Undo and Clear are inert" asserts no undo, clear or toggle, but not that transport is untouched. Remapping Undo to Stop passes, while the plan criterion is "Undo/Clear are inert".
- **`toggleMode` from Reverse.** Nothing pins that `toggleMode` returns to Record (`control_cubit.dart:1312-1315`); a mutation that keeps it in Reverse passes.

**Suggested fix:** add one assertion or test per guard.

### Low 5. Spanish strings

These are the 10 new keys in `lib/l10n/arb/app_es.arb:2694-2703`, with my judgement of each. The ARB keeps the performance terms "Fade" and "Overdub" in English and uses "sobregrabar" in prose, and I judged the new keys against that convention.

| Key | Spanish | English | Judgement |
|---|---|---|---|
| `actionModeReverse` | "Reverso" | "Reverse" | Weak. "Reverso" is the back side of a coin or page, not a playback direction. The file keeps "Fade" in English, so "Reverse" is the consistent choice. If a Spanish word is wanted, "Reversa" (Rioplatense, as in "poner reversa") or "Al revés". |
| `actionOperationReverse` | "Reverso" | "Reverse" | Same as above. |
| `footReversePlaybackDirection` | "Dirección de reproducción" | "Playback direction" | Acceptable. "Sentido de reproducción" is more precise in Spanish: "sentido" names forward or backward, "dirección" the line. |
| `footReverseForward` | "Adelante" | "Forward" | Weak as a state word; alone it reads like "go ahead" or "come in". Prefer "Normal" (it pairs with the chevron) or "Hacia adelante". |
| `footReverseReversed` | "Reverso" | "Reverse" | Weak; same as the mode name. Prefer "Reverse", or "Al revés" or "Invertida". |
| `footReverseSwitchBank` | "Cambiar banco" | "Switch bank" | Good. Close to the existing "Cambiar de banco A / B". |
| `footReverseFailure` | "No se pudo invertir la pista. Inténtalo de nuevo." | "The track could not be turned around. Try again." | Good, and follows the file's "No se pudo … Inténtalo de nuevo." pattern. Minor: "invertir" can read as polarity inversion to audio users; "No se pudo cambiar el sentido de la pista." avoids that. |
| `footReverseOverdubRefused` | "No se puede sobregrabar mientras la pista está en reverso" | "Overdub is unavailable while the track is reversed" | Grammatical, but "en reverso" is not idiomatic. Prefer "…mientras la pista suena al revés" or "…mientras la pista está en Reverse". |
| `stageReverseMarker` | "REV" | "REV" | Good. |
| `a11yStageReversed` | "La pista se reproduce en reverso" | "Track plays reversed" | Prefer "La pista se reproduce al revés". |

The Spanish golden (`foot_reverse_spanish.png`) shows "Reverso" in the title and on the pedals, so a wording change needs that golden regenerated.

## Notes

- **Pre-existing truncation.** "Grabar / Repr..." is truncated on the Spanish Rec/Play caption. Fade's `foot_fade_spanish.png` has the same truncation, so it is not this branch's regression.
- **Reverse is not undoable.** This matches the plan, and the history is untouched.
- **Size.** The as-built note's +901/-62 production lines exceed the plan's 700-line review ceiling; the note acknowledges it, and the view mirrors Fade's.
- **Assigned all-tracks Reverse.** It toggles every recorded scope member in parallel, and the custom "lit" state needs every recorded member reversed. Both are tested and the mutations were killed.
- **Hardware evidence outstanding.** The plan's appliance criterion (physical footswitch, LED, listening on a division, with a running fade, overdub refusal) is manual and not evidenced on the branch. That is expected for `autonomy:merge-gate`.

Verdict: Request changes (Medium 1, the REV overlap, and Medium 2, the "Empty" busy tracks; the Low items can ride along)

## Delta review (d221f0dba)

### Scope

- **Head:** `d221f0dba` ("fix(control): REV takes a slot, busy tracks keep their direction"), on top of a merge of trunk `7a9fdcbd9` (`133e44d5b`).
- **Fix commit:** 14 files changed.
- **Trunk changes:** the 18 non-Reverse golden changes in the branch diff come from the trunk merge. Against `7a9fdcbd9`, the only goldens that differ are the four `foot_reverse_*` files, `pedal_setup_picker.png` and `tracks_reverse_marker.png`. Every forward Tracks golden is byte-identical to the trunk's.
- **Native code:** there is no native diff against the trunk.

### Runs

All runs used my own worktree at `d221f0dba`.

| Run | Result |
|---|---|
| Native plain | ALL PASSED x5, rc 0 |
| Native ASAN | ALL PASSED x5, rc 0 |
| Native `-DLE_CALLBACK_TELEMETRY=0` | ALL PASSED x5, rc 0 |
| App suite | +3387 ~49, all passed |
| looper_repository (with `SEGNO_ENGINE_LIB`) | +805, all passed |
| session_repository | +122, all passed |
| `dart analyze --fatal-infos lib test packages` | no issues |
| `bloc lint` | 0 issues, 851 files |

**Mutations.** I ran 18 mutations against the targeted suites, with the screenshot suite included for the layout mutations. 17 were killed and 1 survived.

| Mutation | Result |
|---|---|
| session-transition gate removed | killed |
| visit check removed | killed |
| session check removed | killed |
| `trackPressed` Reverse arm made live again | killed |
| busy ignores `pending` | killed |
| marker ignores `hasContent` | killed |
| Exit blocked while not editable | killed |
| Undo changed to Stop | killed |
| `toggleMode` stays in Reverse | killed |
| busy toggle posts to the engine | killed |
| busy stomp silent | killed |
| busy cell not dimmed | killed |
| busy word reads Empty | killed |
| busy pedal disabled | killed |
| `spacing` floor removed | killed |
| REV–FX `SizedBox` removed | killed |
| REV slot shown on a forward row | killed |
| `detailHighlighted` ignores busy | survived (Low D1 below) |

The first nine are all nine survivors from my first pass, adapted to the new code. The rest are new mutations of the fix.

### Earlier findings

**Medium 1 (REV overlap): resolved.**

- `_TrackMeta` now lays REV out as a real child before FX, only while the track is reversed (`track_column.dart:656`, `:687-695`). The row has `spacing: 12` under `spaceBetween`.
  - With room to spare, `spacing` with `spaceBetween` gives the same positions: each gap is `s + (W - Σ - s(n-1))/(n-1) = (W - Σ)/(n-1)`. That is why the forward goldens are unchanged.
  - When the row is tight, the row grows to Σ + spacing and `ShrinkToWidth` scales it down as one piece.
- **Real-font probe.** I ran it at 1920 and 1280 widths; 1280 is the narrow window. Matrix: en and es, at 1/16/128 bars, with 1 or 12 layers.
  - **No overlap anywhere.**
  - At 1920 the gap from layers to REV is 20.9 px in the worst case (es, 128 bars, 12 layers), and REV to FX is exactly 12.
  - At 1280 the gaps are 7.3–10.9 px on screen. That is the 12 px floor scaled with the row.
  - Crops: `delta-rev-es-128bars-12layers-1920.png` and `delta-rev-es-128bars-12layers-1280.png`.
- **The two changed goldens.**
  - `tracks_reverse_marker.png`: BOOM's row reads "2 — bars 1 layer REV". Its figures have shifted left by the marker's slot, and the other three columns are untouched.
  - `foot_reverse_spanish.png`: shows the new words ("Reversa", "Sentido de reproducción", "Normal").
  - Both look right.

**Medium 2 (busy tracks read "Empty"): resolved.**

- The model is now `recorded` (= `hasContent`) plus `busy` (= `isCapturing || pending`).
- The overview cell and the pedal show the real word and chevron, dimmed (`Opacity(disabledOpacity)`). The pedal stays enabled.
- `FootReverseActions.toggle` returns `notReady` for a busy track before posting.
- `_toggleReverseChannel` stays silent only for a track that is not recorded, so a busy stomp reaches `_reportReverseFailure`, which shows the toast.
- Plan decision 1 and section 3 now agree.
- Tests: "a busy recorded track is refused with one notice, then turns once it settles", plus the view test. The busy mutations are all killed.

**Low 3 (`trackPressed`): resolved.** The Reverse arm now falls through to `break` with Fade (`control_cubit.dart:1804-1807`), and a test pins it.

**Low 4 (test gaps): resolved.** All 9 earlier survivors are now killed, with the new tests for the session transition, the visit, the session revision, Exit while not editable, Undo/Clear leaving the transport alone, the Mode cycle, and the marker's content check.

**Low 5 (Spanish): resolved.** The new strings:

| Key | New Spanish |
|---|---|
| mode and operation | "Reversa" |
| state words | "Normal" / "Reversa" |
| overview heading | "Sentido de reproducción" |
| failure | "No se pudo cambiar el sentido de la pista. Inténtalo de nuevo." |
| overdub refusal | "No se puede sobregrabar mientras la pista suena al revés" |
| screen-reader label | "La pista se reproduce al revés" |

- All are idiomatic. "cambiar el sentido" avoids the polarity reading of "invertir".
- "Inténtalo" is the tú form rather than the Argentine "Intentalo". That matches every other retry string in `app_es.arb`, so it is consistent with the file.
- "Cambiar banco" and "REV" are unchanged and fine.

### New findings

**Low D1. A busy reversed pedal's de-highlighting has no test.**

- **Where:** `foot_reverse_view.dart` `detailHighlighted: reversed && !track.busy`.
- **What is missing:** reverting it to `reversed` passes the suite.
- **Impact:** cosmetic only. The pedal is already dimmed through the overview and the detail colour.
- **Fix:** add one assertion to the busy view test.

**Low D2. `busy` misses a pending Count-in launch, though its doc says it covers one.**

- **Where:** `lib/control/model/foot_reverse.dart` documents `busy` as "writing or has an arm or launch pending", and the plan's as-built text repeats it. The projection reads only `isCapturing || pending`; `Track.pendingLaunch` is not included.
- **Failure scenario:** during a Count-in, a track whose launch is pending shows its direction undimmed and its stomp posts. The native admission refuses it (`le_reverse_admit` returns `LE_ERR_NOT_READY` on `a_pending_launch`), and the same notice appears.
- **Impact:** the behaviour is still the notified refusal; only the dimming and the docs disagree.
- **Fix:** either add `pendingLaunch != null` to `busy`, or correct the doc.

### Notes

- **Reversed rows shift.** Reversing a track now shifts that track's bars and layers figures left by the REV slot, relative to forward neighbours: 15–20 px at 1920. In a tight window it also scales that one row slightly smaller. This is the documented trade for never overlapping ("reversing a track reflows that track's own row"). It departs from the original "reflows nothing" wording. Like the other pen departures, it should be written back to the pen's `c/` note for screen 04.
- **Pre-existing truncation.** "Grabar / Repr..." is still truncated on the Spanish Rec/Play caption, as on Fade's Spanish golden.
- **Hardware proof** for Part 3 remains manual and outstanding.

Verdict (d221f0dba): Approve. Medium 1, Medium 2 and Lows 3–5 are resolved. The two new findings, D1 and D2, are Low and can follow up.
