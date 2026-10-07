Model: Claude Opus (subagent), in-session

# Review of origin/claude/pitch-time-1179-p4b (15a4acf57, no PR yet): feat(looper): edit Follow tempo and Pitch on the Audio & tempo page and keep them with the Session

## Scope

- **The commit:** one commit, `15a4acf57`, on top of 4a-iii (`32922f796`). It touches 77 files (+2980/-139); 1139 production lines, excluding tests, goldens, ARB, bindings and docs.
- **What it adds:**
  - **Owned settings:** `FollowTempoFamily` and `PitchModeFamily` on the shared settings owner; `PlaybackOptions.followTempo` / `pitchMode`, null while not ready; staging and settling in `audio_bootstrap.dart`; toasts.
  - **Page:** `loop_audio_tempo_page.dart` for 07/04-07/06, the hub summary, EN/ES strings and six goldens.
  - **Session:** schema 14 (lands as 16): the recorded pair, `tracks[].spanFrames`, and both vectors with strict decode; the 13 → 14 conversion fills the vectors from the live settings.
  - **Recall of a retimed rig:** native `le_engine_import_span`, the commit's span-aware laps, snapshot `recorded_length_frames` and `span_frames`; in the repository, the restore order and `_retimeSession`.
- **Reviewed against:**
  - plan Part 4b and its "As built" note;
  - §4.4, decisions 8 and 21 (E15);
  - the 4a-ii budget text;
  - the ledger (Session schema: 14 = M/D P2, 15 = backing P5, then next free);
  - the pen's 07/04-07/06 (reN7g, MfjIH, hujmY), read through the pencil MCP (text, selection state, option icons; not saved);
  - AGENTS.md and the owner rules.

## Runs

| Run | Result |
|---|---|
| `git merge-tree` against `origin/claude/segno-integration` (`890f04936`) | clean |
| Native suite, plain / ASAN / telemetry-off | ALL PASSED x5 each, exit 0 |
| `flutter test` packages/segno_engine (SEGNO_ENGINE_LIB from this head) | +383, all passed |
| `flutter test` packages/looper_repository (same lib) | one failure in the full run, in a test this part does not touch: `re-apply on restart … only a subsequent start announces exact FX replay confirmation`, which uses 20 ms real-time delays while the machine's load average was about 70. It passed alone three times and in two reruns of its whole file (+381). |
| `flutter test` packages/session_repository / settings_repository | +251 / +204, all passed |
| `flutter test` at the app root (same lib) | +3484 ~56, all passed |
| `dart analyze --fatal-infos lib test packages` | No issues found |
| `bloc lint lib test packages` | 0 issues, 879 files analysed |
| Mutations H6-H7 on the native recall (`mutate5.py`, saved here) | 2 of 2 killed (`test_follow_session_recall_spans`) |
| Probe `probe_division_recall` (`test_rv_probes4b.h`, saved here) | see M1 |

## Verified correct (traced)

- **Owned settings.**
  - One stored nullable bool per address, nine addresses per family. Pitch is stored as "follows speed".
  - An absent default restores Follow **On** (E15) and Pitch Unchanged. The engine's own default stays 0, so a bare engine and the native suites are unchanged.
  - Both families are staged before audio opens and settled after start, in both the auto-start and first-run paths.
  - Refusals and recovery raise the standard toasts (EN/ES).
  - `PlaybackOptions` projects null while an owner is not ready. The page then shows the value it would restore, disabled, and a tap requests nothing (tested). This closes 4a-iii's L1.
- **Page against the pen.**
  - The texts match the pen exactly: "Recorded audio follows the song tempo." / "Keeps its recorded speed, even when the song tempo changes." / "Changes speed without changing the notes." / "Faster raises the pitch. Slower lowers it." / "Pitch stays unchanged at the recorded speed."
  - Default/Custom tags and Use default match.
  - Defaults select On and Unchanged, as reN7g does.
  - A scope that keeps its recorded speed shows Pitch as the "Unchanged" readout with its note (06).
  - EN/ES key sets match, and there are goldens for all three screens in both languages.
