# Session recall ownership proposal

This local, silent prototype implements the field split proposed in
[shared behavior contract 8](2026-09-08-shared-behavior-proposal.md). It preserves
the accepted musical boundaries in [Session Library](2026-09-07-session-library-ux.md#state-boundaries)
and [Input setup](2026-09-07-audio-routing-ux.md#input-setup). The physical split
and connection guard remain review proposals. No production engine, hardware,
native design file, issue closure or merge is claimed by this pass.

## Try the two examples

Open the prototype with `?review=session-ownership&canvas=actual`. The saved
**Earlier session** has 96 BPM, a blue first pedal assigned to Peel, and an
expression assignment for Guitar volume. The current setup has 120 BPM, an
amber first pedal assigned to Stop, a newer expression calibration, and the
input name **Stage vocal**. Open the saved session: the earlier music and pedal
assignment return; the current calibration and input name remain. Navigate to
the existing pedal and expression settings to inspect those values.

Open `?review=session-ownership-missing&canvas=actual` for the same saved music
with CTRL 1 currently configured as a dual switch. Opening waits in **Check
Earlier session connections**. Cancel preserves both sessions. Retry checks the
current physical setup again; it cannot replace the dual-switch setup with the
saved expression requirement. These review fixtures do not write browser storage.

Browser captures: [recall preview](session-field-ownership-previews/chrome-session-ownership.png),
[incompatible control](session-field-ownership-previews/chrome-session-ownership-missing.png).

## Proposed ownership

| Recalls with the session | Remains current on the appliance |
| --- | --- |
| Tracks, labels, layers, edit history, loop mode/tempo/signature/record timing, speed/pitch/reverse/fade/bypass, monitoring and recording inputs | Audio interface identity, format, measured latency and current capabilities |
| FX racks and parameters, routing, levels/pan, mute/solo, input pairing and trim | Input/output aliases and tuner reference |
| Built-in pedal actions, colors, palettes and hold assignments; saved pedal ON/OFF state | Physical held contacts, controller connections and ongoing gestures are never recalled |
| Expression mappings and ranges; external-switch actions and parameter mappings | CTRL port type, switch hardware and current calibration |
| Exact musical MIDI device/source/target assignments | Global MIDI-control enable, external clock source/send/Thru configuration |
| Prepared/backing/imported audio references and backing behavior | Current audio and preset catalogues, USB listings, catalogue IDs and performance recordings |

MIDI-control enable is already presented as a global switch. Keeping the entire
clock connection configuration current is a specific proposal in this split;
the session still recalls its internal musical tempo and timing preferences.
Unknown current appliance fields survive because projection starts from current
state and replaces an explicit musical allowlist. No old-snapshot migration or
name-based compatibility path is added.

## Dependencies and publication

`session-field-ownership.js` contains pure `capture` and `project` functions.
The saved `sessionRequirements.controlPorts` describes the original CTRL type
and required switch hardware. These requirements do not configure the device.
The projection retains every original musical target ID and reports missing
connections, incompatible types, insufficient current calibration, unavailable
MIDI devices, unresolved parameter IDs and media issues.

The host resolves parameter descriptors against the incoming session, including
FX identities that exist only in that session. It does not invent IDs to repair
a missing target. Existing media recovery handles audio replacement; a completed
audio repair can still wait for required controls. The subsequent
[session connection-repair proposal](2026-09-08-session-connection-repair.md)
adds compatible CTRL/MIDI replacement, affected-assignment review, Apply, Reset
and Cancel. An unresolved parameter remains blocked and needs a separate explicit
repair; there is no archived-session parameter editor or matching-label remap.

Library checks requirements before recall and the host checks them again at the
final saved-session transition. Retry also rejects a saved entry changed or
removed since the dialog opened. Cancel, Back, Library, reveal and unrelated
navigation retire the pending request. New Loop and metadata saves remain
available when controls were already missing from the current setup.
For pedal-triggered recall, STOP retries/applies and MODE cancels back to Stage.
The repair picker uses the four track pedals for choices, BANK for more, and
STOP for Back. A pending request retains that pedal ownership, so it cannot
become a track action.

Capture freezes fades and writes released MIDI/external held-parameter values
into the outgoing musical snapshot. The host constructs one candidate rig and
Library, writes storage, then releases contacts and replaces live state. Failed
storage leaves both sessions, current physical setup and held state unchanged.
Successful recall stops playback/capture and cancels old gestures. An external
contact that remains physically down is suppressed until release.

## Verification

`node --test docs/design/verify_session_field_ownership.cjs
docs/design/media-parity-study.test.cjs docs/design/session-recovery-model.test.cjs
docs/design/session-recovery-study.test.cjs` passes **53 tests**, including 16
ownership and pending-lifecycle cases.

`node docs/design/verify_session_field_ownership_browser.cjs` passes in Chrome
and Firefox with Playwright available. Its functional journeys use the normal
storage-enabled URL: musical/current-physical contrasts, exact candidate FX
targets, unavailable CTRL/MIDI, media repair followed by control checks, real
storage-writer failure/retry, reload, held release, and offline New Loop/save.
Both browsers also verify blocked STOP retry, unchanged MODE return and
reconnected STOP success. The existing `verify_session_recovery.cjs` journey
passes in both browsers after this integration; its images were redirected to
a temporary directory to preserve the earlier review exports.
Review URLs are used only for the two image exports and bounds checks. The
default local host is `http://127.0.0.1:8768/fx-ux-prototype.html`; override with
`FX_PROTOTYPE_URL` when needed.

Browser devices, connection inventories and audio are simulated. This proves
prototype state and UI behavior, not physical controller detection, audio
rendering, native timing, crash-safe appliance storage or backup restoration.
