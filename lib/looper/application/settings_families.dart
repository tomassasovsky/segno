import 'dart:convert';

import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/click_volume.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
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
  double? checkpointOf(double durable, Object? address, double? _) => durable;

  @override
  List<Object?> supersededBy(Object? address, double before, double after) =>
      const [];

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

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}
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
  int? checkpointOf(ClickMode durable, Object? address, int? _) => durable.code;

  @override
  List<Object?> supersededBy(
    Object? address,
    ClickMode before,
    ClickMode after,
  ) => const [];

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

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}
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
    StoredRecordStart _,
  ) => (countInBars: durable.countInBars, soundStart: durable.soundStart);

  @override
  List<Object?> supersededBy(
    Object? address,
    RecordStartSettings before,
    RecordStartSettings after,
  ) => const [];

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

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}

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
  int? checkpointOf(DecaySnapshot durable, Object? address, int? _) =>
      durable.at(address! as DecayAddress);

  @override
  List<Object?> supersededBy(
    Object? address,
    DecaySnapshot before,
    DecaySnapshot after,
  ) => const [];

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
    // Captured before any send: each send also moves the repository's
    // restart values, so reading them after a send-back would make a held
    // temporary value durable.
    final priorDurable = this.durable;
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
        // Send-back results are not checked: the repository's values change
        // only on an accepted send, so a refused send-back leaves them equal
        // to what the engine holds, and the owner reports the refusal.
        for (final undo in sent) {
          apply(undo, prior.at(undo));
        }
        _repository.setDecayRestartIntent(
          defaultPercent: priorDurable.defaultPercent,
          trackOverrides: priorDurable.trackOverrides,
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

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}
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
  bool? checkpointOf(OneShotSnapshot durable, Object? address, bool? _) =>
      durable.at(address! as OneShotAddress);

  @override
  List<Object?> supersededBy(
    Object? address,
    OneShotSnapshot before,
    OneShotSnapshot after,
  ) => const [];

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

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}
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

const _lengthAddresses = <Object?>[
  LooperModeAddress(),
  RecordLengthAddress.defaults(),
  RecordLengthAddress.track(0),
  RecordLengthAddress.track(1),
  RecordLengthAddress.track(2),
  RecordLengthAddress.track(3),
  RecordLengthAddress.track(4),
  RecordLengthAddress.track(5),
  RecordLengthAddress.track(6),
  RecordLengthAddress.track(7),
];

const _allTrackLengths = <Object?>[
  RecordLengthAddress.track(0),
  RecordLengthAddress.track(1),
  RecordLengthAddress.track(2),
  RecordLengthAddress.track(3),
  RecordLengthAddress.track(4),
  RecordLengthAddress.track(5),
  RecordLengthAddress.track(6),
  RecordLengthAddress.track(7),
];

