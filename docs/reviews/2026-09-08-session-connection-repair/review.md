# Session connection repair review

September 8, 2026. Ready for local prototype review, with no unresolved findings
in the bounded connection-repair change. The new behavior is a proposal under
issue 919. No production, appliance, GitHub CI or merge readiness is asserted.

The implementation follows the
[plan](../../plan/2026-09-08-session-connection-repair-plan.md). The pure model
owns compatibility and exact-ID remapping, Library owns the pending request,
and the host retains the existing saved-session publication boundary.

## Independent review

| Role | Report | Unresolved findings |
| --- | --- | --- |
| VGV | [Report](raw/vgv-review.md) | 0 |
| Architecture | [Report](raw/architecture-review.md) | 0 |
| Test quality | [Report](raw/test-quality-review.md) | 0 |
| Readiness | [Report](raw/pr-readiness-review.md) | 0 |
| Simplicity | [Report](raw/code-simplicity-review.md) | 0 |

Reviewers excluded their own implementation or test files and disclosed those
boundaries. The coordinator read all five results. Reviewed source hashes match
the final files; baseline hashes in the simplicity report describe the earlier
revision and are not presented as current evidence.

The reviewer reproduced a held-choice bug: disconnecting USB before releasing
its pedal could select MIDI In instead. Contacts now retain their exact action
and request context. A monotonic revision also invalidates a contact after Back
and reentry to the same picker. Final browser assertions cover both cases plus
Cancel/reopen, Reset and paging. A duplicated option lookup was removed; the
assignment summary now comes from the validated repair result.

## Behavior checks

- 19 new model tests pass. Combined connection, ownership, media and recovery:
  72/72 pass. The focused model reports 98.59% line, 83.82% branch and 100%
  function coverage; this is not whole-prototype coverage.
- `verify_session_connection_repair_browser.cjs`: Chrome and Firefox pass on
  the normal storage-enabled URL, including touch, complete encoder navigation,
  foot paging and stale contacts, compatibility/collisions, pending Cancel,
  disconnect and failed-write retry, media repair sequencing and reload.
- Existing `verify_session_field_ownership_browser.cjs` and
  `verify_session_recovery.cjs` pass in both browsers.
- The coordinator reran `verify_pedal_closure.cjs` on the final host revision:
  Chrome and Firefox pass, including foot loop-mode confirmation.
- Source syntax and scoped whitespace checks pass. No Dart, native engine,
  firmware or dependency files changed in this slice.

## Saved visual evidence

[Four-state gallery](../../design/session-connection-previews/index.html), with
Chrome, Firefox and editable Pen references. The user can open any state directly
in the main prototype. Review URLs are screenshot/demo fixtures; functional
persistence checks use normal storage.

Pen section 40 contains four 1920 × 1080 screens. Native checks cover 207 text
positions, 481 element rectangles and four contained focus outlines. All 40
current flow groups are contained without overlap. The only greater-than-one-pixel
clipping is the intentionally scroll-clipped third track in the background
Library. Subpixel font/geometry rounding is under one pixel; modal controls fit.
All four native renders were inspected against the browser captures. The old
retry-only guard is moved into the Superseded group and removed from the current
gallery. Seven already-current references missing from the older gallery manifest
were reconciled; the manifest and HTML now both contain 278 current references.

The file was saved through Pen and the on-disk change verified:
92,607,865 bytes; SHA-256
`5970ec7a932493378c8dc9ebf449847d9add9810f0c8b7a8f21a70eeda126b65`.
Gallery links and images resolve, and the layout fits 1440-pixel and 420-pixel
viewports. Frame IDs, links and native checks are recorded in the
[manifest](../../design/session-connection-previews/manifest.json).

## Remaining boundaries

Missing archived-session effect/parameter targets still require explicit repair.
Controller discovery, native recorded layers, audio processing, durable storage
and physical-appliance recovery remain unverified. The owner did not settle the
downstream-tail, capture-tap or broader field-ownership proposals by asking to
continue. LX-181 remains partially open; this is not a claim of full audit closure.
