# Complete appliance backup and restore proposal

**Owner accepted — September 9, 2026.** The demonstrated layout and behavior
are locked in, including the revised connection summary where applicable.
See the [acceptance record](2026-09-09-recovery-expansion-delivery.md).
Native audio and hardware verification remain separate.

September 8, 2026. The owner approved building this local Library/Storage
proposal. Its packages contain prototype state and declared audio descriptors;
they are not filesystem archives and contain no PCM audio bytes.

Back up to USB first reviews Sessions, Loop recordings, Backing audio, Presets
and Settings. An existing name requires Keep both or Replace. Review restore
shows those groups again and explicitly replaces the current appliance data.
The final action is **Restore and restart**, because hardware/global settings
need a new initialization. Cancel writes nothing; failed publication retains
the review for an explicit retry.

## Host boundary

`SegnoApplianceBackupModel` exposes `validate`, `summary`, `pack`, `inspect` and
`restore` through the browser global and CommonJS. Its explicit payload is:

```js
{
  sessions: {current: fullSessionEntry, sessions: [], nextId, folders: []},
  audio: {files: [], recordedFiles: []},
  presets: { /* complete host-provided preset collections */ },
  settings: { /* complete host-provided settings groups */ }
}
```

The preset and settings objects preserve current host ownership. They do not
decide a new accepted global/session schema. Preset totals count entries in
their top-level collections; settings totals count the supplied groups.

All active/archived session references and known recorded Undo/Redo dependencies
must resolve. Recorded tracks with neither materialized layers nor a verified
import are rejected. Missing/damaged inventory entries, conflicting IDs,
changed recorded content, missing payload sections and incomplete package
counts block backup or restore. Packages also carry an explicit simulated
damage flag. Structural validation and those counts are not a cryptographic
integrity check.

Declared multipart performances must pass `SegnoPerformanceRecording.manifest`:
ordered parts, complete frame/byte totals, readable parts and the declared WAV
format. This applies even to audio no session currently uses. Backing/import
references must still identify the same original performance. Recovery updates
imported layer and Undo/Redo source references together before backup validation.

`createApplianceBackupStudy(ctx)` renders body/overlay and exposes action,
back/leave, pending, mediaChanged, initialFocus and snapshot. Its action prefix
is `appliance-backup:`. The required application callbacks are:

- `capture()` returns the complete settled payload, including the current
  session as a full snapshot; do not introduce changing preview timestamps.
- `archives()` reads the simulated USB collection. `writeArchives(next,
  expected)` publishes a new collection only after comparing the expected one.
- `commitRestore(nextPayload, expectedCurrentPayload)` performs the complete
  host transaction and returns `true` only after all stores are committed.
  `false` means no change; a string can expose a distinct transaction failure.
- `completed()` restarts/reinitializes the prototype after successful restore.
- `blocker()` returns the applicable USB/device/capture/other-transfer/pending
  preview reason. It must exclude this study's own review state.
- `button`, `escape`, `render`, `focus` and `open` provide the existing host UI.

There is no simulated transfer timer: review, validation and publication are
explicit. The host supplies a single transaction boundary. When existing
settings occupy several storage keys, rollback must include every earlier
write, and rollback failure must not be reported as unchanged data. A browser
multi-key transaction does not prove native crash-safe or power-loss durability.

## Verification

```sh
node --test docs/design/verify_appliance_backup.cjs
node --test docs/design/verify_appliance_storage_transaction.cjs
node docs/design/verify_appliance_backup_browser.cjs
```

Focused cases cover complete payload preservation, active/history audio,
unreadable sections, ambiguous IDs, conflict choices, immutable Cancel,
changed sources/packages, disconnected media, capture/preview guards, failed
publication and restart only after success. The browser suite checks a normal
storage URL: creation, conflicts, Cancel, source changes, USB loss, middle-key
failure and rollback, then encoder retry, restart and exact restored payload
across all existing settings stores. It preserves the last performance metadata
and leaves the USB archives untouched by restore. Set `SKIP_SCREENSHOTS=1` to
keep assertions without recapturing images; `APPLIANCE_BACKUP_OUTPUT` selects
the capture directory. Chrome and Firefox pass these journeys.