- **Session schema.**
  - The recorded pair is both-or-neither with 30-300 BPM; spans are ≥ 0; overrides name tracks 0-7. A wrong type throws a `FormatException` (or a cast error, as the file's other fields do).
  - The repository refuses a malformed pair, span or override before the rig is cleared.
  - A rig saves the pair only when it is retimed or a take sits on another span (`_retimed`, `_spanOf`), so an unretimed rig writes 0/0 as schema 13 implied.
  - The conversion fills both vectors from the live durable settings, the schema-8 precedent, with no pair and spans 0. It notes each filled field. Its test opens the v13 Reverse fixture.
  - The schema number (14 here, 16 at landing, conversion keyed 15) follows the ledger.
- **Recall of a retimed rig.** The order:
  1. Pitch vector.
  2. A temporary all-follow vector, because the retime needs a follower.
  3. `restoreTempo(recorded)`.
  4. The takes, with `le_engine_import_span` for a take on another span.
  5. Commit on the recorded master.
  6. `setTempo(session tempo)`.
  7. A check that the master lands on `baseLengthFrames`.
  8. The session's own Follow vector.

  On the native side, `a_import_span` is kept apart from the live span (the import's transform reset clears that) and is reset by the next lane-0 import or layer ordinal 0. The commit adopts it, laps the take over the span (`k = len / span`) and re-derives the rate. `test_follow_session_recall_spans` proves:
  - a take recorded after the retime is parked at 1333 on the recorded clock;
  - at 90 BPM every take reads at its own ratio;
  - overdub is allowed on the on-span take;
  - a retried import starts without a span.

  The Dart native case and the mapping test cover the repository side. A sample-rate mismatch is refused before any of this (`SessionSampleRateMismatch`).
- **Mutations** on the native recall: dropping the commit's adoption of the import span (H6), or the reset on a new lane-0 import (H7). See Runs.

## Findings

### High

None.

### Medium

**M1. A retimed rig that had a Sync division at the retime cannot be recalled: `_retimeSession` throws.**

- **Where:** `looper_repository.dart` `_retimeSession`, with `le_tempo_retime`'s divisor round-up.
- **Cause:**
  - The live retime rounds the new length up to a whole multiple of the largest active Sync division.
  - Sessions never encode a division: the commit zeroes `a_sync_divisor` (`engine_process.c:4673-4678`, "deferred to B5c").
  - At recall the same `setTempo` therefore yields the unrounded length, and the strict check (`masterLengthFrames != rig.baseLengthFrames` → "session retime was refused") fails the load after the takes were imported.
- **Probe (native, the recall's sequence):**
  - A live Sync rig (8000-frame master, a 4000-frame division track) retimed to 90 BPM: master 10668, divisor 2.
  - The same takes imported, committed and set to 90: master 10667, divisor 0.
  - At 48 kHz this happens at any tempo whose bar is an odd frame count (for example 97 BPM: 118762.9 rounds to 118763, rounded up to 118764 with n = 2).
- **Effect:** the session cubit then stops the engine and rolls the mix back, so a valid saved session fails to open.
- **Fix (pick one):**
  - save and restore the divisor round-up, for example a `retimedLengthFrames` the recall installs;
  - let the recall accept the length the engine lands on when it differs only by the division rounding;
  - refuse to save a retimed Sync-division rig with a notice, until B5c encodes divisions.
  Add the case to the native recall test.

**M2. The part is 1139 production lines against a 300 estimate and the 700 ceiling.**

- **Natural split:** (a) owned settings, page and Session vectors; (b) recall of retimed rigs (native `le_engine_import_span`, commit laps, snapshot fields, the restore order, the recorded pair and spans in the schema).
- **Why it is a clean seam:** (b) depends on (a)'s schema bump, but each is testable alone, and (b) is where M1 lives.
- **Fix:** split, or say why not in the PR body.

### Low

**L1. The page's option icons are not the pen's.**

- **Pen:** Off ↦, On ⇄, Unchanged ≡, Follows speed ↗.
- **Page:** Lucide timer-off, timer, music, audio-lines.
- **Origin:** the icons were already on the trunk's placeholder page, so 4b carried them rather than introduced them.
- **Fix:** this part claims 07/04-07/06, so either match the pen or record the deviation in the pen (`c/` note), per the "deviating updates the pen" rule.

**L2. No fixed-point tests for the not-ready fallback or the hub.**

- Not ready, the page shows the restore value (On) disabled, while the engine may hold Off after an uncertain receipt. Disabled plus the recovery toast is the owned-settings precedent, so this is acceptable. A golden of the owed state would pin it.
- The hub summary strings ("Follow tempo · Same pitch", "Recorded speed · Same pitch") have no pen frame to check against (the hub row is the pen's, the summary composition is not), so they could not be verified against the pen.

## Notes

- **Follow On for existing installs.** Switching Follow on by default is a behaviour change for existing installs: a tempo change on a rig with content now retimes, and with Pitch Unchanged it renders stretches. The owner approved it (E15; the plan's status line). The page and the hub show it, and there is no one-time notice. It is worth a line in the release notes.
- **Tempo source after recall.** It reads manual after recalling a retimed rig (labelled).
- **4a-ii's budget gate still holds:** the 8 x 8 retime case is the owner's Pi measurement.

Verdict: Request changes (M1; M2 is a split decision).
