# Library, import and backing correction

September 8, 2026. This records the media correction to the shared UX study. It changes the browser prototype and its production requirements; it does not establish a decoder, time stretcher, durable session store or appliance playback implementation. The dated [recheck ledger](../research/segno-looper-x-comparison/2026-09-08-recheck/features.tsv) remains the before-state.

## Reference and accepted direction

The supplied *Sheeran Looper X User Guide v1.0.0*, page 14, defines an empty Track/Wave import entry, file browsing and search, explicit preview, three timing policies, and optional bar-count confirmation. Its labels name the thing that changes: **Loop BPM** changes the loop tempo to the file; **Import File BPM** changes the file to the loop tempo; **No BPM Change** leaves both alone. Segno uses the less ambiguous labels **Use file tempo**, **Adapt to loop tempo**, and **Leave unchanged**.

The supplied `AppUI/Dialogs/ImportAudioDialog.qml` bypasses the normal policy chooser while receiving MIDI clock and requests `ImportAudio.AdjustImportFileBPM`. Its `NumberOfBarsDialog.qml` exposes a bar value and explicit preview. These sources establish the workflow, not a beat detector, stretch algorithm, codec matrix or supported stretch ratio. The guide's page 29 establishes Save New Loop, rename, delete, folders and search. Page 31 establishes a separate backing player with clear, level, transport, seek and previous/next file actions. The [reference evidence index](../research/sheeran-looper-x-1.0.2/evidence.md) retains the extracted-source paths.

Keep the accepted Segno differences: eight tracks; current-session preservation; compatible-only musical changes; independent prepared backing order; managed internal copies from USB; Stop/Repeat/Next end behavior; session audition and backup recovery; direct encoder editing; and a fixed bottom keyboard. No prepared recording is removed when the loaded backing player is cleared.

## Implemented study journeys

| Journey | Observable outcome |
|---|---|
| Duplicate selected session | Creates a new identity and independent snapshot, including setup and prepared audio references. The active session keeps its identity. Cancel and failed persistence leave the original state intact. |
| Save current as | Names a new active identity and retains the old current snapshot in Library. Uses the metadata transaction, so this identity change does not reset live playback. |
| Delete selected session | A confirmation names the session; Cancel is the initial action. The active session is protected: open another session before deleting it. Busy capture/transfer and failed persistence preserve the entry. Shared media and USB backups remain. |
| Search and organize sessions | A fixed bottom keyboard searches names, with Clear and an explicit empty result. All, Unfiled and named folders filter the list. New folder rejects duplicate names case-insensitively. Move updates metadata without loading the session. This is one useful folder level, with no speculative hierarchy. |
| Search audio | Searches the selected storage/folder using the fixed keyboard. Search cancellation preserves the existing query, Clear restores the list, and selection tracks the matching result. |
| Import from an empty track | `openForTrack(trackId)` rejects occupied/capturing tracks and carries the destination through browsing, preview, timing and commit. The host's Stage entry calls this API. Cancel returns without altering the track. |
| Choose import timing | Shows all three policies. Source tempo is explicitly file metadata, fixture metadata or derived from the user's confirmed bars. Missing tempo blocks tempo-dependent choices until bars are confirmed; unchanged duration needs no invented BPM. Bar count is editable with touch steps and encoder, including cancel. |
| Follow MIDI clock | Adapt is selected and the other policies are disabled. Missing/lost clock blocks publication. Clock changes during the operation return to the timing step with an error. |
| Publish an import | Rechecks the destination, source descriptor, USB state, storage, and timing. One host transaction publishes the imported descriptor and any allowed loop tempo change. USB input becomes a managed internal asset before publication. Imported audio starts stopped. |
| Backing mix | Level and pan use the same normalized `Backing` targets as Mixer, external controls and MIDI. Touch steps, encoder, unity/center reset and persistence failure are explicit. |
| Clear backing | Confirmation stops and unloads the player. The internal file, prepared membership and order are preserved. Removing a recording from preparation remains a separate Library action. |
| Backing performance controls | Existing prepared selection, play/pause, stop, seek, foot jumps, paging and Stop/Repeat/Next remain. Level/pan use the same commands; direct previous/next load adjacent prepared recordings stopped. |
| Session direct controls | Previous/next traverse stable creation order. Capture/transfer block the transition. Ongoing playback uses the existing preserve-and-stop confirmation; the host projects its confirm/cancel actions for foot use. Save checkpoints the current session without creating a second identity. |
| Session preview | Existing recorded waveform preview and explicit audition are retained. Imported descriptors use their resulting duration; they show waveform unavailable until a real media waveform exists rather than borrowing unrelated PCM. |

## Timing and ownership contract

`timing.sourceSeconds` remains the original file duration. `timing.seconds` describes the proposed imported copy. For Adapt, it is `sourceSeconds × sourceTempo ÷ loopTempo`; that is a deterministic metadata preview, not evidence of processed audio. `sourceBars` preserves source metadata or the user-confirmed count. `bars` describes the resulting duration in the current loop signature. `sourceTempoOrigin` distinguishes `fixture`, `file-metadata` and `user-bar-count`; no measured BPM is claimed. The example *Yesterday's loop* has explicit fixture metadata of 120 BPM, 12 bars and 24 seconds.

Use file tempo can change an empty loop. If existing audio would need a different loop tempo, the study directs the user to Adapt or Unchanged and preserves the recorded material. It can accept an already matching tempo. A new loop tempo stays within the existing study's 30–300 BPM control range; this is not a claim about Looper X's different documented bounds. Bar confirmation uses the displayed loop signature. File metadata remains available for inspection and is never overwritten by a derived count.

