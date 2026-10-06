import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/click_mode.dart';
import 'package:segno/looper/model/click_volume.dart';
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
  Future<double?> readCheckpoint() async {
    final value = await _settings.readClickVolumeCheckpoint();
    if (value != null && !validate(value)) {
      throw FormatException('Invalid Click volume setting', value);
    }
    return value;
  }

  @override
  Future<void> writeCheckpoint(double? checkpoint) =>
      _settings.restoreClickVolumeCheckpoint(checkpoint);

  @override
  double? withDurable(double? checkpoint, double durable) => durable;

  /// An absent preference is unity.
  @override
  double restoreValue(double? checkpoint) => checkpoint ?? 1;

  /// Removing the key restores unity.
  @override
  double? repair() => null;

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
  Future<int?> readCheckpoint() => _settings.readClickModeCheckpoint();

  @override
  Future<void> writeCheckpoint(int? checkpoint) =>
      _settings.restoreClickModeCheckpoint(checkpoint);

  @override
  int? withDurable(int? checkpoint, ClickMode durable) => durable.code;

  /// An absent preference is First recording.
  @override
  ClickMode restoreValue(int? checkpoint) =>
      ClickMode.fromCode(checkpoint ?? ClickMode.recFirst.code);

  /// Off: never adds an audible click the player did not choose.
  @override
  int? repair() => ClickMode.off.code;

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
  Stream<double> get ordinaryClickVolumeChanges => _owner.ordinaryChanges;

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
  Stream<ClickMode> get ordinaryClickModeChanges => _owner.ordinaryChanges;

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
  Future<StoredRecordStart> readCheckpoint() =>
      _settings.readRecordStartCheckpoint();

  @override
  Future<void> writeCheckpoint(StoredRecordStart checkpoint) =>
      _settings.restoreRecordStartCheckpoint(checkpoint);

  @override
  StoredRecordStart withDurable(
    StoredRecordStart checkpoint,
    RecordStartSettings durable,
  ) => (countInBars: durable.countInBars, soundStart: durable.soundStart);

  @override
  RecordStartSettings restoreValue(StoredRecordStart checkpoint) =>
      RecordStartSettings.fromCheckpoint(checkpoint);

  /// Off and no Sound start: nothing waits before a take.
  @override
  StoredRecordStart repair() => (countInBars: 0, soundStart: false);

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
      _owner.ordinaryChanges;

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
