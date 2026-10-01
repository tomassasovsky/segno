## Architecture Review

### Scope and independence

Read-only review of the working diff against `a0a54e57ed371c316b9eabcc64379c2c431150cc`: app bootstrap, MonitorCubit, LooperBloc/events, shared FX persistence helpers, mix coordinator/persistence adapter, session mapping, LooperRepository structural-FX/capture/recovery/history paths and changed domain models, SettingsRepository, and the Session schema model. Final source-freeze reconciliation is complete, including the bounded session cache-reset correction.

Engine C/C++/Dart and SessionRepository main/export implementation were authored by this reviewer and are excluded from independent certification. Their interfaces were read only to establish caller contracts. Initial independent-track-gain wiring in LooperRepository was also authored by this reviewer before ownership transfer and is excluded; Sol's subsequent recipe, lifecycle, model and app work is independently reviewed. Native correctness and full test-quality gates are separate reviews. No tests or product edits were performed in this review role.

### Layer Separation

- Violations found: 0.
- App state management calls LooperRepository and SettingsRepository; LooperRepository uses AudioEngine as its engine seam. Session mapping converts repository models into persistence DTOs.
- No direct FFI/data-client access or reverse imports were introduced in the reviewed presentation/state-management paths. Recipe/channel models remain below presentation.

### State Management Assessment

The single mix coordinator remains authoritative for persisted gain/pan, with independent track gain separate from part levels. Structural recipes are prepared once at the repository boundary; remembered state changes only after native admission, while persistence waits for successful application. Capture inheritance changes remembered FX, provenance and mutes on the actual image revision. Session/boot completion waits for recipe acknowledgement.

The following concrete findings were sent to the author and are repaired in the current source:

- **Late acknowledgement and direct save callers:** `LooperBloc._waitAndPersistFx` and MonitorCubit completion paths retain ordinary editor saves beyond the bounded boot deadline. Explicit inheritance/history notifications, old parameter-debounce callbacks, and mode-only monitor announcements all reach the same acknowledgement boundary. Boot/session waits remain bounded.
- **Restart continuation without boot clobber:** `LooperRepository.fxReplayConfirmed` identifies the current engine/session lifetime after a subsequent start has replayed its recipes. Existing settings owners retry only their registered pending targets. They do not dump uninitialized caches or infer dirty settings from boot recipes. New sessions/disposal discard old pending intent; an old generation cannot initiate its stale completion.
- **Save serialization and diagnostics:** target-keyed pending saves retain a newer token during an older asynchronous write. After releasing the busy target, the owner hands off only to a genuinely newer current-session token. A failed unchanged token reports through `addError` and remains pending without a retry spin.
- **Monitor placement:** the repository retains Pre/Post metadata for recording inheritance but submits monitor `preCount: 0`, matching the live-input native capability.
- **Unsupported plugins and relink:** track/output/All-tracks plugins remain explicit unsupported native-bypass placeholders rather than prepared bus hosts. Relink preserves entry placement/channels/identity while avoiding replay of another plugin's state/parameter identifiers. A known unavailable/loading input placeholder stays recordable and dry; a new preparation failure for a working plugin still refuses capture. A copied loading placeholder becomes an explicit unavailable entry rather than an orphaned spinner.
- **Pending plugin control ownership:** shared lane/monitor knob and readback paths check the target's recipe acknowledgement before touching retained hosts or persisting candidate metadata. This does not claim to freeze a third-party plugin editor's internal behavior.
- **Clear/Undo integration:** the repository queues the latest lane recipe/power/provenance intent behind an older pending target. Restored audio waits for its matching FX recipe. Redo cancellation releases staged ownership and requests the dry recipe; native Clear refusal preserves mute and settings. Quiescent stop/start folds accepted Clear intent into remembered state, with stopped notifications or post-replay lane notices for durable follow-through, including raw reconnect.
- **Session replacement of absent targets:** the final recipe loops remove out-of-range remembered lane/track FX and flags instead of leaving them behind or submitting an invalid native target. Stopped restoration retains the eight product-track settings boundary; source audio identity is not remapped.

### Dependency Direction and Package Structure

- Direction/cycle violations found: 0.
- LooperRepository depends on segno_engine; SettingsRepository retains its local-storage dependency; app orchestration consumes repositories. No native object escapes into presentation.
- No new package or parallel transaction coordinator is introduced. The per-target recipe acknowledgement follows native ownership, and the narrow pending-save identities reference existing save functions rather than duplicating chain payloads.

### Evidence and limits

This role independently traced the changed source and repair deltas. The separate reviewer exercised immutable native v3 and actual Bloc/settings held-callback cases; the author/root own focused tests and aggregate gates. These are distinct evidence sources, not tests run by this reviewer.

The lifecycle checks govern which saves may start. They do **not** cancel a platform storage Future that already started. The existing direct `_persistLaneChain` sink for granular power/session sweeps and MonitorCubit `syncFromRepository` writes do not join or cancel every older platform write. Their raw write semantics predate this change. Full ordering/rollback across already-in-flight storage writes, and a complete storage-recovery UI, remain M7 obligations; this report does not claim them verified. Hardware and production callback timing validation remain separate.

### Verdict

Architecture review complete for the bound source hashes: 0 unresolved actionable findings. Root owns aggregate checks and overall review status; this role does not certify authored code or replace the independent bug/test gates.

### Source binding

The private 17-file SHA-256 manifest has `complete: true`; its SHA-256 is `1eaa4e4c3d1a8ff03665525b92bcf945902b270e7a583a06a2b1d6e5565ebe2e`. Critical lifecycle files at completion:

- `packages/looper_repository/lib/src/looper_repository.dart`: `71f74c3891220c86c54c682f67c4eb4f567076a6f1ebfbc7ab4e9c132acae3bc`
- `lib/looper/bloc/looper_bloc.dart`: `3a93404289c66c2715ff9336348469322183b73202f0baf0d088de23c26dfe0d`
- `lib/audio_setup/cubit/monitor_cubit.dart`: `936ab069514567d913b20572de35888df6ef5c7d20a78538933d9c64e157cd53`
- `lib/common/fx_chain_persistence.dart`: `5635d6e588d222dbb184152a7ca0247601f027ea0da6588762e47cae12c36b76`

### Final recovery delta

The repository-only follow-up prevents a completed empty recovery scan from re-marking an already unavailable lane plugin as loading during an unrelated bus edit. The catalog clears its active scan before completing the shared Future; the guard still admits initial/in-progress recovery and leaves existing generation/session checks intact. Reversing only this conditional/comment block reconstructs the previously reviewed repository hash exactly. All other 16 bound source files are unchanged. The supplied focused log records five successful recovery tests, including the existing bus-write/missing-lane assertion; this reviewer inspected the log and source without rerunning tests. No additional finding.
