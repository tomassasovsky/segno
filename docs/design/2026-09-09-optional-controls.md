# Optional controls — executable prototype, 9 September 2026

This pass implements the remaining optional-control UX under the approved
non-production completion plan. Touch lock and double-press Solo start off.
Existing transport, mapping Save/Cancel, source repair, and encoder workflows
remain the integration points. Browser events and storage prove interaction
semantics; physical controllers, MIDI driver timing, real audio and appliance
input delivery still require production/device verification.

## Touch lock

Stage and Displays expose a small Lock touch header action. While locked, screen
pointer, click, wheel, input and change events are blocked. The bottom banner
keeps an explicit Unlock touch action available to the encoder. A stationary
1.5-second hold on that action also unlocks; release before the threshold,
movement beyond 24 pixels, pointer cancellation, leaving the screen or window
blur cancels the hold. The release click is consumed. Pedals, MIDI and encoder
continue to operate. This is accidental-touch protection, with no authentication
claim. Reload starts unlocked.

`createTouchLockStudy({button, render, focus, cancelTouch})` owns transient state.
The host attaches it once to each appliance touch surface, includes `overlay()`
in its render, routes `action(id)`, and includes Unlock in encoder focus even
when a modal is open. `performanceUI.cancelTouch()` retires numeric pointer
contacts only; string-token hardware/MIDI contacts continue. The host also
cancels its screen drag state. `snapshot()` exposes lock/hold state for browser
verification. Secondary-display forwarding must apply the same filter before
forwarding touch; this module does not represent a physical display driver.

## Optional double-press Solo

Pedals → Track controls → a Track pedal adds one Double press field: Off / Solo.
The preference follows the existing draft Save, failed-save retry and Cancel
contract. It applies to Track pedals in Tracks mode only.

A first down selects immediately. A second short press on the same logical
track, starting within 300 ms of the first release, toggles Solo on its release.
Each press must last at most 300 ms. The second down does not issue another
Select, Record or Play. The existing 800 ms Hold wins and cannot also toggle
Solo. Cancellation, intervening controls, mode changes and a changed logical
track retire the candidate. Record / Play keeps its immediate down action.
Solo publication uses the host's existing transactional save, with rollback on
failure. The option is independent of the Custom control assignments.

## Explicit MIDI formats

Learn adds a Message format picker and shows the exact complete received value.
It does not infer a controller's encoding from a single CC byte.

| Format | Prototype contract | Learn example |
| --- | --- | --- |
| CC, Note or Program | Existing 7-bit controls; button press/release and Program triggers | CC 21 = 64 / 127 |
| 14-bit CC | CC 0–31 MSB plus corresponding CC 32–63 LSB; complete fresh pairs | CC 21=64, CC 53=1 → 8193 / 16383 |
| NRPN | CC 99/98 parameter selection, then CC 6/38 complete 14-bit Data Entry | 99=2, 98=3, 6=64, 38=7 → NRPN 259, 8199 / 16383 |
| Bank + Program | CC 0/32 selects bank; the subsequent Program message triggers its exact bank/program identity | 0=2, 32=4, Program 8 → Bank 260 · Program 8 |
| Relative CC | Explicit two's-complement encoding; 1–63 positive, 64–127 negative, 0 no movement | CC 22=127 → −1 step |

