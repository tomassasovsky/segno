import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/model/audio_tempo.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/playback_options.dart';

/// Presents application-owned playback preferences and forwards UI choices.
class PlaybackOptionsCubit extends Cubit<PlaybackOptions> {
  /// Borrows [settings]; closing this adapter leaves its owner available.
  PlaybackOptionsCubit({required PlaybackSettings settings})
    : _settings = settings,
      super(settings.state) {
    _subscription = settings.stream.listen(emit);
  }

  final PlaybackSettings _settings;
  late final StreamSubscription<PlaybackOptions> _subscription;

  Future<void> setOverdubDecay(int percent) async {
    await _settings.decayControl.setOverdubDecay(
      const DecayAddress.defaults(),
      percent,
    );
  }

  Future<void> setTrackOverdubDecay({
    required int channel,
    required int? percent,
  }) async {
    await _settings.decayControl.setTrackOverdubDecay(
      channel: channel,
      percent: percent,
    );
  }

  Future<void> setDefaultOneShot({required bool value}) async {
    await _settings.oneShotControl.setOneShot(
      const OneShotAddress.defaults(),
      oneShot: value,
    );
  }

  Future<void> setTrackOneShot({
    required int channel,
    required bool? oneShot,
  }) async {
    await _settings.oneShotControl.setTrackOneShot(
      channel: channel,
      oneShot: oneShot,
    );
  }

  /// Sets Follow tempo for [channel] (null: the default); a null [follow]
  /// on a track removes its override (Use default).
  Future<void> setFollowTempo({required bool? follow, int? channel}) async {
    final address = channel == null
        ? const AudioTempoAddress.defaults()
        : AudioTempoAddress.track(channel);
    await _settings.followTempoOwner.update(
      (live) => live.withValue(address, follow),
      address: address,
    );
  }

  /// Sets Pitch for [channel] (null: the default); a null [mode] on a track
  /// removes its override (Use default).
  Future<void> setPitchMode({required PitchMode? mode, int? channel}) async {
    final address = channel == null
        ? const AudioTempoAddress.defaults()
        : AudioTempoAddress.track(channel);
    await _settings.pitchModeOwner.update(
      (live) => live.withValue(address, mode),
      address: address,
    );
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await super.close();
  }
}
