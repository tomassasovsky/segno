import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:settings_repository/settings_repository.dart';

/// Click volume: one physical gain, stored as an exact scalar.
final class ClickVolumeFamily implements SettingsFamily<double, double?> {
  /// Binds the family to its repository receipt and its stored key.
  const ClickVolumeFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings;

  final LooperRepository _repository;
  final SettingsRepository _settings;

  @override
  OwnedSetting get key => OwnedSetting.clickVolume;

  @override
  bool validate(double value) =>
      value.isFinite && value >= 0 && value <= kMaxClickGain;

  @override
  List<Object?> get addresses => const [null];

  @override
  Future<double?> readCheckpoint(Object? address) async {
    final value = await _settings.readClickVolumeCheckpoint();
    if (value != null && !validate(value)) {
      throw FormatException('Invalid Click volume setting', value);
    }
    return value;
  }

  @override
  Future<void> writeCheckpoint(Object? address, double? checkpoint) =>
      _settings.restoreClickVolumeCheckpoint(checkpoint);

  @override
  double? checkpointOf(double durable, Object? address) => durable;

  @override
  double durableAfter(double durable, double written, Object? address) =>
      written;

  /// An absent preference is unity.
  @override
  double restoreValue(Map<Object?, double?> checkpoints) =>
      checkpoints[null] ?? 1;

  /// Removing the key restores unity.
  @override
  double? repair(Object? address) => null;

  @override
  double get live => _repository.sessionTransport.clickVolume;

  @override
  double get durable => _repository.clickVolumeRestartIntent;

  @override
  bool get captureLocked => false;

  @override
  bool get recoveryRequired => _repository.clickVolumeRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.clickVolumeFailures;

  /// A distinct durable value is the Released one a hold leaves behind.
  @override
  EngineResult request(double live, double durable, Object? edit) => _repository
      .setClickVolume(live, releasedVolume: durable == live ? null : durable);

  @override
  Future<EngineResult> settle() => _repository.settleClickVolume();

  @override
  EngineResult recover() => _repository.recoverClickVolume();
}

/// Hear click: one native mode, stored as its enum code.
final class HearClickFamily implements SettingsFamily<ClickMode, int?> {
  /// Binds the family to its repository receipt and its stored key.
  const HearClickFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings;

  final LooperRepository _repository;
  final SettingsRepository _settings;

  @override
  OwnedSetting get key => OwnedSetting.hearClick;

  @override
  bool validate(ClickMode value) => true;

  @override
  List<Object?> get addresses => const [null];

  @override
  Future<int?> readCheckpoint(Object? address) =>
      _settings.readClickModeCheckpoint();

  @override
  Future<void> writeCheckpoint(Object? address, int? checkpoint) =>
      _settings.restoreClickModeCheckpoint(checkpoint);

  @override
  int? checkpointOf(ClickMode durable, Object? address) => durable.code;

  @override
  ClickMode durableAfter(
    ClickMode durable,
    ClickMode written,
    Object? address,
  ) => written;

  /// An absent preference is First recording.
  @override
  ClickMode restoreValue(Map<Object?, int?> checkpoints) =>
      ClickMode.fromCode(checkpoints[null] ?? ClickMode.recFirst.code);

  /// Off: never adds an audible click the player did not choose.
  @override
  int? repair(Object? address) => ClickMode.off.code;

  @override
  ClickMode get live => _repository.sessionTransport.clickMode;

  @override
  ClickMode get durable => _repository.clickModeRestartIntent;

  @override
  bool get captureLocked => _repository.clickModeCaptureLocked;

  @override
  bool get recoveryRequired => _repository.clickModeRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.clickModeFailures;

  /// A distinct durable choice is the Released one a hold leaves behind.
  @override
  EngineResult request(ClickMode live, ClickMode durable, Object? edit) =>
      _repository.setClickMode(
        live,
        releasedMode: durable == live ? null : durable,
      );

  @override
  Future<EngineResult> settle() => _repository.settleClickMode();

  @override
  EngineResult recover() => _repository.recoverClickMode();
}

