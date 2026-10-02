import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';

/// A page fixture for the same accepted Decay snapshot shown by its owner.
class MockDecayPlaybackCubit extends MockCubit<PlaybackOptions>
    implements PlaybackOptionsCubit {
  /// Creates an available accepted owner, or one still uninitialized.
  MockDecayPlaybackCubit({DecaySnapshot? snapshot, OneShotSnapshot? oneShot}) {
    registerFallbackValue(const DecayAddress.defaults());
    registerFallbackValue(const OneShotAddress.defaults());
    when(() => state).thenReturn(
      PlaybackOptions(
        overdubDecay: snapshot?.defaultPercent ?? 0,
        trackOverdubDecayOverrides: snapshot?.trackOverrides ?? const {},
        decayReady: snapshot != null,
        defaultOneShot: oneShot?.defaultOneShot ?? false,
        trackOneShotOverrides: oneShot?.trackOverrides ?? const {},
        oneShotReady: oneShot != null,
      ),
    );
    when(() => stream).thenAnswer((_) => const Stream<PlaybackOptions>.empty());
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
}
