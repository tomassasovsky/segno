# Recording recovery review

September 8, 2026. The authorized local prototype slice is complete. No remaining
actionable findings were reported by the five review roles. This is a bounded
review of recording recovery and its display/persistence seams; it is not a
whole-repository, production audio, CI or merge certification.

## Delivered behavior

- Accepted Multi partial-take recovery preserves the established loop duration,
  captured-region position and silence, without changing mode or stopping peers.
- Active Clear All is a working proposal: freeze partial audio, cancel arms,
  recover the group with capturing tracks stopped, and preserve later mix/FX.
- Publication failures preserve the current content, capture, queue and history.
  Offline Redo retains its recoverable entry until playback is available.
- Wave, the small display and length edits share captured-region metadata.

The [design record](../../design/2026-09-08-capture-recovery-ux.md) distinguishes
accepted Multi behavior from the demonstrated Clear All, defining-take and
fixed-window Sync/Band proposals. The 183-row audit retains its open decision
and production gates.

## Verification

| Check | Observed result |
|---|---|
| Focused capture recovery | 21/21 passing |
| Existing audio-state reconciliation | 10/10 passing |
| Existing transport/history suite | Passing |
| New normal-URL recovery browser journeys | Chrome and Firefox passing |
| Existing integrated audio-state browser journeys | Chrome and Firefox passing on final implementation |
| Song/Band mutation checks | Omitting normalization or moving it after publication makes the two new candidate-state tests fail |
| Audit ledger | 183/183 IDs, unchanged baseline, CSV/JSON parity and valid evidence paths |
| Review gallery | All 10 browser/Pen images decode at 1920 × 1080; all links return 200 |
| Main Pen gallery | 267 references, including five new recovery states |

Pen was updated through native tooling, text fitted to browser geometry, encoder
focus aligned and screenshots inspected. The only actual clipped descendants
are the existing meter fills clipped by their meter containers, matching the
browser. Scale/grid labels intentionally overflow non-clipping wrappers; they
are visible in both renderings. Section 37 contains the five new frames inside
the current UX group. File → Save changed the on-disk design hash; the final hash
is recorded in `evidence.json`. Pen and screenshot inspection are local author
verification, separate from automated behavior evidence.

## Review roles and resolved findings

| Role | Report | Scope |
|---|---|---|
| VGV | [Raw report](raw/vgv.md) | Independent implementation review; test authorship disclosed |
| Architecture | [Raw report](raw/architecture.md) | Transport, atomic publication, host ownership and recovery invariants |
| Test Quality | [Raw report](raw/test-quality.md) | Independent model-test review and mutation checks; browser authorship disclosed |
| Simplicity | [Raw report](raw/simplicity.md) | Shared history and region model, without extra UI or compatibility paths |
| Local readiness | [Raw report](raw/pr-readiness.md) | Parsing, scope, evidence and current hashes; no PR/CI claim |

Review corrected three implementation problems: incompatible short Sync/Band
Clear recovery, offline Redo consuming its history, and section exclusivity
being applied after rather than inside the saved candidate. Test review also
found that the Song/Band publication ordering lacked a regression; two new
tests now detect both omission and incorrect ordering.

The working directory contains unrelated pre-existing edits and untracked design
work. Review used a captured local baseline where available and inspected the
narrow length-edit and exporter additions separately. No unrelated work was
staged, committed, pushed or merged. No Dart, firmware or native engine code was
changed. Real PCM, sample-clock accuracy, resource exhaustion and durable
power-loss recovery remain in the production plan.
