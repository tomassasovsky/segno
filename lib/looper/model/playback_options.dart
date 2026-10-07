import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/model/audio_tempo.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';

/// Accepted global playback options and explicit track decay membership.
class PlaybackOptions extends Equatable {
  /// Creates the playback state; Decay remains unavailable until restored.
  const PlaybackOptions({
    this.overdubDecay = 0,
    this.defaultOneShot = false,
    this.trackOverdubDecayOverrides = const {},
    this.decayReady = false,
    this.oneShotReady = false,
    this.trackOneShotOverrides = const {},
    this.followTempo,
    this.pitchMode,
  });

  /// The default overdub decay in percent, from zero to 100.
  final int overdubDecay;

  /// Whether inheriting tracks play once instead of looping.
  final bool defaultOneShot;

  /// Explicit track values, including zero; absence means inheritance.
  final Map<int, int> trackOverdubDecayOverrides;

  /// Confirmed playback override membership, including Custom false.
  final Map<int, bool> trackOneShotOverrides;

  /// Whether Playback has initialized independently of Decay.
  final bool oneShotReady;

  /// Whether Decay has initialized independently of the Once preference.
  final bool decayReady;

  /// Accepted Follow tempo choices (#1179), null until the owner is ready
  /// (loading, or a vector owed after an uncertain receipt).
  final InheritSnapshot<bool>? followTempo;

  /// Accepted Pitch choices (#1179), null until the owner is ready.
  final InheritSnapshot<PitchMode>? pitchMode;

  /// Accepted Decay settings, unavailable until this field has initialized.
  DecaySnapshot? get decaySnapshot => decayReady
      ? DecaySnapshot(
          defaultPercent: overdubDecay,
          trackOverrides: trackOverdubDecayOverrides,
        )
      : null;

  /// Accepted Once settings, independently available from Decay.
  OneShotSnapshot? get oneShotSnapshot => oneShotReady
      ? OneShotSnapshot(
          defaultOneShot: defaultOneShot,
          trackOverrides: trackOneShotOverrides,
        )
      : null;

  /// Returns a copy with the supplied accepted fields.
  PlaybackOptions copyWith({
    int? overdubDecay,
    bool? defaultOneShot,
    Map<int, int>? trackOverdubDecayOverrides,
    bool? decayReady,
    bool? oneShotReady,
    Map<int, bool>? trackOneShotOverrides,
    InheritSnapshot<bool>? followTempo,
    InheritSnapshot<PitchMode>? pitchMode,
  }) => PlaybackOptions(
    overdubDecay: overdubDecay ?? this.overdubDecay,
    defaultOneShot: defaultOneShot ?? this.defaultOneShot,
    trackOverdubDecayOverrides:
        trackOverdubDecayOverrides ?? this.trackOverdubDecayOverrides,
    decayReady: decayReady ?? this.decayReady,
    oneShotReady: oneShotReady ?? this.oneShotReady,
    trackOneShotOverrides: trackOneShotOverrides ?? this.trackOneShotOverrides,
    followTempo: followTempo ?? this.followTempo,
    pitchMode: pitchMode ?? this.pitchMode,
  );

  @override
  List<Object?> get props => [
    overdubDecay,
    defaultOneShot,
    trackOverdubDecayOverrides,
    decayReady,
    oneShotReady,
    trackOneShotOverrides,
    followTempo,
    pitchMode,
  ];
}
