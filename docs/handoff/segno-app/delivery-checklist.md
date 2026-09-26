# Design handoff delivery

September 9, 2026. Design/prototype handoff under issue 919; production implementation has not been started by this handoff task.

## Delivered

- The [entry prompt](IMPLEMENTATION_PROMPT.md) is tailored to the owner-confirmed Claude Fable 5.1 using [official guidance](prompting-basis.md). It links the full context progressively and starts with a concrete working app slice.
- [Accepted behavior](accepted-behavior.md) consolidates the decisions across displays, transport/history, FX/routing, pedals/MIDI, instruments, Library/recovery and appliance settings. Earlier alternatives do not reopen those decisions.
- [Implementation map](implementation-map.md) identifies existing Flutter/native infrastructure, seven dependent implementation slices and required evidence. It also corrects the stale FFI-header location in project instructions.
- [Reference gates](reference-gates.md) distinguishes exact catalogue identities and preset values from missing parameter domains, reset defaults and rack-order evidence. The independent-sound permission is preserved.
- The 19 completion Pen screens have corrected text alignment. Track, Wave, Mixer and the selected-track display were refreshed from current browser geometry, including the crown and whole-track meter. The eight accepted instrument screens remain intact. Archive/design-system sections no longer overlap Current UX; superseded processing alternatives are in the archive.
- The clock-loss recovery cue now wraps inside its track instead of clipping. Its ownership and recovery behavior are unchanged.

## Observed checks

| Evidence | What it establishes |
| --- | --- |
| Completion walkthrough dry run | All seven existing interaction chapters pass in Chrome against the current prototype. The timing chapter was rerun after the visual repair. |
| `verify_handoff_display.cjs` | Chrome and Firefox: crown remains attached when selection changes, four whole-track meter surfaces exist, recovery text fits, and the second display follows selected-track crown state. |
| Native Pen geometry and screenshots | The 19 completion frames, four display frames and eight accepted instrument frames have checked text bounds. Representative screens were visually compared with browser output. Intentional overflow for LED positioning and meter-scale labels is distinct from text clipping. |
| [Pen save evidence](pen-verification.json) | Native File → Save, on-disk hash/size, checked frame identities and nonoverlapping root sections. A saved file alone is not the visual check. |
| [Review record](../../reviews/design-handoff/review.md) | Independent review scopes, findings and corrections. No production CI or appliance proof is implied. |
| [Transfer manifest](transfer-manifest.json) | Design/context allowlist and exact hashes, including untracked prototype assets. Run the [verifier](verify_handoff.py) in the receiving checkout. |

Existing completion, instrument and recovery browser/model reviews remain linked from their design records. This pass does not replace their historical evidence or relabel an old video as a new recording. The original completion video predates the crown and latest message wrapping; the live prototype and refreshed Pen frames contain those refinements.

## What remains

Exact reference parity is **not closed**: 239 rack control domains, all 300 factory reset defaults, 26 Single FX schemas, and verified rack composition/processing order require stronger source evidence. Preset inventories and partial ARM constructor traces cannot establish them. A complete authorized runtime/schema capture or equivalent builder/translator trace can close the rows. Further tracing is a distinct research task; this delivery does not claim every possible reverse-engineering route has been exhausted.

Segno may use independent sounds. A finished bundled sound/sample collection, native instrument hosting, real audio and media integration, controller/device behavior, sustained performance and power-loss recovery belong to implementation/content delivery and hardware validation. USB gadget-audio feasibility, output/Phones policy and other hardware-dependent boundaries remain explicit in the accepted contract.

The next agent can start the existing-app Tracks/two-display slice immediately. No new design approval is needed for the accepted instrument UX or settled completion flows. Unverified effect definitions must not be invented to make an audit table appear complete.

This is a ready implementation brief, not a claim that every product audit row or production capability is finished. No new task was launched and no repository work was committed, pushed, merged or deployed.
