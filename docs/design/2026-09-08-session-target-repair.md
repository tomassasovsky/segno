# Repair saved control targets

September 8, 2026. Local prototype proposal under issue 919. The owner asked to
continue with unavailable effect/parameter assignments. This does not settle the
open downstream-tail, capture-tap or session field-ownership choices.

[Try the repair flow](session-target-previews/index.html).

## Journey

Open a saved session from Library. A missing control shows its saved name and
location. Choose **Replace**, choose an input, track or output in that session,
then choose an available knob. Review the resulting values for every expression,
external-button and MIDI assignment that used the missing control.

**Use control** stages the replacement. **Apply and open** publishes the complete
pending session. **Cancel** preserves the current session and the original saved
session. **Reset choices** removes staged control/connection changes, retaining
any media repair made earlier in the same request.

Long assignment reviews show three sources per page. Previous and Next work with
touch, encoder and the first two track pedals. In foot recall, the four track
pedals choose visible destinations/controls, Bank pages through them, Stop goes
Back or stages the reviewed control, and Mode cancels. Existing Apply, reset and
return-to-Tracks behavior is shared with connection repair.

## Values and identities

- The picker uses the incoming session's controls and saved track labels. It
  cannot borrow a similarly named effect from the current session.
- Repair changes the exact missing target key everywhere it is referenced.
  Source identities, channels, pedal conditions and other mapping settings stay.
- Existing normalized range positions pass through the replacement control's
  coercion and formatting. A switch, for example, shows explicit Off/On values.
  Reversed ranges remain reversed. Unknown scales remain labeled as source
  values rather than being presented as verified musical units.
- Expression shows Heel/Toe; toggle shows Off/On; momentary shows Released/Held;
  continuous MIDI shows From/To. A Program mapping shows only its used Value.
- Duplicate assignments within one source and occupied replacement targets are
  refused. Different pedals/controllers may legitimately share a target.
- A target that disappears, becomes ambiguous or becomes invalid cannot be
  applied. The archived session and current connections are checked again at
  publication. Failed storage keeps the draft available for retry.
- A release from an earlier foot gesture cannot act after a page change, Back
  and reentry, another choice, Reset or cancellation.

## Scope and verification

The new pure model passes 21 focused tests; combined target, connection,
ownership and media/recovery model regressions pass 93. Normal-storage browser
journeys pass Chrome and Firefox, including typed endpoint conversion, long
reviews, complete encoder/foot paths, stale releases, cancellation, writer failure,
retry/reload, and media plus controller plus target repair in one pending session.

The five review states are grouped in Pen section 41. Native render and alignment
checks, independent review reports and saved-file evidence are recorded in the
[review record](../reviews/2026-09-08-session-target-repair/review.md).

This repairs **assignments to a missing control**. It does not install a missing
plugin, reconstruct a removed processor, recover missing recorded audio, or
validate real plugin availability. The prototype remains silent. Native audio,
physical-device discovery, content verification and durable power-loss recovery
remain production/appliance work. LX-181 remains partially open.

## Approved summary refinement

The owner approved the lighter final Review changes layout: From and To show
the old and replacement control, with the count of updated assignments below.
It does not repeat endpoint values already reviewed before Use control. The
short playback notice and Apply/Cancel behavior remain. This refinement is saved
in the prototype and Pen, and the 21 focused tests and Chrome/Firefox repair
journeys pass again.
