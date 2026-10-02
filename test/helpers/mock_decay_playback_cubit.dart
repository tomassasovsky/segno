import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/playback_options_cubit.dart';
import 'package:segno/looper/model/overdub_decay.dart';

/// A page fixture for the same accepted Decay snapshot shown by its owner.
class MockDecayPlaybackCubit extends MockCubit<PlaybackOptions>
    implements PlaybackOptionsCubit {
  /// Creates an available accepted owner, or one still uninitialized.
  MockDecayPlaybackCubit({DecaySnapshot? snapshot}) {
    registerFallbackValue(const DecayAddress.defaults());
    when(() => state).thenReturn(
      PlaybackOptions(
        overdubDecay: snapshot?.defaultPercent ?? 0,
        trackOverdubDecayOverrides: snapshot?.trackOverrides ?? const {},
        decayReady: snapshot != null,
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
  }
}
