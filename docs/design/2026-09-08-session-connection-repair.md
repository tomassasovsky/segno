# Repair session connections

September 8, 2026. A local prototype proposal under issue 919. The owner asked
to continue after the shared-behavior review; processing and downstream-tail
choices remain open. This flow does not accept those policies by implication.

[Try the four review states](session-connection-previews/index.html).

## User journey

Open a saved session from Library. If a required pedal or MIDI controller is
unavailable, choose **Replace**, select a compatible current connection, then
review the affected assignments. **Apply and open** publishes the repair and
opens that session. **Cancel** keeps both the current and archived sessions.
Choosing a replacement alone changes only the pending copy.

The example moves an expression assignment from CTRL 1 to the connected,
calibrated CTRL 2. The MIDI example offers a current controller for an absent
keyboard. Disabled choices explain type, calibration, occupation or collision
problems. Nothing is matched merely because its name looks familiar.

## Boundaries

- CTRL replacements require the same configured pedal type and required switch
  hardware. Expression calibration must already be valid. All musical mappings
  on the source port move together, including external rack activation rules.
- An incoming session's occupied port cannot be overwritten, including dormant
  assignments. Current physical types, calibration and aliases are preserved.
- MIDI replacement changes the exact device ID while retaining message,
  channel, ranges, enabled state and target IDs. Exact and Omni collisions are
  refused, including collisions with disabled mappings.
- **Reset choices** discards connection replacements while retaining any media
  repair made earlier in the same request. **Cancel** discards the whole request.
- Apply rechecks current availability and the original archived session. A
  removed device, changed archive or rejected storage write leaves the current
  rig intact. Failed storage keeps the pending repair available for retry.
- Successful publication follows the existing session boundary: playback stops,
  the outgoing session is preserved, incoming music is loaded, and old held
  contacts are retired. Actual device/audio/storage behavior is simulated here.

## Touch, encoder and foot controls

Touch and encoder use the same choices and review. During pedal-triggered recall,
the four track pedals select visible connections or replacements. Bank pages
through more than four choices. Stop goes Back from the picker or applies/retries
from the review; Clear resets staged choices, and Mode cancels to Tracks.

A held contact retains the exact action and request context from its press.
Disconnection, Back/reentry, Cancel/reopen, Reset or paging cannot make its release
select a different connection or act on the underlying track controls.

## Verification and remaining work

The pure model passes 19 tests; combined connection, ownership, media and recovery
regressions pass 72. Normal-storage journeys pass in Chrome and Firefox for
touch, the complete encoder path, foot paging and stale-contact cases, Cancel,
failed write/retry, media plus controller repair, and reload. Existing pedal,
ownership and media-recovery browser journeys also pass.

Four editable screens are saved in Pen section 40. The earlier retry-only guard
is archived. Native text/focus checks and visual comparisons are recorded in the
[review record](../reviews/2026-09-08-session-connection-repair/review.md).

Unavailable effects or parameter targets still need a separate explicit repair
before the session can open. This pass preserves those IDs and keeps them blocked.
Native recording layers, real controller discovery and appliance power-loss
recovery also remain open. This is not whole-audit closure or production approval.

## Follow-on control repair

The [saved-control repair proposal](2026-09-08-session-target-repair.md) now adds
replacement of missing archived effect/parameter target IDs in the same pending
request. It preserves the connection-repair boundary described above. Native
plugin replacement and appliance recovery remain open.