/// Presents the Click volume owner through ControlCubit's existing port.
/// Temporary: Part 3 of #1159 replaces the per-family ports with one.
final class ClickVolumeOwnerControl implements ClickVolumeControl {
  /// Adapts the Click volume owner.
  const ClickVolumeOwnerControl(this._owner);

  final SettingsOwner<double, double?> _owner;

  @override
  double? get clickVolume => _owner.value;

  @override
  double get durableClickVolume => _owner.durable;

  @override
  ClickVolumeLifetime get clickVolumeLifetime => _owner.lifetime;

  @override
  Stream<double> get ordinaryClickVolumeChanges =>
      _owner.ordinaryChanges.map((change) => change.value);

  @override
  Future<ClickVolumeOutcome> setControllerClickVolume(
    double volume, {
    required ClickVolumeLifetime lifetime,
    double? releasedVolume,
  }) async {
    final outcome = await _owner.setController(
      volume,
      lifetime: lifetime,
      released: releasedVolume,
    );
    return ClickVolumeOutcome(
      ClickVolumeStatus.values.byName(outcome.status.name),
      deferred: outcome.deferred,
      engineResult: outcome.engineResult,
      error: outcome.error,
    );
  }
}

/// Presents the Hear click owner through ControlCubit's existing port.
/// Temporary: Part 3 of #1159 replaces the per-family ports with one.
final class ClickModeOwnerControl implements ClickModeControl {
  /// Adapts the Hear click owner.
  const ClickModeOwnerControl(this._owner);

  final SettingsOwner<ClickMode, int?> _owner;

  @override
  ClickModeSnapshot? get clickModeSnapshot => _owner.ready
      ? ClickModeSnapshot(
          mode: _owner.live,
          captureLocked: _owner.captureLocked,
        )
      : null;

  @override
  ClickMode get durableClickMode => _owner.durable;

  @override
  ClickModeLifetime get clickModeLifetime => _owner.lifetime;

  @override
  int get clickModeRevision => _owner.revision;

  @override
  Stream<ClickMode> get ordinaryClickModeChanges =>
      _owner.ordinaryChanges.map((change) => change.value);

  @override
  Future<ClickModeOutcome> setClickMode(ClickMode mode) async =>
      _convert(await _owner.set(mode));

  @override
  Future<ClickModeOutcome> setControllerClickMode(
    ClickMode mode, {
    required ClickModeLifetime lifetime,
    required int revision,
    ClickMode? releasedMode,
  }) async => _convert(
    await _owner.setController(
      mode,
      lifetime: lifetime,
      revision: revision,
      released: releasedMode,
    ),
  );

  static ClickModeOutcome _convert(SettingOutcome outcome) => ClickModeOutcome(
    ClickModeStatus.values.byName(outcome.status.name),
    deferred: outcome.deferred,
    engineResult: outcome.engineResult,
    error: outcome.error,
  );
}

/// The stored Count-in and Sound-start scalars, absence included.
typedef StoredRecordStart = ({int? countInBars, bool? soundStart});

