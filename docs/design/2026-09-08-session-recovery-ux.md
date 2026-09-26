# Session recovery and shared behavior review

September 8, 2026. Proposal requested after the owner accepted the audit closure UI pass. This is a working, silent browser prototype; the new recovery behavior is ready for owner review. It does not certify appliance recovery or close the remaining shared-behavior decisions.

## Repair and return

From Library, select a saved session and choose **Open session**. Normal valid sessions keep their accepted path. Missing, unreadable or changed imported audio opens a compact list of the affected references. Each row identifies where the file is used. **Find audio** lists readable internal recordings; imported loop replacements must match the source duration and format so the existing timing recipe stays intact. Prepared backing audio can use a different recording.

One replacement updates every affected reference to that file: prepared order, loaded backing and imported track descriptors. These changes stay in a pending snapshot. **Cancel**, Stage or leaving for Audio Library discards the repair; no session is opened. Audio setup is the deliberate exception: the pending repair survives that excursion and Back returns to it.

**Open session** commits the repaired snapshot and preserves the outgoing session in one storage transaction. During playback it reads **Stop and open**. An unavailable audio interface blocks opening and links to existing Audio setup. Save failure retains the repair for retry. A changed saved source is rejected; changed replacement media requires renewed selection. New Loop or another successful session replacement retires an old repair draft. Malformed references produce a controlled error.

The proposal intentionally requires a ready interface before opening through this path; offline session editing has not been accepted. It does not silently substitute physical input/output ports, resize audio or skip a missing dependency.

## What this pass does not cover

This model repairs existing prepared/backing/import descriptors against simulated internal media. It does not reconstruct a missing recorded layer, read a native session manifest, recover corrupted WAV bytes, recover power-loss writes or verify content hashes. Repairing missing MIDI endpoints, physical port associations and every possible FX dependency remains open. Source-owned parameter repair from the previous pass remains separate and working. USB audio can be imported through the accepted Audio Library flow; this chooser does not perform an additional USB copy transaction.

The eight shared contracts are described in [three proposed performance demos](2026-09-08-shared-behavior-proposal.md). Those examples are a review script, not eight new implemented behaviors: recording/clock rules; interrupted-take and grouped recovery; sound processing and session/physical ownership. Existing accepted behavior stays in force until a specific conflicting choice is approved.

## Review entry points

- [Missing media](fx-ux-prototype.html?review=session-recovery)
- [Find replacement](fx-ux-prototype.html?review=session-recovery-files)
- [Ready to open](fx-ux-prototype.html?review=session-recovery-ready)
- [Failed save and retry](fx-ux-prototype.html?review=session-recovery-error)
- [Unavailable interface and return](fx-ux-prototype.html?review=session-recovery-device)
- [Browser and Pen references](session-recovery-previews/index.html)

## Verification

The model, recovery study and existing media/session model tests pass: 37 tests. The new Chrome and Firefox journey covers pending edits, Cancel, actual storage failure, retry, reload, device setup/return, full encoder selection/Open and Stage/Library exit. Existing session Library browser checks also pass, including contrasting-session recall, capture guards and foot entry. That older harness was updated to follow the already accepted Manage → Rename path and recognize Tracks as the existing default startup screen.

Five editable 1920 × 1080 references are saved under **36 Session recovery · proposal** in `segno-ui.pen`. Native checks report no clipped nodes; subpixel import rounding and chooser border styling were corrected. Browser and native screenshots were visually inspected. These are author checks, not CI, native audio or hardware evidence.

Independent role review and exact validation evidence are recorded in [the recovery review](../reviews/2026-09-08-session-recovery/review.md). No commit, publication or merge is part of this pass. Audit item LX-181 remains partial; the other behavior, reference, production and hardware gates are unchanged.
