import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/app/monitor_mute.dart';
import 'package:settings_repository/settings_repository.dart';

/// Per-hardware-input live-monitor configuration.
///
/// Each monitored input carries its live signal through a single effect chain
/// with its own output routing, volume, and mute. An empty effect chain is the
/// clean (dry) path. This is the chain snapshot-copied onto a track lane
/// when you record into the input, so what you monitor is what the take stores.
class MonitorState extends Equatable {
  /// Creates a [MonitorState] from a map of input index to its [InputMonitor].
  const MonitorState({this.inputs = const {}, this.restoreFailed = false});

  /// Saved monitoring has not been fully restored; an explicit retry is needed.
  final bool restoreFailed;

  /// The configured monitors, keyed by hardware input index. Inputs absent from
  /// the map are not monitored (a default, disabled [InputMonitor]).
  final Map<int, InputMonitor> inputs;

  /// The monitor for [input], or a disabled default when none is configured.
  InputMonitor forInput(int input) =>
      inputs[input] ?? InputMonitor(input: input);

  /// Whether [input] has a configured monitor, as opposed to the synthesized
  /// default [forInput] hands back. Callers that WRITE must check this first,
  /// or they materialize (and persist) a monitor the user never created.
  bool hasInput(int input) => inputs.containsKey(input);

  /// Returns a copy with [monitor] replacing its input's entry.
  MonitorState withInput(InputMonitor monitor) => MonitorState(
    inputs: {...inputs, monitor.input: monitor},
    restoreFailed: restoreFailed,
  );

  @override
  List<Object?> get props => [inputs, restoreFailed];
}

