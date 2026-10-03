import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/tempo_cubit.dart';

/// A page fixture for the same Click owner provided to ControlCubit and UI.
class MockClickTempoCubit extends MockCubit<TempoSettings>
    implements TempoCubit {
  /// Creates an accepted physical Click value, or an unavailable owner.
  MockClickTempoCubit({double? clickVolume = 1}) {
    when(
      () => state,
    ).thenReturn(
      TempoSettings(
        clickVolume: clickVolume ?? 1,
        clickReady: clickVolume != null,
      ),
    );
    when(() => stream).thenAnswer((_) => const Stream<TempoSettings>.empty());
    when(() => clickModeSnapshot).thenReturn(null);
    when(() => durableClickMode).thenReturn(ClickMode.off);
    when(
      () => clickModeLifetime,
    ).thenReturn((sessionRevision: 0, mixGeneration: 0));
    when(() => clickModeRevision).thenReturn(0);
    when(
      () => ordinaryClickModeChanges,
    ).thenAnswer((_) => const Stream<ClickMode>.empty());
    when(() => this.clickVolume).thenReturn(clickVolume);
    when(() => durableClickVolume).thenReturn(clickVolume ?? 1);
    when(() => clickVolumeLifetime).thenReturn((
      sessionRevision: 0,
      mixGeneration: 0,
    ));
    when(
      () => ordinaryClickVolumeChanges,
    ).thenAnswer((_) => const Stream<double>.empty());
  }
}