/// Count-in and Sound start: one mutually exclusive pair, stored as two
/// scalars. The edit tag is the native edit kind.
final class RecordStartFamily
    implements SettingsFamily<RecordStartSettings, StoredRecordStart> {
  /// Binds the family to its repository receipt and its stored keys.
  const RecordStartFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings;

  final LooperRepository _repository;
  final SettingsRepository _settings;

  @override
  OwnedSetting get key => OwnedSetting.recordStart;

  /// The pair's constructor already refuses an invalid combination.
  @override
  bool validate(RecordStartSettings value) => true;

  @override
  List<Object?> get addresses => const [null];

  @override
  Future<StoredRecordStart> readCheckpoint(Object? address) =>
      _settings.readRecordStartCheckpoint();

  @override
  Future<void> writeCheckpoint(
    Object? address,
    StoredRecordStart checkpoint,
  ) => _settings.restoreRecordStartCheckpoint(checkpoint);

  @override
  StoredRecordStart checkpointOf(
    RecordStartSettings durable,
    Object? address,
  ) => (countInBars: durable.countInBars, soundStart: durable.soundStart);

  @override
  RecordStartSettings durableAfter(
    RecordStartSettings durable,
    RecordStartSettings written,
    Object? address,
  ) => written;

  @override
  RecordStartSettings restoreValue(
    Map<Object?, StoredRecordStart> checkpoints,
  ) => RecordStartSettings.fromCheckpoint(checkpoints[null]!);

  /// Off and no Sound start: nothing waits before a take.
  @override
  StoredRecordStart repair(Object? address) =>
      (countInBars: 0, soundStart: false);

  @override
  RecordStartSettings get live => _pair(_repository.recordStartSettings);

  @override
  RecordStartSettings get durable =>
      _pair(_repository.recordStartRestartIntent);

  @override
  bool get captureLocked => _repository.recordStartCaptureLocked;

  @override
  bool get recoveryRequired => _repository.recordStartRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.recordStartSettingsFailures;

  /// An edit carries its native kind and its Released pair; a restore
  /// carries neither.
  @override
  EngineResult request(
    RecordStartSettings live,
    RecordStartSettings durable,
    Object? edit,
  ) => _repository.setRecordStartSettings(
    countInBars: live.countInBars,
    soundStart: live.soundStart,
    editKind: edit is RecordStartEditKind ? edit : RecordStartEditKind.restore,
    releasedSettings: edit == null
        ? null
        : (countInBars: durable.countInBars, soundStart: durable.soundStart),
  );

  @override
  Future<EngineResult> settle() => _repository.settleRecordStartSettings();

  @override
  EngineResult recover() => _repository.recoverRecordStartSettings();

  static RecordStartSettings _pair(({int countInBars, bool soundStart}) pair) =>
      RecordStartSettings(
        countInBars: pair.countInBars,
        soundStart: pair.soundStart,
      );
}

/// Presents the Count-in owner through ControlCubit's existing port.
/// Temporary: Part 3 of #1159 replaces the per-family ports with one.
final class RecordStartOwnerControl implements RecordStartControl {
  /// Adapts the Count-in owner.
  const RecordStartOwnerControl(this._owner);

  final SettingsOwner<RecordStartSettings, StoredRecordStart> _owner;

  @override
  RecordStartSnapshot? get recordStartSnapshot => _owner.ready
      ? RecordStartSnapshot(
          settings: _owner.live,
          captureLocked: _owner.captureLocked,
        )
      : null;

  @override
  RecordStartSettings? get confirmedRecordStart =>
      _owner.initialized ? _owner.live : null;

  @override
  RecordStartSettings get durableRecordStartSettings => _owner.durable;

  @override
  RecordStartLifetime get recordStartLifetime => _owner.lifetime;

  @override
  int get recordStartRevision => _owner.revision;

  @override
  Stream<RecordStartSettings> get ordinaryRecordStartChanges =>
      _owner.ordinaryChanges.map((change) => change.value);

  @override
  Future<RecordStartOutcome> setCountInBars(int bars) async => _convert(
    await _owner.update(
      (pair) => pair.withCountIn(bars),
      edit: RecordStartEditKind.countIn,
    ),
  );

  @override
  Future<RecordStartOutcome> setSoundStart({required bool enabled}) async =>
      _convert(
        await _owner.update(
          (pair) => RecordStartSettings(
            countInBars: enabled ? 0 : pair.countInBars,
            soundStart: enabled,
          ),
          edit: RecordStartEditKind.sound,
        ),
      );

  @override
  Future<RecordStartOutcome> setControllerCountIn(
    int bars, {
    required RecordStartLifetime lifetime,
    required int revision,
    int? releasedBars,
  }) async => _convert(
    await _owner.updateController(
      (pair) => pair.withCountIn(bars),
      lifetime: lifetime,
      revision: revision,
      released: releasedBars == null
          ? null
          : (held) => held.withCountIn(releasedBars),
      edit: RecordStartEditKind.countIn,
    ),
  );

  static RecordStartOutcome _convert(SettingOutcome outcome) =>
      RecordStartOutcome(
        RecordStartStatus.values.byName(outcome.status.name),
        deferred: outcome.deferred,
        engineResult: outcome.engineResult,
        error: outcome.error,
      );
}