/// Record length and looper mode: the mode, a default and eight track
/// presets, one stored scalar each, confirmed by one receipt for the whole
/// vector.
final class RecordLengthFamily
    implements SettingsFamily<RecordLengthVector, int?> {
  /// Binds the family to its repository receipt and its stored keys.
  const RecordLengthFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings;

  final LooperRepository _repository;
  final SettingsRepository _settings;

  @override
  OwnedSetting get key => OwnedSetting.recordLength;

  @override
  List<Object?> get addresses => _lengthAddresses;

  @override
  bool validate(RecordLengthVector value) =>
      value.defaultBars >= 0 &&
      value.defaultBars <= 64 &&
      value.trackOverrides.entries.every(
        (e) => e.key >= 0 && e.key < 8 && e.value >= 0 && e.value <= 64,
      );

  @override
  Future<int?> readCheckpoint(Object? address) => switch (address) {
    LooperModeAddress() => _settings.readLooperModeCheckpoint(),
    final address => _settings.readRecordLengthCheckpoint(
      channel: (address! as RecordLengthAddress).channel,
    ),
  };

  @override
  Future<void> writeCheckpoint(Object? address, int? checkpoint) =>
      switch (address) {
        LooperModeAddress() => _settings.restoreLooperModeCheckpoint(
          checkpoint,
        ),
        final address => _settings.restoreRecordLengthCheckpoint(
          channel: (address! as RecordLengthAddress).channel,
          bars: checkpoint,
        ),
      };

  @override
  int? checkpointOf(RecordLengthVector durable, Object? address, int? _) =>
      switch (address) {
        LooperModeAddress() => durable.mode.code,
        final address => durable.at(address! as RecordLengthAddress),
      };

  /// Entering Multi retires every track's preset: each track's controller
  /// claim is superseded, so its owed release is not kept as a choice.
  @override
  List<Object?> supersededBy(
    Object? address,
    RecordLengthVector before,
    RecordLengthVector after,
  ) =>
      address is LooperModeAddress &&
          after.mode == LooperMode.multi &&
          before.mode != LooperMode.multi
      ? _allTrackLengths
      : const [];

  @override
  RecordLengthVector durableAfter(
    RecordLengthVector durable,
    RecordLengthVector written,
    Object? address,
  ) => switch (address) {
    LooperModeAddress() => durable.withMode(written.mode),
    final address => durable.withBars(
      address! as RecordLengthAddress,
      written.at(address as RecordLengthAddress),
    ),
  };

  /// An absent mode is Multi, an absent default Auto, an absent track
  /// inherits.
  @override
  RecordLengthVector restoreValue(Map<Object?, int?> checkpoints) =>
      RecordLengthVector(
        defaultBars: checkpoints[const RecordLengthAddress.defaults()] ?? 0,
        trackOverrides: {
          for (var channel = 0; channel < 8; channel++)
            channel: ?checkpoints[RecordLengthAddress.track(channel)],
        },
        mode: LooperMode.fromCode(checkpoints[const LooperModeAddress()] ?? 0),
      );

  /// Removing the key restores Multi, Auto or inheritance.
  @override
  int? repair(Object? address) => null;

  @override
  RecordLengthVector get live {
    final transport = _repository.sessionTransport;
    return RecordLengthVector(
      defaultBars: transport.defaultLengthPresetBars,
      trackOverrides: _repository.trackLengthPresetOverrides,
      mode: transport.looperMode,
    );
  }

  @override
  RecordLengthVector get durable {
    final intent = _repository.lengthRestartIntent;
    return RecordLengthVector(
      defaultBars: intent.defaultBars,
      trackOverrides: intent.trackOverrides,
      mode: intent.mode,
    );
  }

  @override
  bool get captureLocked => _repository.recordLengthCaptureLocked;

  @override
  bool get recoveryRequired => _repository.lengthRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.lengthSettingsFailures;

  /// A restore always sends its mode; an edit switches mode only when the
  /// mode changes.
  @override
  EngineResult request(
    RecordLengthVector live,
    RecordLengthVector durable,
    Object? edit,
  ) => _repository.setLengthSettings(
    defaultBars: live.defaultBars,
    overrides: live.trackOverrides,
    mode: edit == null || live.mode != this.live.mode ? live.mode : null,
    released: live == durable
        ? null
        : (
            defaultBars: durable.defaultBars,
            trackOverrides: durable.trackOverrides,
            mode: durable.mode,
          ),
  );

  @override
  Future<EngineResult> settle() => _repository.settleLengthSettings();

  @override
  EngineResult recover() => _repository.recoverLengthSettings();

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}
}

/// The stored Record timing gate, one storage address of the timing family.
final class _TimingGate {
  const _TimingGate();
}

/// The stored Record timing division, one storage address of the family.
final class _TimingDivision {
  const _TimingDivision();
}

/// The default's two stored scalars, as one write checkpoint.
typedef _DefaultTiming = ({bool? quantize, int? division});

const _timingAddresses = <Object?>[
  _TimingGate(),
  _TimingDivision(),
  RecordTimingAddress.track(0),
  RecordTimingAddress.track(1),
  RecordTimingAddress.track(2),
  RecordTimingAddress.track(3),
  RecordTimingAddress.track(4),
  RecordTimingAddress.track(5),
  RecordTimingAddress.track(6),
  RecordTimingAddress.track(7),
];

