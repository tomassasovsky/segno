import 'dart:async';

import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/playback_options.dart';

/// A page fixture for the same accepted Decay snapshot shown by its owner.
class MockDecayPlaybackSettings extends Mock
    implements PlaybackSettings, DecayControl, OneShotControl {
  /// Creates an available accepted owner, or one still uninitialized.
  MockDecayPlaybackSettings({
    DecaySnapshot? snapshot,
    OneShotSnapshot? oneShot,
  }) {
    registerFallbackValue(const DecayAddress.defaults());
    registerFallbackValue(const OneShotAddress.defaults());
    when(() => state).thenAnswer(
      (_) => PlaybackOptions(
        overdubDecay: decaySnapshot?.defaultPercent ?? 0,
        trackOverdubDecayOverrides: decaySnapshot?.trackOverrides ?? const {},
        decayReady: decaySnapshot != null,
        defaultOneShot: oneShotSnapshot?.defaultOneShot ?? false,
        trackOneShotOverrides: oneShotSnapshot?.trackOverrides ?? const {},
        oneShotReady: oneShotSnapshot != null,
      ),
    );
    when(() => stream).thenAnswer((_) => _states.stream);
    when(() => decaySnapshot).thenReturn(snapshot);
    when(
      () => decayLifetime,
    ).thenReturn((sessionRevision: 0, mixGeneration: 0));
    when(() => ordinaryDecayChanges).thenAnswer(
      (_) => const Stream<({DecayAddress address, int? percent})>.empty(),
    );
    when(() => decayRevision(any())).thenReturn(0);
    when(() => oneShotSnapshot).thenReturn(oneShot);
    when(() => durableOneShotSnapshot).thenReturn(
      oneShot ??
          OneShotSnapshot(defaultOneShot: false, trackOverrides: const {}),
    );
    when(
      () => oneShotLifetime,
    ).thenReturn((sessionRevision: 0, mixGeneration: 0));
    when(() => ordinaryOneShotChanges).thenAnswer(
      (_) => const Stream<({OneShotAddress address, bool? oneShot})>.empty(),
    );
    when(() => oneShotRevision(any())).thenReturn(0);
  }
  final _states = StreamController<PlaybackOptions>.broadcast(sync: true);

  /// Publishes a changed fixture through the same projection seam as the owner.
  void publish() => _states.add(state);

  @override
  Future<void> close() => _states.close();
}