/// Owns the per-input live monitors: applies them to the [LooperRepository] and
/// persists them via [SettingsRepository].
class MonitorCubit extends Cubit<MonitorState> {
  /// Creates a [MonitorCubit] driving [repository], persisted through
  /// [settings].
  MonitorCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
    required MixSettingsCoordinator mixSettings,
    required FxChainPersistence fxPersistence,
    Duration fxPersistDebounce = const Duration(milliseconds: 300),
  }) : _repository = repository,
       _settings = settings,
       _mixSettings = mixSettings,
       _fxPersistence = fxPersistence,
       _fxPersistDebounce = fxPersistDebounce,
       super(const MonitorState()) {
    // Subscribed at construction, not in [load]: this cubit is a cache of
    // state another writer can change from the first frame, and a session
    // applied before the restore finished would already have gone past it.
    // Announcements that arrive before the restore are held, not read — see
    // [_readMonitor].
    _monitorWatch = _repository.monitorChanges.listen(_readMonitor);
    _paramWatch = _repository.monitorParamChanges.listen(_readMonitorParams);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  final MixSettingsCoordinator _mixSettings;
  final FxChainPersistence _fxPersistence;

  final Duration _fxPersistDebounce;

  Future<void>? _loadFuture;

  /// The inbound editor-sync poll cadence (D-SYNC: ≤10 Hz).
  static const Duration _editorPollInterval = Duration(milliseconds: 100);

  /// Per-open-editor sync poll timers, keyed by `(input, index)`. Cancelled on
  /// close / [close] so a closed editor never leaves a ticking timer.
  final Map<(int, int), Timer> _editorTimers = {};

  /// Follows the plugin scan, so the chains pick up what it resolves.
  StreamSubscription<void>? _catalogWatch;

  /// Follows monitor writes that did not come through here.
  ///
  /// This cubit is a write-through cache of state the repository owns, and it
  /// is not the only writer: a pedal binding resolving an `FxStage.input`
  /// target goes straight there (`FxBindingResolver`), as does a session
  /// apply. The other stages are projected onto `LooperState` and so correct
  /// themselves; a monitor lives only in the repository's own maps, so nothing
  /// corrected this one — a footswitch could switch an input chain off and
  /// leave the console drawing it as running, with the first tap writing the
  /// state it was already in and looking inert.
  late final StreamSubscription<int> _monitorWatch;

  /// Follows the repository's throttled (≤10 Hz, D-SYNC cadence) parameter
  /// announces, so a CC sweeping an input-stage param moves the console knob
  /// as it moves the audio — not at the next structural announce (#605).
  late final StreamSubscription<int> _paramWatch;

  /// Whether [_restore] has pushed the saved monitors into the repository.
  bool _restored = false;

  /// Inputs announced before that, to be read once it has.
  final Set<int> _heldReads = {};

  /// Restores the persisted per-input monitors and applies them to the
  /// repository. Reads the single-chain keys; the multi-lane → single-chain
  /// fold (v3) runs at bootstrap, before this.
  Future<void> load() {
    if (isClosed || _restored) return Future<void>.value();
    if (_fxPersistence.sessionTransitionActive) {
      emit(MonitorState(inputs: state.inputs, restoreFailed: true));
      return Future<void>.value();
    }
    final pending = _loadFuture;
    if (pending != null) return pending;
    final session = _repository.sessionRevision;
    late final Future<void> attempt;
    bool stillOwned() =>
        !isClosed &&
        !_restored &&
        identical(_loadFuture, attempt) &&
        _repository.sessionRevision == session &&
        !_fxPersistence.sessionTransitionActive;
    attempt = _mixSettings
        .runExclusive(() async {
          if (stillOwned()) await _restore(stillOwned);
        })
        .catchError((Object error, StackTrace stack) {
          if (!stillOwned()) return;
          addError(error, stack);
          emit(MonitorState(inputs: state.inputs, restoreFailed: true));
        })
        .whenComplete(() {
          if (!identical(_loadFuture, attempt)) return;
          _loadFuture = null;
          // A canceled reservation can leave startup incomplete without a newer
          // Session projection. Keep explicit Retry reachable in that case.
          if (!isClosed &&
              !_restored &&
              _repository.sessionRevision == session) {
            emit(MonitorState(inputs: state.inputs, restoreFailed: true));
          }
        });
    return _loadFuture = attempt;
  }

  Future<void> _restore(bool Function() stillOwned) async {
    // Scan the monitor path's own ceiling ([kMaxMonitoredInputs] ==
    // `LE_MAX_MONITORED_INPUTS`).
    // Only inputs with saved state populate the map.
    final loaded = await Future.wait([
      for (var input = 0; input < kMaxMonitoredInputs; input++)
        _restoreInput(input),
    ]);
    if (!stillOwned()) return;
    final restored = <int, InputMonitor>{};
    for (final monitor in loaded) {
      if (monitor != null) restored[monitor.input] = monitor;
    }
    final priorFx = await _repository.settleFxRecipes();
    if (!stillOwned()) return;
    if (!priorFx.isOk) throw StateError('previous monitor FX was refused');
    for (final monitor in restored.values) {
      if (!stillOwned()) return;
      final result = _applyMonitor(monitor);
      if (!result.isOk) throw StateError('saved monitor settings were refused');
    }
    final monitorLevels = {
      for (final monitor in restored.values) monitor.input: monitor.volume,
    };
    if (!stillOwned()) return;
    if (monitorLevels.isNotEmpty) {
      final request = _repository.setMixSettings(
        trackPans: _repository.trackPans,
        inputSetup: _repository.inputSetup,
        monitorLevels: monitorLevels,
      );
      final settled = request.isOk
          ? await _repository.settleMixSettings()
          : request;
      if (!stillOwned()) return;
      if (!settled.isOk) {
        throw StateError('saved monitor levels were refused');
      }
    }
    final settledFx = await _repository.settleFxRecipes();
    if (!stillOwned()) return;
    if (!settledFx.isOk) throw StateError('saved monitor FX was refused');
    emit(
      MonitorState(
        inputs: restored,
        restoreFailed: state.restoreFailed,
      ),
    );
    // Read the APPLIED chains back into state. What was decoded from settings
    // says nothing about whether a plugin actually loaded: `unavailable`,
    // `loading` and the enumerated params are the repository's answer, made
    // while applying just above, and without this the console draws a stale
    // one — offering to open the window of a plugin that is not there, and
    // never offering to relink the one that is missing.
    //
    // Mint-once for legacy payloads (A9): the repository minted stable slot
    // ids for any id-less restored entries as it applied them, and those have
    // to be persisted back or every launch re-mints DIFFERENT ids for the
    // same legacy chain. Only that case writes; a chain that already had ids
    // is read, not rewritten.
    for (final monitor in restored.values) {
      if (!stillOwned()) return;
      final applied = _repository.monitorEffects(monitor.input);
      // Nothing applied (engine not running / a unit-test fake): keep the
      // restored state; the next real apply re-reads and re-mints.
      if (applied.isEmpty) continue;
      emit(state.withInput(monitor.copyWith(effects: applied)));
      if (!monitor.effects.any((fx) => fx.slotId == null)) continue;
      if (!stillOwned()) return;
      await _persistMonitor(monitor);
      if (!stillOwned()) return;
    }
    // And keep reading it. The engine starts before the app, with a cold
    // plugin cache, so by now every hosted entry has just failed to load and
    // is `loading` while the repository's own recovery scan runs. That scan
    // re-applies the chains when it lands, and nothing tells this cubit — so
    // a plugin that resolves perfectly well would sit in the console reading
    // "loading..." until somebody edited the chain, and a missing one would
    // never offer the relink it needs.
    if (!stillOwned()) return;
    _catalogWatch ??= _repository.pluginCatalog.progressStream.listen(
      (_) => unawaited(_readAfterScan()),
    );
    emit(MonitorState(inputs: state.inputs));
    _followRepository();
  }

  /// Marks the repository authoritative and reads whatever was announced
  /// before it was.
  ///
  /// Both the restore and a session re-projection end here: each is a moment
  /// when the repository stops holding defaults this cubit has not filled in
  /// yet and starts holding the rig.
  void _followRepository() {
    _restored = true;
    final held = _heldReads.toList();
    _heldReads.clear();
    held.forEach(_readMonitor);
  }

  /// Re-reads everything this cubit caches about [input].
  ///
  /// Emits only on a real difference: every write from here comes back
  /// through the same stream, and re-emitting an identical state would rebuild
  /// the console on each one.
  ///
  /// Never writes to the ENGINE: the repository is where this came from, and
  /// pushing it back would be this cubit re-applying, to the engine, the state
  /// the engine's owner just set.
  ///
  /// It does persist, because the alternative is worse than either pole. The
  /// persisted envelope is built from this state, so a bypass read here and
  /// deliberately not saved would still ride into settings on the next
  /// unrelated edit of that chain — the flag would survive a restart if and
  /// only if the player happened to touch the chain afterwards. Saving it is
  /// the answer that is the same every time.
  void _readMonitor(int input) {
    if (isClosed) return;
    // Before the restore, the repository does not hold the player's saved
    // monitors — [_restore] is what puts them there. Reading now would take
    // the repository's DEFAULTS as truth and, worse, save them over good
    // settings, which is silent, permanent, and only visible on the next
    // boot. Held instead, and read once the restore has landed, when the
    // repository really is the authority this treats it as.
    if (!_restored) {
      _heldReads.add(input);
      return;
    }
    final current = state.forInput(input);
    final applied = current.copyWith(
      mode: _repository.monitorMode(input),
      outputMask: _repository.monitorOutput(input),
      volume: _repository.monitorVolume(input),
      muted: _repository.monitorMuted(input),
      // No `isNotEmpty` fallback, unlike every optimistic read here: those
      // guard against reading back a write the repository may have refused.
      // This one is not a read-back — the repository just said this input
      // changed — so an empty chain is a real clear (a session apply), and
      // refusing it would leave the console showing a rack that is gone.
      effects: _repository.monitorEffects(input),
      chainEnabled: _repository.monitorChainEnabled(input),
    );
    if (applied == current) return;
    // A chain that changed SHAPE reseats the slots, so an editor-sync poll
    // keyed to a chain index would start reading a different entry — the same
    // reason [_pushEffects] cancels them on its own edits.
    if (!_sameShape(current.effects, applied.effects)) {
      _cancelEditorTimers(input);
    }
    emit(state.withInput(applied));
    // Every monitor write persists the whole envelope, including FX. Even a
    // mode-only announce can arrive while an earlier recipe is still pending.
    unawaited(_fxPersistence.trackSave(_persistMonitorAfterFx(applied)));
  }

  Future<void> _persistMonitorAfterFx(InputMonitor monitor) => _fxPersistence
      .saveConfirmed(
        FxAddress(stage: FxStage.input, index: monitor.input),
        _settings,
      )
      .catchError((Object error, StackTrace stack) {
        if (!isClosed) addError(error, stack);
      });

  /// Re-reads only [input]'s chain, following a throttled param announce.
  ///
  /// Deliberately does NOT persist, unlike [_readMonitor]: a swept value
  /// arrives here up to ten times a second for the length of the sweep, and
  /// the editor-sync poll — the other follower of live param motion — does
  /// not persist either. The value is not lost to settings: any structural
  /// announce, and every edit made through this cubit, saves the chain with
  /// whatever params it carries by then.
  ///
  /// A param write cannot change the chain's shape, so no editor timers are
  /// cancelled; the whole chain is still re-read (not one value) because the
  /// repository's copy is the truth and a chain is what state carries.
  void _readMonitorParams(int input) {
    if (isClosed) return;
    // Dropped, not held (unlike [_readMonitor]'s pre-restore announces): the
    // restore is about to push the SAVED chain over the repository's, so a
    // pre-restore swept value is gone by the time a held read would run.
    if (!_restored) return;
    final applied = _repository.monitorEffects(input);
    // An empty read here is "nothing to follow", not a clear: a param write
    // requires a non-empty chain, so empty means the engine is not running
    // (or a unit-test fake) — emitting it would wipe the console's chain.
    if (applied.isEmpty) return;
    emit(state.withInput(state.forInput(input).copyWith(effects: applied)));
  }

  /// Whether two chains hold the same entries in the same slots — what an
  /// editor poll's `(input, index)` key depends on.
  static bool _sameShape(List<TrackEffect> a, List<TrackEffect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].slotId != b[i].slotId) return false;
    }
    return true;
  }

  /// Re-reads once the scan's own listeners have run.
  ///
  /// The catalog publishes its last progress event BEFORE it completes the
  /// scan future, and the repository re-applies the chains from that future.
  /// Read straight off the event and the chains are still `loading` — and no
  /// later event is coming, because the poll timer stops in the same breath.
  /// Nor can this join the scan and wait: `_finish` clears the running scan
  /// before completing it, so by delivery time there is nothing left to join.
  ///
  /// Yielding to the event loop is what lands after: the repository's
  /// callback is already queued when this one runs.
  Future<void> _readAfterScan() async {
    await Future<void>.delayed(Duration.zero);
    _readApplied();
  }

  /// Re-reads every known input's applied chain.
  ///
  /// The repository is the one that knows whether a plugin loaded, and its
  /// answer changes when a scan lands. Nothing HERE writes — this path exists
  /// for the transient flags (`loading`, `unavailable`, the enumerated
  /// params), none of which belong in settings and none of which the wire
  /// format carries. What a scan resolves that IS worth saving — a plugin's
  /// display name — reaches settings through [_readMonitor], because a rebind
  /// that rewrote the chain announces and that path persists.
  void _readApplied() {
    if (isClosed) return;
    for (final input in state.inputs.keys.toList()) {
      final applied = _repository.monitorEffects(input);
      if (applied.isEmpty) continue;
      emit(state.withInput(state.forInput(input).copyWith(effects: applied)));
    }
  }

  /// Maps a persisted mode name back to the enum. An unrecognised name reads
  /// as `null` — "nothing saved" — rather than silently becoming `off`, so a
  /// key written by a future build is not mistaken for a deliberate disable.
  static MonitorMode? _modeFromName(String? name) =>
      name == null ? null : monitorModeFromName(name);

  /// Reads hardware [input]'s persisted single-chain monitor, or null if none
  /// was saved. The chain key holds the envelope (R15) — the chain-enabled
  /// flag rides inside it; a legacy bare-array chain decodes chain-enabled.
  Future<InputMonitor?> _restoreInput(int input) async {
    final mode = _modeFromName(await _settings.loadMonitorInputMode(input));
    final outputMask = await _settings.loadMonitorOutput(input);
    final volume = await _settings.loadMonitorVolume(input);
    final muted = await _settings.loadMonitorMute(input);
    final encodedChain = await _settings.loadMonitorEffects(input);
    final chain = decodeFxChain(encodedChain);
    // A chain-DISABLED envelope counts as saved state even with no entries:
    // the encode side can write {chainEnabled:false, entries:[]} (disable the
    // chain, then remove its last effect), and dropping it here would revert
    // the flag to enabled on the next boot — the disable-survives-restart
    // guarantee R15 pins.
    final anySaved =
        mode != null ||
        outputMask != null ||
        volume != null ||
        muted != null ||
        chain.entries.isNotEmpty ||
        !chain.chainEnabled;
    if (!anySaved) return null;
    return InputMonitor(
      input: input,
      mode: mode ?? MonitorMode.off,
      outputMask: outputMask ?? 0x3,
      volume: volume ?? 1.0,
      muted: muted ?? false,
      effects: chain.entries,
      chainEnabled: chain.chainEnabled,
    );
  }

  /// Re-projects a loaded session's monitor display from the repository.
  /// Boot persistence is awaited by the session application boundary; this
  /// display owner must not start a second, unawaited settings sweep.
  void projectFromRepository() {
    if (isClosed) return;
    state.inputs.keys.forEach(_cancelEditorTimers);
    _heldReads.clear();
    _restored = true;
    emit(MonitorState(inputs: _repository.allMonitors()));
  }

  Future<void> _persistMonitor(InputMonitor monitor) =>
      _fxPersistence.saveConfirmed(
        FxAddress(stage: FxStage.input, index: monitor.input),
        _settings,
      );

  /// Enables or disables monitoring of hardware [input], applying and
  /// persisting the change.
  Future<void> setMode(int input, MonitorMode mode) async {
    final monitor = state.forInput(input).copyWith(mode: mode);
    emit(state.withInput(monitor));
    _repository.setMonitorInputMode(input: input, mode: mode);
    await _persistMonitor(monitor);
  }

  /// Sets and persists monitor [input]'s output bitmask.
  Future<void> setOutputMask(int input, int mask) async {
    final next = state.forInput(input).copyWith(outputMask: mask);
    emit(state.withInput(next));
    _repository.setMonitorOutput(input: input, mask: mask);
    await _persistMonitor(next);
  }

  /// Sets and persists monitor [input]'s output gain (silence to unity).
  Future<void> setVolume(int input, double volume) async {
    final result = await _mixSettings.setMonitorVolume(
      input: input,
      volume: volume,
    );
    if (!result.isOk || isClosed) return;
    final confirmed = _repository.monitorVolume(input);
    emit(state.withInput(state.forInput(input).copyWith(volume: confirmed)));
  }

  /// Mutes or unmutes monitor [input].
  Future<void> setMute(int input, {required bool muted}) async {
    if (isClosed) return;
    try {
      await applyMonitorMute(
        repository: _repository,
        settings: _settings,
        persistence: _fxPersistence,
        input: input,
        muted: muted,
        onAccepted: () => emit(
          state.withInput(state.forInput(input).copyWith(muted: muted)),
        ),
      );
    } on Object catch (error, stack) {
      if (!isClosed) addError(error, stack);
      rethrow;
    }
  }

  /// Appends a default effect (drive) to monitor [input]'s chain, Pre.
  ///
  /// A live input's new instances default to Pre (slice 3e): the accepted
  /// design's own default, and the one that matches what this chain is for —
  /// an input's Pre entries are what a take records, its Post entries are
  /// copied onto the lane and run after that take's player.
  void addEffect(int input, {TrackEffectType? type}) {
    final effects = state.forInput(input).effects;
    _pushEffects(input, [
      ...effects,
      BuiltInEffect(
        type: type ?? TrackEffectType.drive,
        placement: FxPlacement.pre,
      ),
    ]);
  }

  /// Replaces monitor [input]'s chain with [effects].
  ///
  /// The structural write every rack surface goes through: rename, reorder and
  /// removal all rewrite the chain rather than edit one slot, because a rack is
  /// several entries that move together.
  void setEffects(int input, List<TrackEffect> effects) =>
      _pushEffects(input, effects);

  /// Replaces a modal editor's chain and reports the matching callback result.
  // An exact mutation acknowledgment controls navigation; projected state
  // cannot identify which accepted recipe the callback applied.
  // ignore: prefer_void_public_cubit_methods
  Future<bool> setEffectsConfirmed(
    int input,
    List<TrackEffect> effects, {
    bool Function()? cancelled,
    int? expectedMixGeneration,
  }) async {
    if ((cancelled?.call() ?? false) ||
        (expectedMixGeneration != null &&
            expectedMixGeneration != _repository.mixGeneration)) {
      return false;
    }
    final result = _pushEffects(input, effects);
    if (!result.isOk) return false;
    final generation = _repository.mixGeneration;
    final session = _repository.sessionRevision;
    final applied = await _repository.settleFxRecipes(
      waitForCallback: true,
      cancelled: () => isClosed || (cancelled?.call() ?? false),
    );
    return applied.isOk &&
        !isClosed &&
        !(cancelled?.call() ?? false) &&
        _repository.mixGeneration == generation &&
        _repository.sessionRevision == session;
  }

  /// Appends one library choice against the repository's current input chain.
  /// A lagging UI projection must not turn a full chain into a successful
  /// clamped write that silently drops the new instance.
  // An exact mutation acknowledgment controls navigation; projected state
  // cannot identify which accepted recipe the callback applied.
  // ignore: prefer_void_public_cubit_methods
  Future<bool> appendEffectsConfirmed(
    int input,
    List<TrackEffect> entries, {
    bool Function()? cancelled,
    int? expectedMixGeneration,
  }) {
    final current = _repository.monitorEffects(input);
    if (entries.isEmpty || current.length + entries.length > kTrackEffectMax) {
      return Future<bool>.value(false);
    }
    return setEffectsConfirmed(
      input,
      [...current, ...entries],
      cancelled: cancelled,
      expectedMixGeneration: expectedMixGeneration,
    );
  }

  /// Appends [entries] to monitor [input]'s chain in one write.
  ///
  /// One write rather than a loop of [addEffect], because a rack is one thing
  /// the player chose: adding its pedals one at a time would push the chain to
  /// the engine once per pedal and let a half-built rack be heard on the way.
  void appendEffects(int input, List<TrackEffect> entries) {
    if (entries.isEmpty) return;
    _pushEffects(input, [...state.forInput(input).effects, ...entries]);
  }

  /// Appends a hosted plugin (identified by [ref]) to monitor [input]'s chain,
  /// Pre — see [addEffect]. The repository loads it through the slot ABI on
  /// the next chain apply.
  void insertPlugin(int input, PluginRef ref) {
    _pushEffects(input, [
      ...state.forInput(input).effects,
      PluginEffect(ref: ref, placement: FxPlacement.pre),
    ]);
  }

  /// Relinks monitor [input]'s plugin chain entry [index] to [ref] (D-MISS),
  /// keeping its captured state + tweaks.
  void relinkPlugin(int input, int index, PluginRef ref) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
    if (fx is! PluginEffect) return;
    final result = _repository.relinkMonitorPlugin(
      input: input,
      index: index,
      ref: ref,
    );
    if (!result.isOk) return;
    final applied = _repository.monitorEffects(input);
    emit(state.withInput(monitor.copyWith(effects: applied)));
    unawaited(_fxPersistence.trackSave(_persistAppliedFx(input)));
  }

  /// Removes monitor [input]'s chain entry at [index].
  void removeEffect(int input, int index) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    _pushEffects(input, [...effects]..removeAt(index));
  }

  /// Reorders monitor [input]'s chain, moving entry [from] to [to].
  void moveEffect(int input, int from, int to) {
    final effects = state.forInput(input).effects;
    if (from < 0 || from >= effects.length) return;
    var target = to;
    if (target < 0) target = 0;
    if (target > effects.length - 1) target = effects.length - 1;
    if (from == target) return;
    // Reorder stays within a stage (slice 3e). A drag across the Pre/Post
    // boundary is refused rather than honoured, because the chain is stored
    // Pre-first: honouring it would re-partition the result straight back and
    // the entry would appear to snap to somewhere nobody asked for. Placement
    // moves through the placement control, which says where it lands.
    if (effects[from].placement != effects[target].placement) return;
    final next = [...effects];
    next.insert(target, next.removeAt(from));
    _pushEffects(input, next);
  }

  /// Moves monitor [input]'s chain entry [index] to [placement] (slice 3e).
  ///
  /// The entry keeps its identity, parameters and enable state and lands at
  /// the end of the destination stage's run. A live input's Pre entries are
  /// what a take records; its Post entries are copied onto the lane and run
  /// after that take's player.
  void setEffectPlacement(int input, int index, FxPlacement placement) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    final fx = effects[index];
    if (fx.placement == placement) return;
    final moved = switch (fx) {
      BuiltInEffect() => fx.copyWith(placement: placement),
      PluginEffect() => fx.copyWith(placement: placement),
    };
    // Removed and appended, not edited in place: the accepted design puts a
    // re-placed instance at the end of its destination stage, and the stable
    // partition in _pushEffects keeps it there.
    _pushEffects(input, [
      for (var i = 0; i < effects.length; i++)
        if (i != index) effects[i],
      moved,
    ]);
  }

  /// Sets the type of monitor [input]'s chain entry [index] (resets its DSP
  /// state and seeds default params).
  void setEffectType(int input, int index, TrackEffectType type) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    // Retyping resets the DSP parameters while retaining the slot's identity
    // and the player's power, placement, and channel settings.
    final old = effects[index];
    final next = [...effects]
      ..[index] = BuiltInEffect(
        type: type,
        enabled: old.enabled,
        slotId: old.slotId,
        placement: old.placement,
        channels: old.channels,
      );
    _pushEffects(input, next);
  }

  /// Sets parameter [param] of monitor [input]'s chain entry [index] to [value]
  /// without resetting DSP state.
  void setEffectParam(int input, int index, int param, double value) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
    // Built-in params only — a plugin's parameter surface arrives in part 5.
    if (fx is! BuiltInEffect) return;
    if (param < 0 || param >= fx.params.length) return;
    final params = List<double>.of(fx.params)..[param] = value;
    final next = [...monitor.effects]..[index] = fx.copyWith(params: params);
    final result = _repository.setMonitorEffectParam(
      input: input,
      index: index,
      param: param,
      value: value,
    );
    if (!result.isOk) return;
    _fxPersistence.ordinaryParameterAt(
      FxAddress(stage: FxStage.input, index: input),
      index,
      param,
      value,
    );
    emit(state.withInput(monitor.copyWith(effects: next)));
    _schedulePersist(input);
  }

  /// Sets hosted-plugin parameter [paramId] of monitor [input]'s chain entry
  /// [index] to the plain [value], routing it to the plugin through the RT
  /// param queue. Mirrors [setEffectParam] for [PluginEffect] entries, keyed by
  /// the stable plugin param id rather than a positional built-in index.
  void setPluginParam(int input, int index, int paramId, double value) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
    if (fx is! PluginEffect) return;
    final values = Map<int, double>.of(fx.paramValues)..[paramId] = value;
    final next = [...monitor.effects]
      ..[index] = fx.copyWith(paramValues: values);
    final result = _repository.setMonitorPluginParam(
      input: input,
      index: index,
      paramId: paramId,
      value: value,
    );
    if (!result.isOk) return;
    emit(state.withInput(monitor.copyWith(effects: next)));
    _schedulePersist(input);
  }

  /// Sets entry [index] of monitor [input]'s chain to [channels].
  ///
  /// By identity at the repository boundary, like placement: channel handling
  /// belongs to the INSTANCE, and an index is what a reorder changes.
  void setEffectChannels(int input, int index, FxChannels channels) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    final slotId = effects[index].slotId;
    if (slotId == null) return;
    final result = _repository.setMonitorEffectChannels(
      input: input,
      slotId: slotId,
      channels: channels,
    );
    if (!result.isOk) return;
    _emitInputEffects(input);
    unawaited(_fxPersistence.trackSave(_persistAppliedFx(input)));
  }

  /// Enables/disables monitor [input]'s chain entry [index] without losing its
  /// type or parameters (R16; click-free ramp engine-side).
  void setEffectEnabled(int input, int index, {required bool enabled}) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    // Write first, then emit what actually landed — the repository owns the
    // flag flip across the sealed entry hierarchy, so re-reading it is more
    // honest than reproducing that dispatch here. [setChainEnabled] keeps the
    // same order for the same reason.
    final result = _repository.setMonitorEffectEnabled(
      input: input,
      index: index,
      enabled: enabled,
    );
    if (!result.isOk) return;
    _fxPersistence.ordinarySlotAt(
      FxAddress(stage: FxStage.input, index: input),
      index,
      enabled: enabled,
    );
    // Fall back to the optimistic chain when the repository reports nothing:
    // it rejects the write (leaving its cache untouched) whenever it holds no
    // chain for this input — engine not running yet, a session load that just
    // cleared the key, or a unit-test fake. Emitting the empty read-back would
    // wipe the user's chain from the UI *and* persist the wipe. Matches the
    // guard [_pushEffects] and the restore path already carry.
    final applied = _repository.monitorEffects(input);
    final next = applied.isNotEmpty ? applied : monitor.effects;
    emit(state.withInput(monitor.copyWith(effects: next)));
    unawaited(
      _fxPersistence.trackSave(
        _persistMonitorAfterFx(state.forInput(input)),
      ),
    );
  }

  /// Enables/disables monitor [input]'s WHOLE chain in one atomic flip, leaving
  /// the per-entry flags intact (R15). A chain-disabled monitor sounds dry and
  /// stops being snapshot-copied onto recording lanes (D-CHAINDIS, R18).
  void setChainEnabled(int input, {required bool enabled}) {
    // Only flip a monitor the user actually has. `forInput` synthesizes a
    // default for an unknown input, so without this an input that exists on
    // the device but was never configured would be materialized into state and
    // persisted here — and the restore path counts a disabled chain as saved
    // state, so the phantom would come back on every subsequent boot.
    if (!state.hasInput(input)) return;
    final monitor = state.forInput(input);
    // Write, then emit — the same order as [setEffectEnabled].
    final result = _repository.setMonitorChainEnabled(
      input: input,
      enabled: enabled,
    );
    if (!result.isOk) return;
    _fxPersistence.ordinaryChain(
      FxAddress(stage: FxStage.input, index: input),
      enabled: enabled,
    );
    emit(state.withInput(monitor.copyWith(chainEnabled: enabled)));
    unawaited(
      _persistMonitorAfterFx(state.forInput(input)),
    );
  }

  /// Opens the native editor window for monitor [input]'s plugin chain entry
  /// [index] (D-WIN) and starts the ≤10 Hz inbound sync poll (D-SYNC): each
  /// tick mirrors editor-driven param moves onto the in-app knobs.
  void openPluginEditor(int input, int index) {
    _repository.openMonitorPluginEditor(input: input, index: index);
    final key = (input, index);
    _editorTimers.remove(key)?.cancel();
    _editorTimers[key] = Timer.periodic(_editorPollInterval, (timer) {
      if (_repository.refreshMonitorPluginParams(input: input, index: index)) {
        _emitInputEffects(input);
      }
      // Self-terminate when the user closes the native window directly.
      if (!_repository.isMonitorPluginEditorOpen(input: input, index: index)) {
        timer.cancel();
        _editorTimers.remove(key);
      }
    });
  }

  /// Closes monitor [input] chain entry [index]'s editor, stops its poll, and
  /// reflects the plugin's final params (D-SYNC read-back) into state.
  void closePluginEditor(int input, int index) {
    _editorTimers.remove((input, index))?.cancel(); // no leaked timer
    _repository.closeMonitorPluginEditor(input: input, index: index);
    _emitInputEffects(input);
  }

  /// Re-reads [input]'s remembered chain from the repository (where the inbound
  /// sync wrote the live values) and emits it, so the knobs follow the editor.
  void _emitInputEffects(int input) {
    final next = state
        .forInput(input)
        .copyWith(
          effects: _repository.monitorEffects(input),
        );
    emit(state.withInput(next));
  }

  EngineResult _pushEffects(int input, List<TrackEffect> rawEffects) {
    // A structural edit reseats the input's slots, so cancel any editor-sync
    // poll keyed by a now-stale chain index (a reorder would otherwise rebind
    // the poll to a different plugin).
    _cancelEditorTimers(input);
    // Partition Pre-first here as well as at the repository write boundary
    // (slice 3e), so the optimistic emit below is never an order the
    // repository is about to change under it: adding a Pre entry to a chain
    // that ends in Post ones would otherwise draw it last for one frame and
    // then jump.
    final effects = partitionByPlacement(rawEffects);
    final result = _repository.setMonitorEffects(
      input: input,
      effects: effects,
    );
    if (!result.isOk) return result;
    emit(state.withInput(state.forInput(input).copyWith(effects: effects)));
    // The repository enriches plugin entries with their enumerated params
    // while applying the chain. Re-read those before the confirmed write.
    final applied = _repository.monitorEffects(input);
    if (applied.isNotEmpty) {
      emit(state.withInput(state.forInput(input).copyWith(effects: applied)));
    }
    unawaited(_fxPersistence.trackSave(_persistAppliedFx(input)));
    return result;
  }

  Future<void> _persistAppliedFx(int input) =>
      _persistMonitorAfterFx(state.forInput(input));

  /// Trailing-debounced persistence of monitor [input]'s chain, for the two
  /// knob-drag entry points ([setEffectParam] / [setPluginParam]). The engine
  /// write stays per-move and immediate; only the envelope rewrite waits.
  ///
  /// The shared owner reads confirmed repository state when storage starts.
  void _schedulePersist(int input) => _fxPersistence.scheduleSave(
    FxAddress(stage: FxStage.input, index: input),
    _settings,
    debounce: _fxPersistDebounce,
  );

  /// Cancels every editor-sync poll timer for monitor [input].
  void _cancelEditorTimers(int input) {
    _editorTimers.removeWhere((key, timer) {
      if (key.$1 == input) {
        timer.cancel();
        return true;
      }
      return false;
    });
  }

  /// Pushes [monitor]'s non-mix fields; restore applies all levels together.
  EngineResult _applyMonitor(InputMonitor monitor) {
    final input = monitor.input;
    // Silence before enabling; unmute only after the destination is ready.
    if (monitor.muted) {
      final result = _repository.setMonitorMute(input: input, muted: true);
      if (!result.isOk) return result;
    }
    _repository
      ..setMonitorInputMode(input: input, mode: monitor.mode)
      ..setMonitorOutput(input: input, mask: monitor.outputMask);
    if (!monitor.muted) {
      final result = _repository.setMonitorMute(input: input, muted: false);
      if (!result.isOk) return result;
    }
    return _repository.setMonitorEffects(
      input: input,
      effects: monitor.effects,
      chainEnabled: monitor.chainEnabled,
      allowUnavailable: true,
    );
  }

  @override
  Future<void> close() {
    // A drag that ended inside the debounce window and was followed by a
    // shutdown must still reach the store.
    _fxPersistence.flushScheduled();
    for (final timer in _editorTimers.values) {
      timer.cancel();
    }
    _editorTimers.clear();
    unawaited(_catalogWatch?.cancel());
    unawaited(_monitorWatch.cancel());
    unawaited(_paramWatch.cancel());
    return super.close();
  }

  /// Commits pending monitor FX writes now. Called on a clean halt.
  Future<void> flushPersistence() => _fxPersistence.flush();
}