const _decayAddresses = <Object?>[
  DecayAddress.defaults(),
  DecayAddress.track(0),
  DecayAddress.track(1),
  DecayAddress.track(2),
  DecayAddress.track(3),
  DecayAddress.track(4),
  DecayAddress.track(5),
  DecayAddress.track(6),
  DecayAddress.track(7),
];

/// Overdub decay: a default and eight track overrides, one stored scalar
/// each. Decay has no callback receipt: the engine applies it on admission.
final class DecayFamily implements SettingsFamily<DecaySnapshot, int?> {
  /// Binds the family to the repository and its stored keys.
  const DecayFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings;

  final LooperRepository _repository;
  final SettingsRepository _settings;

  @override
  OwnedSetting get key => OwnedSetting.decay;

  @override
  List<Object?> get addresses => _decayAddresses;

  @override
  bool validate(DecaySnapshot value) =>
      _percent(value.defaultPercent) &&
      value.trackOverrides.entries.every(
        (entry) => entry.key >= 0 && entry.key < 8 && _percent(entry.value),
      );

  static bool _percent(int value) => value >= 0 && value <= 100;

  @override
  Future<int?> readCheckpoint(Object? address) => _settings.readDecayCheckpoint(
    channel: (address! as DecayAddress).channel,
  );

  @override
  Future<void> writeCheckpoint(Object? address, int? checkpoint) =>
      _settings.restoreDecayCheckpoint(
        channel: (address! as DecayAddress).channel,
        percent: checkpoint,
      );

  @override
  int? checkpointOf(DecaySnapshot durable, Object? address) =>
      durable.at(address! as DecayAddress);

  @override
  DecaySnapshot durableAfter(
    DecaySnapshot durable,
    DecaySnapshot written,
    Object? address,
  ) => durable.withValue(
    address! as DecayAddress,
    written.at(address as DecayAddress),
  );

  /// An absent default is no decay; an absent track inherits.
  @override
  DecaySnapshot restoreValue(Map<Object?, int?> checkpoints) => DecaySnapshot(
    defaultPercent: checkpoints[const DecayAddress.defaults()] ?? 0,
    trackOverrides: {
      for (var channel = 0; channel < 8; channel++)
        channel: ?checkpoints[DecayAddress.track(channel)],
    },
  );

  /// Removing the key restores the default (no decay) or inheritance.
  @override
  int? repair(Object? address) => null;

  @override
  DecaySnapshot get live => DecaySnapshot(
    defaultPercent: _repository.defaultOverdubDecay,
    trackOverrides: _repository.trackOverdubDecayOverrides,
  );

  @override
  DecaySnapshot get durable {
    final intent = _repository.decayRestartIntent;
    return DecaySnapshot(
      defaultPercent: intent.defaultPercent,
      trackOverrides: intent.trackOverrides,
    );
  }

  @override
  bool get captureLocked => false;

  @override
  bool get recoveryRequired => false;

  @override
  Stream<EngineResult> get failures => const Stream.empty();

  /// Sends only the scalars that change. A refusal puts back the ones
  /// already sent, so a refused vector is never partly audible.
  @override
  EngineResult request(DecaySnapshot live, DecaySnapshot durable, Object? _) {
    final prior = this.live;
    final sent = <DecayAddress>[];
    EngineResult apply(DecayAddress address, int? percent) =>
        switch (address.channel) {
          final channel? => _repository.setTrackOverdubDecay(
            channel: channel,
            percent: percent,
          ),
          null => _repository.setOverdubDecay(percent!),
        };
    for (final address in _decayAddresses.cast<DecayAddress>()) {
      if (live.at(address) == prior.at(address)) continue;
      final result = apply(address, live.at(address));
      if (!result.isOk) {
        for (final undo in sent) {
          apply(undo, prior.at(undo));
        }
        _repository.setDecayRestartIntent(
          defaultPercent: this.durable.defaultPercent,
          trackOverrides: this.durable.trackOverrides,
        );
        return result;
      }
      sent.add(address);
    }
    _repository.setDecayRestartIntent(
      defaultPercent: durable.defaultPercent,
      trackOverrides: durable.trackOverrides,
    );
    return EngineResult.ok;
  }