MIDI's assigned CC pairs, Data Entry and NRPN numbers follow the
[MIDI Association control-change table](https://midi.org/midi-1-0-control-change-messages).
The bank/program separation follows its
[MIDI message overview](https://midi.org/about-midi-part-3midi-messages).
The 100 ms pair freshness window and required fresh pair per update are explicit
prototype receiver choices. Controllers that send only a changed byte or omit
one bank byte are outside this implemented subset. These choices need physical
controller validation before production. Pair assembly is separate for each
device, channel, protocol and controller; disconnect, Learn and control reset
discard partial data. RPN selection and NRPN null selection cancel NRPN state.
NRPN Data Increment/Decrement is not mapped. There is no reserved CC command
scheme: all actions require an explicit saved assignment.

High-resolution absolute controls use normalized saved ranges and pickup.
Relative controls move from the current value by the destination's encoder
step, clamp within their saved range, honor reversed ranges and apply the
existing target coercion. High-resolution/relative formats accept parameter
controls. Actions require an explicit button or Program format. Program
parameter controls retain their unused low endpoint and apply the high Value.
Cancel does not save the learned source; failed Save keeps the complete draft.

Source identity includes protocol and, where applicable, NRPN parameter or
bank. Overlapping raw CC footprints in different protocols cannot be assigned
on overlapping channels. Distinct NRPN parameters and banked Programs remain
independent. Controller replacement and missing-target repair use the same
identity helpers and preserve these fields. No repair generates new source IDs.

The pure `SegnoMidiProtocol` browser/CommonJS module exports `decoder`,
`validSource`, `same`, `overlaps`, `name`, `protocol` and `protocols`. Load it
before MIDI controls and both session repair modules. The decoder accepts the
existing simulated `{kind, number, value, channel}` wire shape. It returns a
complete `{source, value, maximum, delta?}` event or `null`; it never dispatches
an action or writes storage.

Song Position Pointer belongs to MIDI Sync, not assignable Learn. The timing
slice accepts `{kind:'song-position', value}` where value is 0–16383 MIDI
sixteenth notes and converts to quarter-note beats with `value / 4`. Its stopped
transport guard, Continue anchor and Start reset are owned and verified by the
timing module. RPN mappings, other relative encodings, SysEx controls, pressure,
pitch-bend mapping, MIDI 2.0/UMP and physical timing guarantees remain explicit
production/extended-controller scope; no UI claims support for them.

## Explicit Cut all sound

Loop transport includes the assignable `command:cut-sound`, operation
`cut-sound`. Mapping dispatch calls the host's `cutSound` callback once per
button press or matching Program event. The host immediately stops audible recorded tracks and backing and advances its
transient tail-reset revision. Cut does not depend on writable storage: a failed
publication freezes captured material for recovery while audible players and
queued actions stop. Existing monitor preferences remain; new live-input sound
can resume. Ordinary Stop,
Clear and Mute do not call this tail reset. The action is available to built-in
Custom controls, external switches and explicit MIDI mappings through the
shared catalogue. No browser test proves DSP tail rendering.

## Review and video sequence

Use the normal prototype URL with `?canvas=actual` at 1920×1080; the harness
outside the appliance supplies simulated physical and MIDI events.

1. Stage: choose Lock touch, try Settings (blocked), press physical Track 2
   (selection changes), then encoder to Unlock touch and press. Lock again and
   hold the visible Unlock touch action for 1.5 seconds.
2. Settings → Pedals → Track 1: show Double press Off, choose Solo, Save. Return
   Stage, press Track 2 twice briefly. Show Solo then a second double press to
   release it. A long second press follows Hold only.
3. Settings → MIDI controls → Add mapping → Message format → 14-bit CC. Send
   CC 21=64 then CC 53=1 on USB channel 1. Show Received 8193 / 16383, add Track
   1 Volume, then Save. Repeat with NRPN 259 to show complete parameter/value.
4. Learn Bank + Program, send CC 0=2 and CC 32=4 followed by Program 8. Add
   Performance actions → Loop transport → Cut all sound. Show that bank CCs
   alone do not trigger the action.
5. Learn Relative CC, send CC 22=127. Show −1 step, choose Track 1 Volume and
   Save. Reload to prove source identity/ranges remain saved.

`verify_optional_controls.cjs` covers decoder boundaries and source identity,
real mapping Learn/Save/failure paths, shared repair preservation, gesture
arbitration, touch filtering and explicit Cut dispatch. The browser suite
`verify_optional_controls_browser.cjs` exercises normal storage, actual screen
input, physical/encoder paths and the same Learn sequences in Chrome and
Firefox. Its `OPTIONAL_CONTROLS_OUTPUT` environment variable keeps independent
review captures in a separate directory. Final browser outcomes are recorded
by the coordinator with the assembled host revision.