/// Record timing: a gate and division for the default and an override per
/// track. Each stored key is its own storage address, so Retry repairs only
/// an unreadable key; a write addresses the default (both scalars) or one
/// track.
final class RecordTimingFamily
    implements SettingsFamily<RecordTimingVector, Object?> {
  /// Binds the family to its repository receipt and its stored keys.
  const RecordTimingFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : _repository = repository,
       _settings = settings;

  final LooperRepository _repository;
  final SettingsRepository _settings;

  @override
  OwnedSetting get key => OwnedSetting.recordTiming;

  @override
  List<Object?> get addresses => _timingAddresses;

  @override
  bool validate(RecordTimingVector value) =>
      value.trackOverrides.keys.every(
        (channel) => channel >= 0 && channel < 8,
      ) &&
      (!value.defaultTiming.quantize ||
          value.defaultTiming.division == value.rememberedDivision);

  @override
  Future<Object?> readCheckpoint(Object? address) async => switch (address) {
    _TimingGate() => await _settings.readRecordTimingGateCheckpoint(),
    _TimingDivision() => await _settings.readRecordTimingDivisionCheckpoint(),
    RecordTimingAddress(channel: null) => (
      quantize: await _settings.readRecordTimingGateCheckpoint(),
      division: await _settings.readRecordTimingDivisionCheckpoint(),
    ),
    final address => await _settings.readRecordTimingOverrideCheckpoint(
      (address! as RecordTimingAddress).channel!,
    ),
  };

  @override
  Future<void> writeCheckpoint(Object? address, Object? checkpoint) async {
    switch (address) {
      case _TimingGate():
        await _settings.restoreRecordTimingGateCheckpoint(
          quantize: checkpoint as bool?,
        );
      case _TimingDivision():
        await _settings.restoreRecordTimingDivisionCheckpoint(
          checkpoint as int?,
        );
      case RecordTimingAddress(channel: null):
        final defaults = checkpoint! as _DefaultTiming;
        await _settings.restoreRecordTimingGateCheckpoint(
          quantize: defaults.quantize,
        );
        await _settings.restoreRecordTimingDivisionCheckpoint(
          defaults.division,
        );
      case RecordTimingAddress(:final channel?):
        await _settings.restoreRecordTimingOverrideCheckpoint(
          channel: channel,
          timing: checkpoint as int?,
        );
    }
  }

  /// [address]'s part of [durable]. A default without a gate keeps the
  /// stored division.
  @override
  Object? checkpointOf(
    RecordTimingVector durable,
    Object? address,
    Object? stored,
  ) {
    final channel = (address! as RecordTimingAddress).channel;
    if (channel == null) {
      final timing = durable.defaultTiming;
      return (
        quantize: timing.quantize,
        division: timing.quantize
            ? timing.division.code
            : (stored! as _DefaultTiming).division,
      );
    }
    return durable.trackOverrides[channel]?.code;
  }

  @override
  List<Object?> supersededBy(
    Object? address,
    RecordTimingVector before,
    RecordTimingVector after,
  ) => const [];

  @override
  RecordTimingVector durableAfter(
    RecordTimingVector durable,
    RecordTimingVector written,
    Object? address,
  ) => durable.withValue(
    address! as RecordTimingAddress,
    written.at(address as RecordTimingAddress),
  );

  /// An absent gate is Immediately; an absent track inherits.
  @override
  RecordTimingVector restoreValue(Map<Object?, Object?> checkpoints) {
    final division = GridDivision.fromCode(
      checkpoints[const _TimingDivision()] as int? ?? 0,
    );
    return RecordTimingVector(
      defaultTiming: RecordTiming.of(
        quantize: checkpoints[const _TimingGate()] as bool? ?? false,
        division: division,
      ),
      rememberedDivision: division,
      trackOverrides: {
        for (var channel = 0; channel < 8; channel++)
          channel: ?RecordTiming.fromCode(
            checkpoints[RecordTimingAddress.track(channel)] as int?,
          ),
      },
    );
  }

  /// Removing an unreadable key restores Immediately, no remembered
  /// division, or inheritance; every other key keeps its value.
  @override
  Object? repair(Object? address) => null;

  @override
  RecordTimingVector get live => RecordTimingVector(
    defaultTiming: _repository.defaultRecordTiming,
    rememberedDivision: _repository.sessionTransport.quantizeDiv,
    trackOverrides: _repository.trackRecordTimingOverrides,
  );

  @override
  RecordTimingVector get durable {
    final intent = _repository.recordTimingRestartIntent;
    return RecordTimingVector(
      defaultTiming: intent.defaultTiming,
      rememberedDivision: intent.rememberedDivision,
      trackOverrides: intent.trackOverrides,
    );
  }

  @override
  bool get captureLocked => _repository.recordTimingCaptureLocked;

  @override
  bool get recoveryRequired => _repository.recordTimingRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.recordTimingFailures;

  /// An edit's tag is its address, which names the native edit mask; a
  /// restore edits every field.
  @override
  EngineResult request(
    RecordTimingVector live,
    RecordTimingVector durable,
    Object? edit,
  ) => _repository.setRecordTimingSettings(
    defaultTiming: live.defaultTiming,
    rememberedDivision: live.rememberedDivision,
    trackOverrides: live.trackOverrides,
    released: live == durable
        ? null
        : (
            defaultTiming: durable.defaultTiming,
            rememberedDivision: durable.rememberedDivision,
            trackOverrides: durable.trackOverrides,
          ),
    editMask: switch (edit) {
      RecordTimingAddress(channel: null) => 1,
      RecordTimingAddress(:final channel?) => 2 << channel,
      _ => 0x1ff,
    },
  );

  @override
  Future<EngineResult> settle() => _repository.settleRecordTimingSettings();

  @override
  EngineResult recover() => _repository.recoverRecordTimingSettings();

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}
}

