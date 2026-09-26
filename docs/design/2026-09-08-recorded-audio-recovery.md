# Recorded-loop audio recovery proposal

**Owner accepted — September 9, 2026.** The demonstrated layout and behavior
are locked in, including the revised connection summary where applicable.
See the [acceptance record](2026-09-09-recovery-expansion-delivery.md).
Native audio and hardware verification remain separate.

September 8, 2026. This local prototype extends Library's existing pending media
repair to missing, damaged or changed recorded takes. The owner approved building
the proposal. It does not read, hash, copy or decode native audio bytes.

Choose an intact original or backup copy, then Open session. A different recording
with the same filename or length is not a substitute. Cancel leaves the current
session and archive unchanged. Failed publication retains the draft for retry.

## Explicit recorded assets

Each materialized recorded layer has `recordedAudio` containing `id`, `name`,
`sourceId`, `integrity`, `seconds` and `format: 'WAV'`. The inventory adds a location
(`internal` or `usb-backup`) and optional `damaged`/`unreadable` flags. Integrity is
declared simulated evidence; the generated `symbolic:` value is not a checksum of
an audio file. A native implementation must supply independently verified byte
identity and duration.

`SegnoRecordedAudio.materializeRecorded(snapshot, inventory, sessionId)` returns
an isolated `{snapshot, files}`. It identifies new symbolic layers once, scoped
by session, track and stable layer ID. The host invokes it before persisting a
new take, while its captured duration and tempo are still known. It never
regenerates a missing asset for an already identified layer. Imported layers
retain their existing source-file contract.

The traversal includes active and removed layers and the `before`/`after` audio
snapshots in both Undo and Redo history. Repeated copies of the same take share
one asset reference; a history-only asset is still required to open the session.
No blanket claim is made about unknown history formats or symbolic PCM.

## Recovery and publication

Load `performance-recording-model.js` and `recorded-audio-model.js` before
`session-recovery-model.js`. The existing
`SegnoSessionRecovery.valid/inspect/candidates/repair` interface remains the
single entry for ordinary backing/import references and recorded-take recovery.
The host passes the combined ordinary and recorded inventory, including backup
copies only while their USB source is available.

Ordinary backing/import repair excludes recorded-original recovery assets from
its choices. It validates declared multipart performances using their existing
ordered-parts contract and detects a changed underlying original. Imported layer
source IDs and the full import descriptors in Undo/Redo are repaired together.
History-only imports retain their original duration and format requirements; an
orphan source ID without its original descriptor cannot silently adopt new audio.

Recorded candidates must match every reference's exact `sourceId`, `integrity`,
`seconds` and `format`. Duplicate inventory IDs are ambiguous and refused. The
repair updates asset references throughout the pending snapshot. It never edits
layer gain, captured beats, sparse regions, track length, mode or edit chronology.
A four-beat take can therefore retain its two seconds of recorded content within
a sixteen-beat Multi loop, including its original wrapped region and silence.

At final Open, the existing recovery study rechecks the selected descriptor,
current media, interface readiness and saved-source equality. The host calls
`SegnoRecordedAudio.internalCopies(snapshot, currentFiles)` only while preparing
the complete commit candidate. That helper returns isolated descriptors with
internal locations; it does not modify the live inventory. The host publishes
the session and those copies together, or keeps the prior state on failure.

## Verification

```sh
node --test docs/design/verify_recorded_audio_recovery.cjs
node docs/design/verify_recorded_audio_recovery_browser.cjs
```

The focused model/UI cases cover exact identity, declared damage, changed
duration, same-name refusal, history dependencies, immutable Cancel, stale media,
device loss, imported-history repair and failed-save retry. The browser suite uses a normal storage URL
and checks byte-for-byte persisted state before Cancel/failure, guarded internal
copy publication, encoder access and Multi timing after reload. Set
`SKIP_SCREENSHOTS=1` to retain assertions without rewriting preview images;
`RECORDED_AUDIO_OUTPUT` selects a separate capture directory.

Physical filesystem recovery, actual WAV integrity, driver behavior and durable
power-loss guarantees remain separate implementation and appliance gates.
