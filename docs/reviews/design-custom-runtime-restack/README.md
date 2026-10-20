# Custom pedal runtime

Custom now runs the saved Press and Hold assignments through the shared action
dispatcher. Mode exits immediately and Bank pages the four track positions.
Fresh Mode defaults to Mute on Press and Custom on Hold; deliberate saved choices
remain intact. Touch and keyboard track selection do not execute a different
physical switch’s assignment.

Base: `cce88c32d03538c61bafeb64d89369b5aef708ac`.
Original proposal parent: `27efe48a9ca3871c85b4e307e3638fd20a49b604`.
The [source binding](source.json) identifies all 46 changed source, design and
test paths before report-only additions.

## Behavior and repairs

- Press-only acts on contact. A Press/Hold pair waits for short release or the
  800 ms Hold threshold; Hold never also runs Press or replays on release.
- Pending selected/banked Holds follow selection until dispatch. Completed
  contacts retain their resolved target; released state feedback follows the
  current selection again. Setup changes, take locks, session replacement and
  disconnect invalidate pending gestures.
- Custom track indicators show the assigned function’s actual state, or its
  active contact for one-shot actions. Assignment presence does not light them.
  All-ten physical activity and user colors follow in PRs #1031 and #1032.
- Grouped Solo joins the app’s existing mix coordinator. Queued GUI edits,
  grouped toggles and individual Solo changes retain order and toggle parity.
- Clear and Restore affect only Custom assignments. Later edits to Track
  controls survive Restore. Failed and uncertain Save warnings fit below the
  header without covering Save, Cancel or Restore.
- Obsolete mode-token compatibility is removed. Only the implemented shared
  actions are exposed; later performance actions are not advertised as working.

## Verification

The final application run passes 2,331 tests with six existing skips and 91.12%
coverage under the CI exclusions. The source stayed unchanged throughout.
Formatting, strict analysis, Bloc lint over 663 files and whitespace pass.
Native, firmware and package evidence is reused only after confirming no source,
root dependency or workflow changes. No unchanged broad tests were repeated.

Six author-generated layout goldens were independently inspected. The running
macOS app verifies assignment Save, Settings exit, Custom selection, Bank B and
return to normal controls. The saved Pen annotation records the implementation
boundary; complete historical design reconciliation remains the final QA task.

One independent reviewer covers the complete source, bug gate and five quality
roles. A separate adversary passes 16 behavioral probes using real engine and
shared coordinator state with independent expectations. Initial test failures
are retained: three obsolete mode-token expectations and one missing mock
session revision were corrected without changing production behavior. Scoped
126 tests and the complete final suite pass afterward.

Physical foot timing, UART electrical behavior and appliance deployment remain
hardware checks. Remote CI and the existing human merge gate are separate.
