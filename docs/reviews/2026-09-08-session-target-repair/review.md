# Saved control repair review

September 8, 2026. Ready for local prototype review. No unresolved actionable
findings remain in the bounded control-repair implementation. This is a design
proposal under issue 919, not production, CI, merge or appliance certification.

[Plan](../../plan/2026-09-08-session-target-repair-plan.md) ·
[Behavior and limits](../../design/2026-09-08-session-target-repair.md) ·
[Five-state gallery](../../design/session-target-previews/index.html)

## Independent review

| Role | Report | Unresolved findings |
| --- | --- | --- |
| VGV | [Report](raw/vgv-review.md) | 0 |
| Architecture | [Report](raw/architecture-review.md) | 0 |
| Test quality | [Report](raw/test-quality-review.md) | 0 |
| Readiness | [Report](raw/pr-readiness.md) | 0 |
| Simplicity | [Report](raw/code-simplicity-review.md) | 0 |

The coordinator read all five reports. Reviewers disclosed exclusions for their
own implementation/tests and prior shared modules. The five roles reviewed the
implementation at host hash `a98d6b45`, with unchanged final Library/model hashes.
A final one-condition demo-fixture correction changed the host to `b176f4f3`:
only the ownership/connection missing demos force a wrong pedal type; the target
missing demo now contains just its intended missing control. Independent VGV,
Architecture and Test Quality review verified that exact delta and all five
target plus three earlier review routes in Chrome and Firefox. Their reports
bind the final hash and distinguish fixture smoke from earlier full journeys.

## Findings resolved

- The initial range summary could hide later assignments without a foot or
  encoder path. Three-source pages now expose every assignment, with stable
  Previous/Next actions and stale-contact invalidation across pages.
- Destination rendering rebuilt the full descriptor catalogue twice. It now
  groups the already-read choices; command-time validation stays fresh.
- Control picker details wrapped out of their buttons. Scoped, content-sized
  rows and full-width details fix this; browser geometry assertions cover it.
- An older ownership test expected a raw effect ID in user-facing text. It now
  checks the readable saved label, exact issue kind/key and visible Replace.
  Its complete Chrome/Firefox rerun passes.
- The target entry fixture inherited an unrelated wrong-pedal-type error from
  a broad missing-scene suffix check. The narrowed condition preserves earlier
  connection examples and leaves target repair independently testable.

## Verification

- New model: 21/21 tests; 100% line/function and 92.77% branch coverage.
- Combined target, connection, ownership, media and recovery models: 93/93.
- Target browser: Chrome and Firefox, normal storage-enabled URL; exact incoming
  targets, typed and reversed endpoints, five-source pagination, collisions,
  touch/encoder/foot journeys, stale contacts, Cancel/Reset, actual writer failure,
  retry/reload and composed media/controller/target repair.
- Existing connection, ownership and media-recovery browser suites: both browsers
  pass independently. The coordinator also reran pedal closure: both pass.
- Source syntax and scoped whitespace checks pass. No Dart, engine, firmware,
  dependencies or generated bindings changed in this slice.

## Saved references

Pen section 41 groups the five 1920 × 1080 states. The browser gallery uses the
same prepared scenes; separate browser-test captures show the longer paged
assignment example. Every Pen reference is editable. Native save, geometry and
link verification evidence is recorded in the gallery manifest.

## Remaining work

Serialized missing control references can be reassigned to existing incoming
controls. Missing native plugins are not installed or reconstructed. Unknown
parameter scales remain Source values, with an explicit unverified-scale note.
Real audio recovery, physical discovery, media validation and durable appliance
storage are still separate. LX-181 remains partially open. The user has not
accepted this new design merely by authorizing implementation, and downstream
processing/tail and capture choices remain open.

## Final Pen and gallery evidence

Native checks cover 511 text positions, 964 element rectangles and five focus
outlines, with no mismatches. All 41 current flow groups are contained and do
not overlap. Clipping is limited to intentional scroll contents: background
Library rows and offscreen destination/control choices. All five native renders
were inspected against the browser scenes. Pen automation briefly timed out
during parent alignment; it recovered, and the subsequent fitting, native
checks, export and explicit Save completed.

The saved file is 94904289 bytes, SHA-256
`b007ef745285d6154340ac19ecca311a3a034726f4d925335d2c66969103b478`. The current Pen gallery now
contains 283 references, with matching HTML/manifest counts. The repair gallery
fits 1440-pixel and 420-pixel viewports.

## Owner-requested summary refinement

After the initial independent review, the owner requested a less crowded final
summary and approved the From/To comparison with an assignment count. Target
repair now returns structured source/destination labels instead of one joined
heading. Endpoint conversion and repair semantics are unchanged. The 21 model
tests and complete Chrome/Firefox target-repair journeys pass on this refinement.
The ready Pen frame was updated, fitted, visually inspected and saved; its current
file hash is 2000987e8a13dc5ab7b92c4cd709b3caf912c242181e0aed55e31c265529de5d. This small
presentation refinement is coordinator-verified; the five independent reports
above remain evidence for the earlier implementation revision.
