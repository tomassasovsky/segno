import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/write_debouncer.dart';
import 'package:settings_repository/settings_repository.dart';

/// Per-hardware-input live-monitor configuration.
///
/// Each monitored input carries its live signal through a single effect chain
/// with its own output routing, volume, and mute. An empty effect chain is the
/// clean (dry) path. This is the chain snapshot-copied onto a track lane
/// when you record into the input, so what you monitor is what the take stores.
class MonitorState extends Equatable {
  /// Creates a [MonitorState] from a map of input index to its [InputMonitor].
  const MonitorState({this.inputs = const {}});

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
  MonitorState withInput(InputMonitor monitor) =>
      MonitorState(inputs: {...inputs, monitor.input: monitor});

  @override
  List<Object?> get props => [inputs];
}

/// Owns the per-input live monitors: applies them to the [LooperRepository] and
/// persists them via [SettingsRepository].
class MonitorCubit extends Cubit<MonitorState> {
  /// Creates a [MonitorCubit] driving [repository], persisted through
  /// [settings].
  MonitorCubit({
    required LooperRepository repository,
    required SettingsRepository settings,
    Duration fxPersistDebounce = const Duration(milliseconds: 300),
  }) : _repository = repository,
       _settings = settings,
       _fxPersist = WriteDebouncer(debounce: fxPersistDebounce),
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

