import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/settings_owner.dart';
import 'package:segno/looper/model/audio_tempo.dart';
import 'package:segno/looper/model/owned_setting.dart';
import 'package:settings_repository/settings_repository.dart';

/// An Audio & tempo Loop setting (#1179): a default and eight track
/// overrides, one stored nullable bool each, confirmed by one callback
/// receipt for the whole vector. The two families differ only in their
/// stored keys, their repository vector and their default.
sealed class _InheritFamily<T extends Object>
    implements SettingsFamily<InheritSnapshot<T>, bool?> {
  const _InheritFamily(this._repository, this._settings);

  final LooperRepository _repository;
  final SettingsRepository _settings;

  /// The value an absent default checkpoint restores.
  T get absentDefault;

  /// The stored scalar for [value], and back.
  bool encode(T value);
  T decode({required bool stored});

  Future<bool?> read(int? channel);
  Future<void> write(int? channel, {required bool? stored});

  EngineResult requestVector(T defaultValue, Map<int, T> overrides);

  ({T defaultValue, Map<int, T> overrides}) get restartIntent;

  @override
  List<Object?> get addresses => audioTempoAddresses;

  @override
  bool validate(InheritSnapshot<T> value) =>
      value.trackOverrides.keys.every((channel) => channel >= 0 && channel < 8);

  @override
  Future<bool?> readCheckpoint(Object? address) =>
      read((address! as AudioTempoAddress).channel);

  @override
  Future<void> writeCheckpoint(Object? address, bool? checkpoint) =>
      write((address! as AudioTempoAddress).channel, stored: checkpoint);

  @override
  bool? checkpointOf(InheritSnapshot<T> durable, Object? address, bool? _) {
    final value = durable.at(address! as AudioTempoAddress);
    return value == null ? null : encode(value);
  }

  @override
  List<Object?> supersededBy(
    Object? address,
    InheritSnapshot<T> before,
    InheritSnapshot<T> after,
  ) => const [];

  @override
  InheritSnapshot<T> durableAfter(
    InheritSnapshot<T> durable,
    InheritSnapshot<T> written,
    Object? address,
  ) => durable.withValue(
    address! as AudioTempoAddress,
    written.at(address as AudioTempoAddress),
  );

  /// An absent default restores [absentDefault]; an absent track inherits.
  @override
  InheritSnapshot<T> restoreValue(Map<Object?, bool?> checkpoints) {
    final stored = checkpoints[const AudioTempoAddress.defaults()];
    return InheritSnapshot(
      defaultValue: stored == null ? absentDefault : decode(stored: stored),
      trackOverrides: {
        for (var channel = 0; channel < 8; channel++)
          if (checkpoints[AudioTempoAddress.track(channel)] case final bool v)
            channel: decode(stored: v),
      },
    );
  }

  /// Removing the key restores the default or inheritance.
  @override
  bool? repair(Object? address) => null;

  @override
  InheritSnapshot<T> get durable {
    final intent = restartIntent;
    return InheritSnapshot(
      defaultValue: intent.defaultValue,
      trackOverrides: intent.overrides,
    );
  }

  @override
  bool get captureLocked => false;

  /// The vector is the whole intent; the repository sends only what the
  /// engine lacks.
  @override
  EngineResult request(
    InheritSnapshot<T> live,
    InheritSnapshot<T> durable,
    Object? edit,
  ) => requestVector(live.defaultValue, live.trackOverrides);

  /// The restart replay already lands the durable value.
  @override
  void retireLive() {}
}

/// Follow tempo: whether a song-tempo change retimes a track (true) or it
/// keeps its recorded speed. An absent default is On (E15): the page that
/// turns it off ships with it.
final class FollowTempoFamily extends _InheritFamily<bool> {
  /// Binds the family to its repository receipt and its stored keys.
  const FollowTempoFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : super(repository, settings);

  @override
  OwnedSetting get key => OwnedSetting.followTempo;

  @override
  bool get absentDefault => true;

  @override
  bool encode(bool value) => value;

  @override
  bool decode({required bool stored}) => stored;

  @override
  Future<bool?> read(int? channel) =>
      _settings.readFollowTempoCheckpoint(channel: channel);

  @override
  Future<void> write(int? channel, {required bool? stored}) =>
      _settings.restoreFollowTempoCheckpoint(channel: channel, follow: stored);

  @override
  EngineResult requestVector(bool defaultValue, Map<int, bool> overrides) =>
      _repository.setFollowTempoSettings(
        defaultFollow: defaultValue,
        trackOverrides: overrides,
      );

  @override
  ({bool defaultValue, Map<int, bool> overrides}) get restartIntent {
    final intent = _repository.followTempoRestartIntent;
    return (
      defaultValue: intent.defaultFollow,
      overrides: intent.trackOverrides,
    );
  }

  @override
  InheritSnapshot<bool> get live => InheritSnapshot(
    defaultValue: _repository.defaultFollowTempo,
    trackOverrides: _repository.trackFollowTempoOverrides,
  );

  @override
  bool get recoveryRequired => _repository.followTempoRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.followTempoFailures;

  @override
  Future<EngineResult> settle() => _repository.settleFollowTempo();

  @override
  EngineResult recover() => _repository.recoverFollowTempoSettings();
}

/// Pitch: what a retime does to a following track's pitch. Stored as
/// whether it follows the speed; an absent default is Unchanged.
final class PitchModeFamily extends _InheritFamily<PitchMode> {
  /// Binds the family to its repository receipt and its stored keys.
  const PitchModeFamily({
    required LooperRepository repository,
    required SettingsRepository settings,
  }) : super(repository, settings);

  @override
  OwnedSetting get key => OwnedSetting.pitchMode;

  @override
  PitchMode get absentDefault => PitchMode.unchanged;

  @override
  bool encode(PitchMode value) => value == PitchMode.followsSpeed;

  @override
  PitchMode decode({required bool stored}) =>
      stored ? PitchMode.followsSpeed : PitchMode.unchanged;

  @override
  Future<bool?> read(int? channel) =>
      _settings.readPitchFollowsSpeedCheckpoint(channel: channel);

  @override
  Future<void> write(int? channel, {required bool? stored}) =>
      _settings.restorePitchFollowsSpeedCheckpoint(
        channel: channel,
        followsSpeed: stored,
      );

  @override
  EngineResult requestVector(
    PitchMode defaultValue,
    Map<int, PitchMode> overrides,
  ) => _repository.setPitchModeSettings(
    defaultMode: defaultValue,
    trackOverrides: overrides,
  );

  @override
  ({PitchMode defaultValue, Map<int, PitchMode> overrides}) get restartIntent {
    final intent = _repository.pitchModeRestartIntent;
    return (defaultValue: intent.defaultMode, overrides: intent.trackOverrides);
  }

  @override
  InheritSnapshot<PitchMode> get live => InheritSnapshot(
    defaultValue: _repository.defaultPitchMode,
    trackOverrides: _repository.trackPitchModeOverrides,
  );

  @override
  bool get recoveryRequired => _repository.pitchModeRecoveryRequired;

  @override
  Stream<EngineResult> get failures => _repository.pitchModeFailures;

  @override
  Future<EngineResult> settle() => _repository.settlePitchMode();

  @override
  EngineResult recover() => _repository.recoverPitchModeSettings();
}
