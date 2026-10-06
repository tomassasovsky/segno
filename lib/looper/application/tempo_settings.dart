import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the tempo grid settings (plan A5), and presents the Click volume,
/// Hear click and Count-in owners in one [TempoState]: loads the persisted
/// intent on [load], applies each setter to the [LooperRepository] (the live
/// engine) AND persists it via [SettingsRepository].
///
/// [tapTempo] is the one exception: a momentary action forwarded straight to
/// the repository, never persisted (see [LooperRepository.tapTempo]'s doc —
/// there is nothing meaningful to remember; the resulting tempo, if any, is
/// the engine's own runtime state).
class TempoSettings {
  /// Creates a [TempoSettings] driving [repository], persisted through
  /// [settings]. Starts at the tempo-free defaults until [load] restores the
  /// saved values.
  TempoSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       clickVolumeOwner = SettingsOwner(
         repository: repository,
         family: ClickVolumeFamily(repository: repository, settings: settings),
       ),
       clickModeOwner = SettingsOwner(
         repository: repository,
         family: HearClickFamily(repository: repository, settings: settings),
       ),
       recordStartOwner = SettingsOwner(
         repository: repository,
         family: RecordStartFamily(repository: repository, settings: settings),
       ) {
    _subscription = _repository.looperState.listen(_onLooperState);
    _ownerSubscriptions = [
      for (final owner in owners) owner.changes.listen((_) => _sync()),
    ];
  }

  /// The Click volume transaction.
  final SettingsOwner<double, double?> clickVolumeOwner;

  /// The Hear click transaction.
  final SettingsOwner<ClickMode, int?> clickModeOwner;

  /// The Count-in and Sound-start transaction.
  final SettingsOwner<RecordStartSettings, StoredRecordStart> recordStartOwner;

  /// The owners in the registry's fixed order.
  List<SettingsOwner<Object, Object?>> get owners => [
    clickVolumeOwner,
    clickModeOwner,
    recordStartOwner,
  ];

  /// ControlCubit's Click volume port over [clickVolumeOwner].
  late final clickVolumeControl = ClickVolumeOwnerControl(clickVolumeOwner);

  /// ControlCubit's Hear click port over [clickModeOwner].
  late final clickModeControl = ClickModeOwnerControl(clickModeOwner);

  /// ControlCubit's Count-in port over [recordStartOwner].
  late final recordStartControl = RecordStartOwnerControl(recordStartOwner);

  TempoState _state = const TempoState();
  final _states = StreamController<TempoState>.broadcast(sync: true);

  /// Current immutable presentation of accepted values and readiness.
  TempoState get state => _state;

  /// Publications consumed by the borrowed UI adapter.
  Stream<TempoState> get stream => _states.stream;

  void _emit(TempoState next) {
    if (_states.isClosed) return;
    final published = next.copyWith(
      clickModeInitialized: clickModeOwner.initialized,
      recordStartInitialized: recordStartOwner.initialized,
    );
    if (_state == published) return;
    _state = published;
    _states.add(published);
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;
  Future<void>? _loadFuture;
  late final StreamSubscription<LooperState> _subscription;
  late final List<StreamSubscription<void>> _ownerSubscriptions;
  int _userEditRevision = 0;
  bool _closing = false;

  void _onLooperState(LooperState _) => _sync();

  void _sync() {
    if (_closing || _states.isClosed) return;
    final transport = _repository.sessionTransport;
    final start = recordStartOwner.live;
    _emit(
      TempoState(
        bpm: transport.tempoBpm,
        tsNum: transport.tsNum,
        tsDen: transport.tsDen,
        clickMode: clickModeOwner.live,
        clickModeReady: clickModeOwner.ready,
        clickModeCaptureLocked: clickModeOwner.captureLocked,
        clickOutputMask: transport.clickMask,
        clickVolume: clickVolumeOwner.live,
        clickReady: clickVolumeOwner.ready,
        countInBars: start.countInBars,
        soundStart: start.soundStart,
        recordStartReady: recordStartOwner.ready,
        recordStartCaptureLocked: recordStartOwner.captureLocked,
      ),
    );
  }

  Future<void>? _closeFuture;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    // Initialization failures belong to the load caller. They must not bypass
    // disposal or prevent the remaining application owners from closing.
    await _loadFuture?.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    try {
      await Future.wait<void>([
        _subscription.cancel(),
        for (final subscription in _ownerSubscriptions) subscription.cancel(),
      ]);
    } finally {
      await Future.wait<void>([
        for (final owner in owners) owner.close(),
        _states.close(),
      ]);
    }
  }

