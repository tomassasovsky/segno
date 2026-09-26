# Whole-track Pre processing

Status: product direction accepted by the owner on 2026-09-10. Rendering architecture and production implementation are not completed or approved as a detailed technical plan by this record.

## What We're Building

A whole track retains its Pre/Post switch. Pre prepares a playable, processed copy of the track's combined recorded material while preserving the separate original parts, overdub layers and recoverable edits. Post processes playback live and can finish its tails after Stop. Preparing or replacing the copy is internal work, not a new Bounce journey.

The owner approved this direction after the example of a track containing guitar and vocals: a whole-track delay in Pre belongs to the playable loop and stops with it; the same delay in Post can ring after Stop. Original recordings remain editable and Segno rebuilds the derived copy when needed.

## Why This Approach

The [implementation question](https://github.com/tomassasovsky/segno/issues/1016#issuecomment-5614857125) identifies that the current whole-track stage receives a live sum rather than owning a dry recording. That is an implementation gap, not a decision to remove the previously accepted whole-track switch.

- Per-part fan-out was considered and rejected for this feature. Processing each part separately is not generally equivalent to processing their sum, especially for nonlinear effects. It also changes the meaning of a whole-track instance.
- Flattening the track through Bounce was considered and rejected as the behavior of this switch. Bounce remains its own accepted operation; changing placement preserves editable sources.
- Retaining sources and deriving a processed playback copy was accepted. It requires a track-level render model and explicit handling of live changes.

[Ableton's Track Freeze](https://www.ableton.com/en/live-manual/12/computer-audio-resources-and-strategies/#track-freeze) provides a reference for replacing realtime processing with derived audio while retaining an editable original state. It is an analogy only: Live does not freeze Group Tracks, and its edit restrictions do not establish Segno's overdub or live-control behavior.

## Key Decisions

- Whole-track Pre processes combined recorded material as one signal; it is not shorthand for separate per-part instances.
- Dry sources, parts, layers and recoverable edit state survive. A processed copy does not replace their identity or become the source of repeated wet processing.
- Preparation failure keeps the existing working sound. Successful replacement uses an audio-safe boundary and preserves playback continuity.
- Whole-track Pre stops with the player; Post remains live. Existing part Post and downstream tail promises cannot be silently lost through rendering.
- Placement changes retain effect identity and assignments. The accepted compact editor remains the UX target.
- Outputs and All tracks retain their fixed placement.
- The owner requested a message to the implementation agent. This turn prepares that message locally; it does not post a GitHub comment, send a task message or change production code.

## Open Questions

The implementation plan must establish the exact processing boundary, particularly whether and where individual-part Post processing can coexist with a combined Pre representation. Preserving the original files alone does not prove that the original processing behavior remains available.

The plan must also cover changes during overdubbing, continuous expression/MIDI or pedal changes, source edits and Undo/Redo, stateful effects and tail wrapping, playback transforms, cache invalidation and safe swaps. No restrictions on those accepted features are approved here. An actual conflict requires a concrete product explanation rather than a silently reduced feature.

Meaningful proof includes nonlinear combined-signal processing, rebuilding from sources without repeated wet processing, source/layer recovery, assignment identity, failure retention and correct Pre/Post Stop behavior. Device performance remains separately verifiable.

## Agent Message

[Copyable message](2026-09-10-whole-track-pre-agent-message.txt).

This is a later owner clarification of the whole-track requirement in [the FX design](../design/2026-09-06-fx-ux-design.md) and [the handoff contract](../handoff/segno-app/accepted-behavior.md). It does not claim that the earlier handoff's hash manifest or production verification has been regenerated for subsequent implementation work.