/// Fade durations: one stored JSON record and no native command. The family
/// holds the accepted live and durable durations itself; a held controller
/// value is live only, and the record keeps its Released value.
final class FadeFamily implements SettingsFamily<FadeDurations, String?> {
  /// Binds the family to its stored record.
  FadeFamily({required SettingsRepository settings}) : _settings = settings;

  final SettingsRepository _settings;
  FadeDurations _live = FadeDurations.defaults;
  FadeDurations _durable = FadeDurations.defaults;

  @override
  OwnedSetting get key => OwnedSetting.fade;

  /// The one record holds every address.
  @override
  List<Object?> get addresses => const [null];

  @override
  bool validate(FadeDurations value) => true;

  /// The exact stored bytes, after checking they decode.
  @override
  Future<String?> readCheckpoint(Object? address) async {
    final record = await _settings.readFadeDurationsCheckpoint();
    if (record != null) _decode(record);
    return record;
  }

  @override
  Future<void> writeCheckpoint(Object? address, String? checkpoint) =>
      _settings.restoreFadeDurationsCheckpoint(checkpoint);

  /// The whole record for [durable]; [stored] when it already holds it, so
  /// an absent record is not written for the defaults.
  @override
  String? checkpointOf(
    FadeDurations durable,
    Object? address,
    String? stored,
  ) {
    final current = stored == null ? FadeDurations.defaults : _decode(stored);
    return current == durable ? stored : jsonEncode(durable.toJson());
  }

  @override
  List<Object?> supersededBy(
    Object? address,
    FadeDurations before,
    FadeDurations after,
  ) => const [];

  /// [durable] with Default ([address] null) or one track taken from
  /// [written].
  @override
  FadeDurations durableAfter(
    FadeDurations durable,
    FadeDurations written,
    Object? address,
  ) => fadeWith(
    durable,
    address as int?,
    address == null ? written.defaultMs : written.overrides[address],
  );

  /// An absent record is the declared defaults.
  @override
  FadeDurations restoreValue(Map<Object?, String?> checkpoints) {
    final record = checkpoints[null];
    return record == null ? FadeDurations.defaults : _decode(record);
  }

  /// An unreadable record is replaced by the declared defaults, stored.
  @override
  String? repair(Object? address) =>
      jsonEncode(FadeDurations.defaults.toJson());

  @override
  FadeDurations get live => _live;

  @override
  FadeDurations get durable => _durable;

  @override
  bool get captureLocked => false;

  @override
  bool get recoveryRequired => false;

  @override
  Stream<EngineResult> get failures => const Stream.empty();

  /// No native command: the next gesture reads [live].
  @override
  EngineResult request(
    FadeDurations live,
    FadeDurations durable,
    Object? edit,
  ) {
    _live = live;
    _durable = durable;
    return EngineResult.ok;
  }

  @override
  Future<EngineResult> settle() => Future.value(EngineResult.ok);

  @override
  EngineResult recover() => EngineResult.ok;

  /// No restart replay retires a held value, so a new session or device
  /// lifetime returns the next gesture to the durable durations.
  @override
  void retireLive() => _live = _durable;

  static FadeDurations _decode(String record) =>
      FadeDurations.fromJson(jsonDecode(record) as Map<String, dynamic>);
}

/// [base] with Default ([channel] null) or one track's explicit value set; a
/// null track value removes its override. Throws [FormatException] for an
/// invalid value or track.
FadeDurations fadeWith(FadeDurations base, int? channel, int? milliseconds) {
  if (channel == null) {
    if (milliseconds == null) {
      throw const FormatException('Fade Default needs a duration');
    }
    return FadeDurations(defaultMs: milliseconds, overrides: base.overrides);
  }
  base.effectiveMs(channel); // Validates even a removal of an absent slot.
  return FadeDurations(
    defaultMs: base.defaultMs,
    overrides: {
      for (final entry in base.overrides.entries)
        if (entry.key != channel) entry.key: entry.value,
      channel: ?milliseconds,
    },
  );
}