  @override
  Future<EngineResult> settle() => Future.value(EngineResult.ok);

  @override
  EngineResult recover() => EngineResult.ok;
}

const _oneShotAddresses = <Object?>[
  OneShotAddress.defaults(),
  OneShotAddress.track(0),
  OneShotAddress.track(1),
  OneShotAddress.track(2),
  OneShotAddress.track(3),
  OneShotAddress.track(4),
  OneShotAddress.track(5),
  OneShotAddress.track(6),
  OneShotAddress.track(7),
];

/// Loop/Once: a default and eight track overrides, one stored scalar each,
/// confirmed by one callback receipt for the whole vector.
final class OneShotFamily implements SettingsFamily<OneShotSnapshot, bool?> {
  /// Binds the family to its repository receipt and its stored keys.
  const OneShotFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings;

  final LooperRepository _repository;
  final SettingsRepository _settings;

  @override
  OwnedSetting get key => OwnedSetting.oneShot;

  @override
  List<Object?> get addresses => _oneShotAddresses;

  @override
  bool validate(OneShotSnapshot value) =>
      value.trackOverrides.keys.every((channel) => channel >= 0 && channel < 8);

  @override
  Future<bool?> readCheckpoint(Object? address) => _settings
      .readOneShotCheckpoint(channel: (address! as OneShotAddress).channel);

  @override
  Future<void> writeCheckpoint(Object? address, bool? checkpoint) =>
      _settings.restoreOneShotCheckpoint(
        channel: (address! as OneShotAddress).channel,
        oneShot: checkpoint,
      );

  @override
  bool? checkpointOf(OneShotSnapshot durable, Object? address) =>
      durable.at(address! as OneShotAddress);

  @override
  OneShotSnapshot durableAfter(
    OneShotSnapshot durable,
    OneShotSnapshot written,
    Object? address,
  ) => durable.withValue(
    address! as OneShotAddress,
    oneShot: written.at(address as OneShotAddress),
  );

  /// An absent default loops; an absent track inherits.
  @override
  OneShotSnapshot restoreValue(Map<Object?, bool?> checkpoints) =>
      OneShotSnapshot(
        defaultOneShot: checkpoints[const OneShotAddress.defaults()] ?? false,
        trackOverrides: {
          for (var channel = 0; channel < 8; channel++)
            channel: ?checkpoints[OneShotAddress.track(channel)],
        },
      );

  /// Removing the key restores Loop or inheritance.
  @override
  bool? repair(Object? address) => null;

  @override
  OneShotSnapshot get live => OneShotSnapshot(
    defaultOneShot: _repository.defaultOneShot,
    trackOverrides: _repository.trackOneShotOverrides,
  );

  @override
  OneShotSnapshot get durable {
    final intent = _repository.oneShotRestartIntent;
    return OneShotSnapshot(
      defaultOneShot: intent.defaultOneShot,
      trackOverrides: intent.trackOverrides,
    );
  }

  @override
  bool get captureLocked => false;

  @override
  bool get recoveryRequired => _repository.oneShotRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.oneShotFailures;

  /// An edit carries its Released vector; a restore does not.
  @override
  EngineResult request(
    OneShotSnapshot live,
    OneShotSnapshot durable,
    Object? edit,
  ) => _repository.setOneShotSnapshot(
    defaultOneShot: live.defaultOneShot,
    trackOverrides: live.trackOverrides,
    released: live == durable
        ? null
        : (
            defaultOneShot: durable.defaultOneShot,
            trackOverrides: durable.trackOverrides,
          ),
  );

  @override
  Future<EngineResult> settle() => _repository.settleOneShot();

  @override
  EngineResult recover() => _repository.recoverOneShotSettings();
}

/// Presents the Decay owner through ControlCubit's existing port.
/// Temporary: Part 3 of #1159 replaces the per-family ports with one.
final class DecayOwnerControl implements DecayControl {
  /// Adapts the Decay owner.
  const DecayOwnerControl(this._owner);

