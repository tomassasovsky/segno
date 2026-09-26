# Physical audio repair and long performance takes

**Owner accepted — September 9, 2026.** The demonstrated layout and behavior
are locked in, including the revised connection summary where applicable.
See the [acceptance record](2026-09-09-recovery-expansion-delivery.md).
Native audio and hardware verification remain separate.

September 8, 2026. Local design prototype under issue 919 and the approved
[recovery expansion plan](../plan/2026-09-08-recovery-expansion-plan.md).
The interface inventory and recording allocation are simulated. This work does
not enumerate real hardware, record PCM bytes, or establish native recorder limits.

## Physical connections

A saved logical input or output retains an explicit interface identity and one
or two ordered physical jack identities in `audioRouting.portBindings`:

```js
{id: 'input:Guitar', direction: 'input', logicalIds: ['Guitar'],
 interfaceId: 'stage', portIds: ['stage:input:1'], label: 'Acoustic guitar'}
```

Input stereo rows have two logical members and two physical jacks. Output buses
retain one logical bus identity and one or two jacks. Pairing or splitting input
rows preserves their exact member jacks. Pairing requires the current inventory
to declare the same ordered left/right stereo group; adjacent channel numbers
alone do not establish a pair.

The existing pending Library opening owns repair. Replace lists the current
interface's compatible jacks and the recording/monitor/output routes affected.
Choices change only its candidate snapshot. Apply and open rechecks availability,
refuses occupied jacks, and publishes through the existing session transaction.
Cancel and a failed writer keep the running session unchanged. A disconnect
invalidates Apply and held foot choices. Missing or malformed manifests stay
explicitly unverified; incoming sessions never receive inferred jack assignments.

`SegnoSessionAudioPortRepair` provides `inspect`, `options`, `repair`, and `regroup`.
The regroup adapter accepts `(snapshot, inventory, stereoPairs, inputIds)` and
returns `{snapshot}` or `{error}`. Only the fresh known simulated fixture uses
`fixtureBindings({interfaceId, inputs, outputs})`, whose associations are supplied
explicitly by the host. `fixtureInventory(audioDeviceUI.snapshot())` exposes the
known simulated Stage, Spare and Compact interfaces, including exact jack IDs
and declared stereo groups. It is not a native discovery API.

Review URLs: `audio-ports-missing`, `audio-ports-choose`, `audio-ports-ready`.
Screenshots are in [audio-port-previews](audio-port-previews/).

## Long takes and capacity

Main-output recording remains one continuous take, independent of loop Stop,
Undo and Clear. Its sample rate, channel count and bit depth are frozen at Start.
The prototype proposes stereo, 24-bit PCM, the applied interface rate, 2 GB file
parts, a 1 GB storage reserve, and a warning at 60 seconds remaining. These are
review choices, not measured Looper X or native engine limits. Exact format and
file size limits still need the production recorder's contract and device proof.

`performance-recording-model.js` computes whole-frame allocation, including a
44-byte header per simulated part. It records ordered part IDs, frame counts,
byte counts and durations. The same remaining-time calculation accounts for an
open part, subsequent headers, current free capacity and the reserve. Unknown
capacity disables Start. Reaching reserve stops at the last complete frame and
keeps the recorded portion available for Save recovered audio.

The study checkpoints through `ctx.write(state, file, {bytesUsed, bytesReleased})`.
The host commits metadata and capacity before adopting live state. Failed writes
keep only the last durable checkpoint, never elapsed time that was not saved.
Successful finalization publishes one catalogue item with every part; it does
not charge those bytes again. Confirmed Discard releases the durable take's
allocation only after publication succeeds. Cancel and failed Discard retain it.
The host persists its simulated free capacity across reload, including active
checkpoint allocation; the five-second checkpoint interval is a prototype choice.

The recorder context also supplies `capacity()`, `recordingFormat()`, `audioReady()`
and `beforeStart()`. The latter cancels a temporary preset audition before capture.
Global recorder state, catalogue entries and numbering survive session changes.
Existing active-capture recovery behavior remains separate from this recorder.

## One take in the Audio library

`performance.takeId` identifies the original parts independently of a catalogue
copy's ID. Export preserves this identity even when the USB entry gets a new ID.
Preview and prepared playback resolve the current position through the ordered
manifest; seek across a boundary selects the next part and its frame offset.
Export consumes the same reviewed sequence. Missing, unreadable or reordered
parts disable use and cannot resume playback. Final export checks the current
source again; import keeps the stable take identity with the copied parts.
These are symbolic playback and transfer plans, not proof of actual audio I/O.

Review URLs: `performance-recording-long`, `performance-recording-low`, and
`performance-recording-unknown`. The long scene is an eight-hour take. The low
scene has two seconds of usable capacity above reserve. The unknown scene has no
usable capacity reading. Normal-host screenshots are in
[long-recording-previews](long-recording-previews/).

## Focused verification

Run the model and study state tests:

```sh
node --test docs/design/verify_session_audio_port_repair.cjs docs/design/verify_performance_recording_model.cjs
```
Browser scripts use Playwright, `ATLAS_CHROME`, and the prototype server at
`http://127.0.0.1:8768/fx-ux-prototype.html`:

- `verify_session_audio_port_repair_browser.cjs`: pending Library Cancel/Apply,
  writer failure/retry/reload, exact identities, stereo outputs, disconnect and
  held-contact races, missing manifests and three layouts.
- `verify_long_performance_recording_browser.cjs`: multi-part allocation,
  preview and prepared seek, ordered export/import, damaged sequence refusal,
  low/unknown capacity, discard accounting, quota recovery and reload accounting.
- `verify_performance_recording.cjs`: existing encoder/foot recording lifecycle,
  continuing loops/backing, session guard, failure/recovery and six layouts.
- `verify_audio_export.cjs`: existing USB export, collision choices, disconnect,
  cancellation, quota failure, encoder and reload behavior.

These are local author checks. Native disk-full handling, real file-part playback,
crash recovery, USB identity discovery and appliance validation remain outstanding.
