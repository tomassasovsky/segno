import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/cubit/meter_cubit.dart';
import 'package:segno/looper/model/meter_scale.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late _MockLooperRepository repository;
  late StreamController<MeterLevels> levels;

  setUp(() {
    repository = _MockLooperRepository();
    levels = StreamController<MeterLevels>.broadcast(sync: true);
    when(() => repository.meterLevels).thenAnswer((_) => levels.stream);
    when(() => repository.meters).thenReturn(const MeterLevels());
  });

  tearDown(() => unawaited(levels.close()));

  MeterCubit<double> trackMeter(int channel) => MeterCubit<double>(
    repository: repository,
    select: (l) => meterPeak(l.track(channel).peak),
  );

  test('starts from the latest levels', () {
    when(() => repository.meters).thenReturn(
      const MeterLevels(tracks: [TrackLevels(peak: 1)]),
    );
    final cubit = trackMeter(0);
    addTearDown(cubit.close);

    expect(cubit.state, 1);
  });

  test('follows a change in its own value', () async {
    final cubit = trackMeter(0);
    addTearDown(cubit.close);
    final emitted = <double>[];
    final sub = cubit.stream.listen(emitted.add);
    addTearDown(sub.cancel);

    levels.add(const MeterLevels(tracks: [TrackLevels(peak: 1)]));
    await Future<void>.delayed(Duration.zero);

    expect(emitted, [1]);
  });

  test('emits nothing for a change it does not show', () async {
    final cubit = trackMeter(0);
    addTearDown(cubit.close);
    final emitted = <double>[];
    final sub = cubit.stream.listen(emitted.add);
    addTearDown(sub.cancel);

    // Another track's level, then a noise floor under the meter's floor.
    levels
      ..add(
        const MeterLevels(tracks: [TrackLevels.silent, TrackLevels(peak: 1)]),
      )
      ..add(const MeterLevels(tracks: [TrackLevels(peak: 0.0001)]));
    await Future<void>.delayed(Duration.zero);

    expect(emitted, isEmpty);
  });

  test('stops following once closed', () async {
    final cubit = trackMeter(0);
    await cubit.close();

    levels.add(const MeterLevels(tracks: [TrackLevels(peak: 1)]));
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state, 0);
  });
}