  final SettingsOwner<DecaySnapshot, int?> _owner;

  @override
  DecaySnapshot? get decaySnapshot => _owner.value;

  @override
  DecaySnapshot get durableDecaySnapshot => _owner.durable;

  @override
  DecayLifetime get decayLifetime => _owner.lifetime;

  @override
  int decayRevision(DecayAddress address) => _owner.revisionOf(address);

  @override
  Stream<({DecayAddress address, int? percent})> get ordinaryDecayChanges =>
      _owner.ordinaryChanges.map((change) {
        final address = change.address! as DecayAddress;
        return (address: address, percent: change.value.at(address));
      });

  @override
  Future<DecayOutcome> setControllerDecay(
    DecayAddress address,
    int percent, {
    required DecayLifetime lifetime,
    required int revision,
    int? releasedPercent,
  }) async => _convert(
    await _owner.updateController(
      (live) => live.withValue(address, percent),
      address: address,
      lifetime: lifetime,
      revision: revision,
      released: releasedPercent == null
          ? null
          : (held) => held.withValue(address, releasedPercent),
    ),
  );

  @override
  Future<DecayOutcome> setTrackOverdubDecay({
    required int channel,
    required int? percent,
  }) => setOverdubDecay(DecayAddress.track(channel), percent);

  /// Ordinary edit of any address; null removes a track's override.
  Future<DecayOutcome> setOverdubDecay(
    DecayAddress address,
    int? percent,
  ) async => _convert(
    await _owner.update(
      (live) => live.withValue(address, percent),
      address: address,
    ),
  );

  static DecayOutcome _convert(SettingOutcome outcome) => DecayOutcome(
    DecayStatus.values.byName(outcome.status.name),
    deferred: outcome.deferred,
    engineResult: outcome.engineResult,
    error: outcome.error,
  );
}

/// Presents the Loop/Once owner through ControlCubit's existing port.
/// Temporary: Part 3 of #1159 replaces the per-family ports with one.
final class OneShotOwnerControl implements OneShotControl {
  /// Adapts the Loop/Once owner.
  const OneShotOwnerControl(this._owner);

  final SettingsOwner<OneShotSnapshot, bool?> _owner;

  @override
  OneShotSnapshot? get oneShotSnapshot => _owner.value;

  @override
  OneShotSnapshot get durableOneShotSnapshot => _owner.durable;

  @override
  OneShotLifetime get oneShotLifetime => _owner.lifetime;

  @override
  int oneShotRevision(OneShotAddress address) => _owner.revisionOf(address);

  @override
  Stream<({OneShotAddress address, bool? oneShot})>
  get ordinaryOneShotChanges => _owner.ordinaryChanges.map((change) {
    final address = change.address! as OneShotAddress;
    return (address: address, oneShot: change.value.at(address));
  });

  @override
  Future<OneShotOutcome> setControllerOneShot(
    OneShotAddress address, {
    required bool oneShot,
    required OneShotLifetime lifetime,
    required int revision,
    bool? releasedOneShot,
  }) async => _convert(
    await _owner.updateController(
      (live) => live.withValue(address, oneShot: oneShot),
      address: address,
      lifetime: lifetime,
      revision: revision,
      released: releasedOneShot == null
          ? null
          : (held) => held.withValue(address, oneShot: releasedOneShot),
    ),
  );

  @override
  Future<OneShotOutcome> setTrackOneShot({
    required int channel,
    required bool? oneShot,
  }) => setOneShot(OneShotAddress.track(channel), oneShot: oneShot);

  /// Ordinary edit of any address; null removes a track's override.
  Future<OneShotOutcome> setOneShot(
    OneShotAddress address, {
    required bool? oneShot,
  }) async => _convert(
    await _owner.update(
      (live) => live.withValue(address, oneShot: oneShot),
      address: address,
    ),
  );

  static OneShotOutcome _convert(SettingOutcome outcome) => OneShotOutcome(
    OneShotStatus.values.byName(outcome.status.name),
    deferred: outcome.deferred,
    engineResult: outcome.engineResult,
    error: outcome.error,
  );
}