  /// Restores the persisted tempo grid and loads the three owners.
  Future<void> load() => _loadFuture ??= Future.wait<void>([
    _restore(),
    for (final owner in owners) owner.load(),
  ]).then((_) {});

  Future<void> _restore() async {
    final sessionRevision = _repository.sessionRevision;
    final userEditRevision = _userEditRevision;
    final bpm = await _settings.loadTempoBpm();
    final (tsNum, tsDen) = await _settings.loadTimeSignature();
    final clickOutputMask = await _settings.loadClickOutputMask();
    if (_states.isClosed) return;
    if (sessionRevision != _repository.sessionRevision ||
        userEditRevision != _userEditRevision) {
      _sync();
      return;
    }
    // An unset tempo must not become a manual 30 BPM grid.
    final tempoApplied = bpm > 0 && _repository.setTempo(bpm).isOk;
    final signatureApplied = _repository.setTimeSignature(tsNum, tsDen).isOk;
    final outputApplied = _repository.setClickOutput(clickOutputMask).isOk;
    _emit(
      state.copyWith(
        bpm: tempoApplied ? bpm : null,
        tsNum: signatureApplied ? tsNum : null,
        tsDen: signatureApplied ? tsDen : null,
        clickOutputMask: outputApplied ? clickOutputMask : null,
      ),
    );
  }

  /// Sets and persists the tempo in BPM, applying it now.
  ///
  /// Unconditionally calls the repository — this is a "set to this value"
  /// command triggered by an explicit user action, not a delta against the
  /// owner's accepted state. The cache can go stale relative to the live engine
  /// (for example, a recalled session replaces the accepted tempo), so
  /// gating the
  /// repository call on `newValue != state.field` risks silently no-op'ing a
  /// user's tap whose target value happens to match the stale cache while
  /// the live engine holds something else. `emit` stays cheap to call
  /// unconditionally too: equal immutable state does not republish.
  Future<void> setTempo(double bpm) async {
    _userEditRevision++;
    if (!_repository.setTempo(bpm).isOk) return;
    _emit(state.copyWith(bpm: bpm));

    await _settings.saveTempoBpm(bpm);
  }

  /// Sets and persists the time signature, applying it now. [num]/[den] must
  /// be one of [kValidTimeSignatures] — the picker only offers valid choices,
  /// and the engine itself rejects anything else without applying it.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setTimeSignature(int num, int den) async {
    _userEditRevision++;
    if (!_repository.setTimeSignature(num, den).isOk) return;
    _emit(state.copyWith(tsNum: num, tsDen: den));

    await _settings.saveTimeSignature(num, den);
  }

  /// Sets and persists the click output routing bitmask, applying it now.
  /// Unconditional repository call — see [setTempo]'s doc.
  Future<void> setClickOutput(int mask) async {
    _userEditRevision++;
    if (!_repository.setClickOutput(mask).isOk) return;
    _emit(state.copyWith(clickOutputMask: mask));

    await _settings.saveClickOutputMask(mask);
  }

  /// Registers a tempo tap; two taps within the engine's window set the
  /// tempo from their interval. A momentary action forwarded straight to the
  /// repository — never persisted (see the class doc).
  EngineResult tapTempo() {
    _userEditRevision++;
    return _repository.tapTempo();
  }
}