  /// Coalesces the chain-envelope write a knob drag would otherwise emit per
  /// pointer move — see [_schedulePersist]. Flushed in [close].
  final WriteDebouncer _fxPersist;

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
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    // Scan the monitor path's own ceiling ([kMaxMonitoredInputs] ==
    // `LE_MAX_MONITORED_INPUTS`).
    // Only inputs with saved state populate the map.
    final loaded = await Future.wait([
      for (var input = 0; input < kMaxMonitoredInputs; input++)
        _restoreInput(input),
    ]);
    if (isClosed) return;
    final restored = <int, InputMonitor>{};
    for (final monitor in loaded) {
      if (monitor != null) restored[monitor.input] = monitor;
    }
    emit(MonitorState(inputs: restored));
    restored.values.forEach(_applyMonitor);
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
      if (isClosed) return;
      final applied = _repository.monitorEffects(monitor.input);
      // Nothing applied (engine not running / a unit-test fake): keep the
      // restored state; the next real apply re-reads and re-mints.
      if (applied.isEmpty) continue;
      emit(state.withInput(monitor.copyWith(effects: applied)));
      if (!monitor.effects.any((fx) => fx.slotId == null)) continue;
      await _settings.saveMonitorEffects(
        monitor.input,
        _encodedChain(monitor.input, applied),
      );
    }
    // And keep reading it. The engine starts before the app, with a cold
    // plugin cache, so by now every hosted entry has just failed to load and
    // is `loading` while the repository's own recovery scan runs. That scan
    // re-applies the chains when it lands, and nothing tells this cubit — so
    // a plugin that resolves perfectly well would sit in the console reading
    // "loading..." until somebody edited the chain, and a missing one would
    // never offer the relink it needs.
    _catalogWatch ??= _repository.pluginCatalog.progressStream.listen(
      (_) => unawaited(_readAfterScan()),
    );
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
    unawaited(_persistMonitor(applied));
  }

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

  /// Re-projects the per-input monitors from the [LooperRepository] (the single
  /// owner) after a session load applied them straight to the engine, past this
  /// cubit. Without this the dock would keep showing the PREVIOUS session's
  /// monitors and re-apply them on the next edit, and the persisted settings
  /// would drift from the loaded session (a wrong boot restore).
  ///
  /// Re-persists every configured monitor and resets inputs dropped since the
  /// last state to the disabled default — the same value-level reset
  /// `LooperRepository.applySession` applies to undefined monitors, so the next
  /// boot restores an inert (disabled, unrouted-to-nothing) monitor rather than
  /// the pre-load leftover. Reads only from the repository; never re-applies to
  /// the engine (the load already did), so it cannot desync engine vs cache.
  Future<void> syncFromRepository() async {
    final applied = _repository.allMonitors();
    final dropped = state.inputs.keys
        .where((input) => !applied.containsKey(input))
        .toList();
    // Any open editor-sync poll is keyed to a chain index the load reseated.
    state.inputs.keys.forEach(_cancelEditorTimers);
    emit(MonitorState(inputs: applied));
    _followRepository();
    await Future.wait([
      for (final monitor in applied.values) _persistMonitor(monitor),
      for (final input in dropped) _persistMonitor(InputMonitor(input: input)),
    ]);
  }

  /// Persists every field of [monitor] (the five monitor settings keys). Shared
  /// by [syncFromRepository]'s apply + reset paths so they never diverge from
  /// the set of persisted fields.
  Future<void> _persistMonitor(InputMonitor monitor) async {
    await _settings.saveMonitorInputMode(
      monitor.input,
      mode: monitor.mode.name,
    );
    await _settings.saveMonitorOutput(monitor.input, monitor.outputMask);
    await _settings.saveMonitorVolume(monitor.input, monitor.volume);
    await _settings.saveMonitorMute(monitor.input, muted: monitor.muted);
    await _settings.saveMonitorEffects(
      monitor.input,
      encodeFxChain(
        FxChainEnvelope(
          chainEnabled: monitor.chainEnabled,
          entries: monitor.effects,
        ),
      ),
    );
  }

  /// Enables or disables monitoring of hardware [input], applying and
  /// persisting the change.
  Future<void> setMode(int input, MonitorMode mode) async {
    final monitor = state.forInput(input).copyWith(mode: mode);
    emit(state.withInput(monitor));
    _repository.setMonitorInputMode(input: input, mode: mode);
    await _settings.saveMonitorInputMode(input, mode: mode.name);
  }

  /// Sets and persists monitor [input]'s output bitmask.
  Future<void> setOutputMask(int input, int mask) async {
    final next = state.forInput(input).copyWith(outputMask: mask);
    emit(state.withInput(next));
    _repository.setMonitorOutput(input: input, mask: mask);
    await _settings.saveMonitorOutput(input, mask);
  }

  /// Sets and persists monitor [input]'s output gain (`0..LE_MAX_GAIN`, 2.0,
  /// +6.02 dB headroom above unity).
  Future<void> setVolume(int input, double volume) async {
    final next = state.forInput(input).copyWith(volume: volume);
    emit(state.withInput(next));
    _repository.setMonitorVolume(input: input, volume: volume);
    await _settings.saveMonitorVolume(input, volume);
  }

  /// Mutes or unmutes monitor [input].
  Future<void> setMute(int input, {required bool muted}) async {
    final next = state.forInput(input).copyWith(muted: muted);
    emit(state.withInput(next));
    _repository.setMonitorMute(input: input, muted: muted);
    await _settings.saveMonitorMute(input, muted: muted);
  }

  /// Appends a default effect (drive) to monitor [input]'s chain.
  void addEffect(int input, {TrackEffectType? type}) {
    final effects = state.forInput(input).effects;
    _pushEffects(input, [
      ...effects,
      BuiltInEffect(type: type ?? TrackEffectType.drive),
    ]);
  }

  /// Appends a hosted plugin (identified by [ref]) to monitor [input]'s chain.
  /// The repository loads it through the slot ABI on the next chain apply.
  void insertPlugin(int input, PluginRef ref) {
    _pushEffects(input, [
      ...state.forInput(input).effects,
      PluginEffect(ref: ref),
    ]);
  }

  /// Relinks monitor [input]'s plugin chain entry [index] to [ref] (D-MISS),
  /// keeping its captured state + tweaks.
  void relinkPlugin(int input, int index, PluginRef ref) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    final fx = monitor.effects[index];
    if (fx is! PluginEffect) return;
    _repository.relinkMonitorPlugin(input: input, index: index, ref: ref);
    final applied = _repository.monitorEffects(input);
    emit(state.withInput(monitor.copyWith(effects: applied)));
    unawaited(
      _settings.saveMonitorEffects(input, _encodedChain(input, applied)),
    );
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
    final next = [...effects];
    next.insert(target, next.removeAt(from));
    _pushEffects(input, next);
  }

  /// Sets the type of monitor [input]'s chain entry [index] (resets its DSP
  /// state and seeds default params).
  void setEffectType(int input, int index, TrackEffectType type) {
    final effects = state.forInput(input).effects;
    if (index < 0 || index >= effects.length) return;
    final next = [...effects]..[index] = BuiltInEffect(type: type);
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
    emit(state.withInput(monitor.copyWith(effects: next)));
    _repository.setMonitorEffectParam(
      input: input,
      index: index,
      param: param,
      value: value,
    );
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
    emit(state.withInput(monitor.copyWith(effects: next)));
    _repository.setMonitorPluginParam(
      input: input,
      index: index,
      paramId: paramId,
      value: value,
    );
    _schedulePersist(input);
  }

  /// Enables/disables monitor [input]'s chain entry [index] without losing its
  /// type or parameters (R16; click-free ramp engine-side) — the input-stage
  /// half of the universal per-slot power control.
  void setEffectEnabled(int input, int index, {required bool enabled}) {
    final monitor = state.forInput(input);
    if (index < 0 || index >= monitor.effects.length) return;
    // Write first, then emit what actually landed — the repository owns the
    // flag flip across the sealed entry hierarchy, so re-reading it is more
    // honest than reproducing that dispatch here. [setChainEnabled] keeps the
    // same order for the same reason.
    _repository.setMonitorEffectEnabled(
      input: input,
      index: index,
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
    unawaited(_settings.saveMonitorEffects(input, _encodedChain(input, next)));
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
    _repository.setMonitorChainEnabled(input: input, enabled: enabled);
    emit(state.withInput(monitor.copyWith(chainEnabled: enabled)));
    unawaited(
      _settings.saveMonitorEffects(
        input,
        _encodedChain(input, monitor.effects),
      ),
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

  void _pushEffects(int input, List<TrackEffect> effects) {
    // A structural edit reseats the input's slots, so cancel any editor-sync
    // poll keyed by a now-stale chain index (a reorder would otherwise rebind
    // the poll to a different plugin).
    _cancelEditorTimers(input);
    emit(state.withInput(state.forInput(input).copyWith(effects: effects)));
    _repository.setMonitorEffects(input: input, effects: effects);
    // The repository enriches plugin entries with their enumerated params
    // while applying the chain (so the in-app knobs render). Re-read to pick
    // those up; fall back to the optimistic chain when the repo reports nothing
    // (engine not running yet, or a unit-test fake).
    final applied = _repository.monitorEffects(input);
    if (applied.isNotEmpty) {
      emit(state.withInput(state.forInput(input).copyWith(effects: applied)));
    }
    // Persist the enriched chain (it carries each plugin's resolved display
    // name, so it survives a restart); fall back to the optimistic input only
    // when the repo reported nothing (engine not running / a unit-test fake).
    unawaited(
      _settings.saveMonitorEffects(
        input,
        _encodedChain(input, applied.isNotEmpty ? applied : effects),
      ),
    );
  }

  /// Trailing-debounced persistence of monitor [input]'s chain, for the two
  /// knob-drag entry points ([setEffectParam] / [setPluginParam]). The engine
  /// write stays per-move and immediate; only the envelope rewrite waits.
  ///
  /// Re-reads the chain from the cubit's state at flush time rather than
  /// closing over the list that scheduled it, so a coalesced burst persists
  /// the value the user let go on.
  void _schedulePersist(int input) => _fxPersist.schedule(
    input,
    () => unawaited(
      _settings.saveMonitorEffects(
        input,
        _encodedChain(input, state.forInput(input).effects),
      ),
    ),
  );

  /// Encodes monitor [input]'s chain as the persisted envelope string (R15):
  /// the chain-enabled flag rides beside the entries in the one monitor-fx
  /// key. [effects] is passed rather than read from state because most save
  /// sites persist a just-computed chain the state emit races.
  String _encodedChain(int input, List<TrackEffect> effects) => encodeFxChain(
    FxChainEnvelope(
      chainEnabled: state.forInput(input).chainEnabled,
      entries: effects,
    ),
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

  /// Pushes the whole [monitor] to the repository: mode, then the chain's
  /// routing / mix / effects.
  void _applyMonitor(InputMonitor monitor) {
    final input = monitor.input;
    _repository
      ..setMonitorInputMode(input: input, mode: monitor.mode)
      ..setMonitorOutput(input: input, mask: monitor.outputMask)
      ..setMonitorVolume(input: input, volume: monitor.volume)
      ..setMonitorMute(input: input, muted: monitor.muted)
      ..setMonitorEffects(input: input, effects: monitor.effects)
      ..setMonitorChainEnabled(input: input, enabled: monitor.chainEnabled);
  }

  @override
  Future<void> close() {
    // A drag that ended inside the debounce window and was followed by a
    // shutdown must still reach the store.
    _fxPersist.flush();
    for (final timer in _editorTimers.values) {
      timer.cancel();
    }
    _editorTimers.clear();
    unawaited(_catalogWatch?.cancel());
    unawaited(_monitorWatch.cancel());
    unawaited(_paramWatch.cancel());
    return super.close();
  }
}
