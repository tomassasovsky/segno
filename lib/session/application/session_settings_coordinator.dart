import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/application/record_timing_settings.dart';
import 'package:segno/looper/application/settings_owners.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Coordinates session capture with the live settings transaction owners.
///
/// It borrows those owners; it does not retain a second durable settings cache.
class SessionSettingsCoordinator {
  /// Uses the same concrete application owners as UI and controller commands.
  const SessionSettingsCoordinator({
    required LooperRepository looper,
    required MixSettingsCoordinator mix,
    required FxChainPersistence fx,
    required SettingsOwners owners,
    required TempoSettings tempo,
    required PlaybackSettings playback,
    required RecordSettings record,
    required RecordTimingSettings timing,
    required FadeSettings fade,
  }) : _looper = looper,
       _mix = mix,
       _fx = fx,
       _owners = owners,
       _tempo = tempo,
       _playback = playback,
       _record = record,
       _timing = timing,
       _fade = fade;

  final LooperRepository _looper;
  final MixSettingsCoordinator _mix;
  final FxChainPersistence _fx;
  final SettingsOwners _owners;
  final TempoSettings _tempo;
  final PlaybackSettings _playback;
  final RecordSettings _record;
  final RecordTimingSettings _timing;
  final FadeSettings _fade;

  /// Excludes settings edits through capture and the caller's session I/O.
  /// All session operations acquire these gates in this one order.
  Future<T> runExclusive<T>(Future<T> Function() operation) =>
      _fade.runExclusive(
        (admittedEdits) => _mix.runExclusive(
          () => _owners.runExclusive(
            () => _record.runRecordExclusive(
              () => _timing.runRecordTimingExclusive(() async {
                await admittedEdits;
                return operation();
              }),
            ),
          ),
        ),
      );

  /// Completes the exact accepted Session setup within the held scope.
  Future<void> installFade(FadeDurations incoming) =>
      _fade.installSession(incoming);

  /// Settles accepted edits and captures their Released values together.
  /// Called inside [runExclusive]; [stillOwned] fences the session lifetime.
  Future<({SessionChains chains, SessionSettings settings})> capture({
    required bool Function() stillOwned,
  }) async {
    if (!stillOwned()) throw StateError('session changed before save');
    if (!_looper.lengthSettingsSettled) {
      final result = await _looper.settleLengthSettings();
      if (!result.isOk || !stillOwned()) {
        throw StateError('length settings did not settle before session save');
      }
    }
    if (!_looper.mixSettingsSettled) {
      final result = await _looper.settleMixSettings();
      if (!result.isOk || !stillOwned()) {
        throw StateError('mix settings did not settle before session save');
      }
    }
    final result = await _mix.flush();
    if (!result.isOk || !stillOwned()) {
      throw StateError('mix edit did not settle before session save');
    }
    await _fx.settlePending();
    if (!stillOwned()) throw StateError('session changed before snapshot');
    final mix = _mix.durableSnapshot;
    return (
      chains: chainsFromLooper(_looper, projection: _fx, mix: mix),
      settings: settingsFromLooper(
        _looper,
        mix: mix,
        clickVolume: _tempo.clickVolumeOwner.durable,
        clickMode: _tempo.clickModeOwner.durable,
        recordStart: _tempo.recordStartOwner.durable,
        decay: _playback.decayOwner.durable,
        oneShot: _playback.oneShotOwner.durable,
        recordLength: _record.durableRecordLengthSnapshot,
        recordTiming: _timing.durableRecordTimingSnapshot,
        fade: _fade.confirmed,
      ),
    );
  }
}
