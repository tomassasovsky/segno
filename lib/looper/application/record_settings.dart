import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_families.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_options.dart';
import 'package:settings_repository/settings_repository.dart';

/// Owns the global record-behavior options and presents the Record length
/// owner: ControlCubit's port, the page's edits and the [RecordOptions]
/// projection. The length transaction is the owner's. Defaults to rec → play
/// behavior.
class RecordSettings implements RecordLengthControl {
  /// Builds the length owner over [repository] and [settings].
  RecordSettings({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings,
       owner = SettingsOwner(
         repository: repository,
         family: RecordLengthFamily(repository: repository, settings: settings),
       ) {
    _subscriptions = [
      repository.looperState.listen(_onLooperState),
      owner.changes.listen((_) => _sync()),
    ];
  }

  final LooperRepository _repository;
  final SettingsRepository _settings;

  /// The Record length and looper mode transaction.
  final SettingsOwner<RecordLengthVector, int?> owner;

  /// The owners in the registry's fixed order.
  List<SettingsOwner<Object, Object?>> get owners => [owner];

  final _states = StreamController<RecordOptions>.broadcast(sync: true);
  late final List<StreamSubscription<void>> _subscriptions;
  RecordOptions _state = const RecordOptions();
  bool _published = false;
  Future<void>? _loadFuture;
  Future<void>? _otherLoad;
  Future<void>? _closeFuture;
  int _userEditRevision = 0;

  /// Current accepted record settings and edit eligibility.
  RecordOptions get state => _state;

  /// Accepted values and readiness changes for borrowed presentation.
  Stream<RecordOptions> get stream => _states.stream;

  void _emit(RecordOptions next) {
    if (_states.isClosed || _published && next == _state) return;
    _published = true;
    _state = next;
    _states.add(next);
  }

  void _sync() {
    // Length is published once a load confirms it; until then only its
    // availability and the capture lock are.
    if (!owner.initialized) {
      _emit(
        state.copyWith(
          recordLengthCaptureLocked: owner.captureLocked,
          recordLengthReady: false,
        ),
      );
      return;
    }
    final live = owner.live;
    _emit(
      state.copyWith(
        defaultLengthBars: live.defaultBars,
        trackLengthPresetOverrides: live.trackOverrides,
        recordLengthMode: live.mode,
        recordLengthCaptureLocked: owner.captureLocked,
        recordLengthReady: owner.ready,
      ),
    );
  }

  void _onLooperState(LooperState looper) {
    _emit(
      state.copyWith(
        recDub: looper.transport.recDub,
        defaultMultiple: looper.transport.defaultMultiple,
      ),
    );
    _sync();
  }

  /// Restores the stored length and the rec/dub and loop-length options.
  Future<void> load() => _loadFuture ??= Future.wait([
    _otherLoad ??= _restoreOther(),
    owner.load(),
  ]).then((_) {});

  Future<void> _restoreOther() async {
    final session = _repository.sessionRevision;
    final revision = _userEditRevision;
    final recDub = await _settings.loadRecDub();
    final multiple = await _settings.loadDefaultMultiple();
    if (_states.isClosed) return;
    if (session != _repository.sessionRevision ||
        revision != _userEditRevision) {
      return;
    }
    if (_repository.setRecDub(enabled: recDub).isOk) {
      _emit(state.copyWith(recDub: recDub));
    }
    if (_repository.setDefaultMultiple(multiple: multiple).isOk) {
      _emit(state.copyWith(defaultMultiple: multiple));
    }
  }

  @override
  RecordLengthSnapshot? get recordLengthSnapshot => state.recordLengthSnapshot;

  @override
  RecordLengthSnapshot get durableRecordLengthSnapshot {
    final durable = owner.durable;
    return RecordLengthSnapshot(
      defaultBars: durable.defaultBars,
      trackOverrides: durable.trackOverrides,
      mode: durable.mode,
      captureLocked: owner.captureLocked,
    );
  }

  @override
  RecordLengthLifetime get recordLengthLifetime => owner.lifetime;

  @override
  int recordLengthRevision(RecordLengthAddress address) =>
      owner.revisionOf(address);

  /// A Multi entry reports every track as superseded (null bars): no track
  /// kept a choice of its own.
  @override
  Stream<({RecordLengthAddress address, int? bars})>
  get ordinaryRecordLengthChanges => owner.ordinaryChanges
      .where((change) => change.address is RecordLengthAddress)
      .map((change) {
        final address = change.address! as RecordLengthAddress;
        return (
          address: address,
          bars: change.superseded ? null : change.value.at(address),
        );
      });

  /// Changes the ordinary default preset.
  Future<RecordLengthOutcome> setDefaultLengthBars(int bars) =>
      _setBars(const RecordLengthAddress.defaults(), bars.clamp(0, 64));

  @override
  Future<RecordLengthOutcome> setTrackRecordLength({
    required int channel,
    required int? bars,
  }) => _setBars(RecordLengthAddress.track(channel), bars);

  Future<RecordLengthOutcome> _setBars(
    RecordLengthAddress address,
    int? bars,
  ) async => _convert(
    await owner.update(
      (live) => _editable(live, address).withBars(address, bars),
      address: address,
      edit: address,
    ),
  );

  @override
  Future<RecordLengthOutcome> setControllerRecordLength(
    RecordLengthAddress address,
    int bars, {
    required RecordLengthLifetime lifetime,
    required int revision,
    int? releasedBars,
  }) async => _convert(
    await owner.updateController(
      (live) => _editable(live, address).withBars(address, bars),
      address: address,
      edit: address,
      lifetime: lifetime,
      revision: revision,
      released: releasedBars == null
          ? null
          : (held) => held.withBars(address, releasedBars),
    ),
  );

  /// Entering Multi retires the held track presets to their Released values.
  @override
  Future<RecordLengthOutcome> setLooperMode(LooperMode mode) async => _convert(
    await owner.update(
      (live) => mode == LooperMode.multi && live.mode != LooperMode.multi
          ? live.withMode(mode, overrides: owner.durable.trackOverrides)
          : live.withMode(mode),
      address: const LooperModeAddress(),
      edit: const LooperModeAddress(),
    ),
  );

  /// Multi shares the default: a track preset is not editable there.
  static RecordLengthVector _editable(
    RecordLengthVector live,
    RecordLengthAddress address,
  ) {
    if (address.channel != null && live.mode == LooperMode.multi) {
      throw StateError('Track presets are not editable in Multi');
    }
    return live;
  }

  static RecordLengthOutcome _convert(SettingOutcome outcome) =>
      RecordLengthOutcome(
        RecordLengthStatus.values.byName(outcome.status.name),
        deferred: outcome.deferred,
        engineResult: outcome.engineResult,
        error: outcome.error,
      );

  /// Drains admitted work and disposes the owner.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    // A failed startup preference read remains visible to its load caller,
    // but cannot skip resource cleanup.
    await _otherLoad?.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await Future.wait([
      for (final subscription in _subscriptions) subscription.cancel(),
    ]);
    await owner.close();
    await _states.close();
  }

  /// Sets and persists the rec/dub second-press mode, applying it now.
  Future<void> setRecDub({required bool value}) async {
    _userEditRevision++;
    if (!_repository.setRecDub(enabled: value).isOk) return;
    _emit(state.copyWith(recDub: value));

    await _settings.saveRecDub(value: value);
  }

  /// Sets and persists the global default loop length, applying it now.
  Future<void> setDefaultMultiple(int multiple) async {
    final clamped = multiple < 0 ? 0 : multiple;
    _userEditRevision++;
    if (!_repository.setDefaultMultiple(multiple: clamped).isOk) return;
    _emit(state.copyWith(defaultMultiple: clamped));

    await _settings.saveDefaultMultiple(clamped);
  }
}