| State | Owner |
|---|---|
| Session names, folder membership, folder names and session identities | Library metadata, outside a session's musical snapshot |
| Recorded/imported track descriptors, backing selection/order/end behavior and `expressionMix.Backing` | Session snapshot |
| Imported original file, other shared audio, export references | Managed media library, addressed by stable ID |
| Search/filter, selected row, open keyboard, audition and transport position | Transient study state |
| USB backup archives | Existing backup helper; retained independently of Library deletion |

The import descriptor contains `processing: 'simulated'` and `sourcePreserved: true`. Production must retain the immutable original source and explicit transformation recipe. A descriptor that says Adapt is not a processed audio file.

## Host integration

The coordinator owns the main HTML and Stage files. The assigned study files expose these small hooks:

```js
// createAudioLibraryStudy context
// All mix values use the existing expression target representation.
mixRead: () => rig.expressionMix?.Backing,
mixWrite: (field, value) => persistBackingMix(field, value), // 0..1
returnToTrack: () => returnToStage(),
timing: () => ({
  tempo, signature, mode, hasAudio,
  external, clockStatus, // internal | waiting | synced | lost
}),
commitImport: (nextAudioState, descriptor) => commitAtomically(
  nextAudioState,
  descriptor.target,
  descriptor.timing,
),
```

`openForTrack(i)` returns a boolean. On success, the host opens Audio Library without calling `open()` again, since `open()` intentionally begins an ordinary Library browse and clears a carried destination. The host should route encoder `turn` and `finish(cancel)` to Audio Library while it is active, allowing direct backing mix and bar count editing.

`commitImport` returns false on failure and must restore both audio state and optional tempo. `descriptor.timing.tempoChange` is null unless the file policy would change loop tempo. Symbolic track length uses `timing.seconds × timing.loopTempo ÷ 60` beats. Production must populate one authoritative playable track object and audio-edit history, not parallel imported and recorded models.

`audioUI.performanceCommand(action, value)` accepts `play` (toggle, optional prepared ID), `stop`, `seek` (seconds), `rewind`, `forward`, `previous`, `next`, `clear`, `level` and `pan`. `performanceSnapshot()` includes normalized `mix`. The performance view's existing action/turn/finish wiring already handles its added mix controls. `sessionUI.command('previous' | 'next' | 'save')` provides direct dispatch. Existing `session:confirm-load` and `session:cancel` accept or exit a playback confirmation. A direct foot mapping must reach these controls without requiring touch.

## Verification

`node --test docs/design/media-parity-study.test.cjs` passes 19 tests. They check outcomes through public APIs: duplicate/Save As identity, cancel and write failures; folder/search and move; protected current deletion; direct-session busy/playback gates; target-carrying import; canceled jobs; occupied target and changed clock; file/adapt/unchanged descriptors; unknown tempo and bar confirmation; USB removal, low storage and managed copies; normalized backing mix and failed writes; encoder cancellation; unloaded versus prepared state; audio search; and audition/import-preview behavior.

`media-parity-browser.test.cjs` passes in fresh headless Chrome and Firefox contexts, with no page errors. It exercises Library creation/move/search/delete and persistence after reload; Stage-to-Track-4 import; Adapt with the explicit 120 BPM fixture; stopped imported audio and saved symbolic content; direct shared backing mix in Library and performance mode; encoder cancel; clear versus preparation; foot-only cancel and acceptance of a session change; and canceled/completed USB backup plus independent restore of imported audio. It also exercises a storage-write failure while Use file tempo would change an empty loop: track, import and tempo remain unchanged, then the retry publishes all three together.

The [saved views](media-parity-previews/README.md) include management, the fixed keyboard, a folder, unknown and known import timing, backing mix, backing performance and restored-session preview. These are author-only browser checks and screenshots, not CI or appliance validation. No production Dart/native/firmware code was changed by this slice, and no commit or push was performed.

## Production work and unresolved facts

1. Implement decode, format/channel/rate validation, waveform extraction and audition. File eligibility must come from decoder results. This study uses silent file descriptors and explicitly illustrative audio/backing envelopes; its session-recorded example waveform is separate from imported-file samples.
2. Supply tempo detection confidence and allow correction of the source's musical length/signature. The UI must distinguish file tags, measured estimates, user-confirmed bars and no tempo. Establish practical import/stretch limits from real audio tests; no allowed ratio, perceptual fidelity or CPU budget is inferred from QML.
3. Publish original copy, transformed audio, session manifest, tempo and track/history state atomically. Cancellation, power loss, a full disk and USB removal must leave either a complete old state or a complete new state. Verify fsync/rename and recovery on the appliance.
4. Use one imported/recorded audio object for playback, layer/length transforms, Bounce, Peel, Undo, redo and session/USB recall. Symbolic browser descriptors cannot prove those engine paths.
5. Implement an independent backing decoder/player, gap/seek/end sequencing, shared gain/pan and routing. Validate previous/next missing-file behavior, end-of-list policy, continuity, clock ownership, actual USB removal safety and output levels on hardware.
6. Make session duplication a durable independent manifest without duplicating mutable audio ownership. Define reference counting and reclaim unreferenced media safely after deletion; confirm that live playback, another session and a USB backup never lose shared assets.
7. Preserve Library folder metadata through the selected complete-appliance backup scope. Existing per-session restore already creates an independent session; complete appliance backup, folder deletion/renaming and arbitrary nested organization are not implemented by this slice.
8. The guide advertises more than 300 factory audio loops, but the supplied extraction does not establish an available redistributable audio collection. The fixture list is not that collection. Factory audio content/licensing and the final arbitrary-file codec matrix remain open.
