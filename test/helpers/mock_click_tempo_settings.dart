import 'dart:async';

import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/application/tempo_settings.dart';
import 'package:segno/looper/model/tempo_state.dart';

/// A coherent accepted owner used by controller and presentation fixtures.
class MockClickTempoSettings extends Mock implements TempoSettings {
  MockClickTempoSettings({double? clickVolume = 1}) {
    when(() => clickModeSnapshot).thenReturn(null);
    when(() => durableClickMode).thenReturn(ClickMode.off);
    when(
      () => clickModeLifetime,
    ).thenReturn((sessionRevision: 0, mixGeneration: 0));
    when(() => clickModeRevision).thenReturn(0);
    when(
      () => ordinaryClickModeChanges,
    ).thenAnswer((_) => const Stream.empty());
    when(() => this.clickVolume).thenReturn(clickVolume);
    when(() => durableClickVolume).thenReturn(clickVolume ?? 1);
    when(
      () => clickVolumeLifetime,
    ).thenReturn((sessionRevision: 0, mixGeneration: 0));
    when(
      () => ordinaryClickVolumeChanges,
    ).thenAnswer((_) => const Stream.empty());
    when(() => state).thenAnswer(
      (_) => TempoState(
        clickVolume: this.clickVolume ?? 1,
        clickReady: this.clickVolume != null,
        clickMode: clickModeSnapshot?.mode ?? ClickMode.off,
        clickModeReady: clickModeSnapshot != null,
        clickModeCaptureLocked: clickModeSnapshot?.captureLocked ?? false,
      ),
    );
    when(() => stream).thenAnswer((_) => _states.stream);
  }

  final _states = StreamController<TempoState>.broadcast(sync: true);

  /// Publishes an explicitly changed fixture, as the real owner does.
  void publish() => _states.add(state);

  @override
  Future<void> close() => _states.close();
}
