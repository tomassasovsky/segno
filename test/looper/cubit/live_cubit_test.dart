import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/cubit/live_cubit.dart';
import 'package:segno/looper/model/meter_scale.dart';

void main() {
  late StreamController<MeterLevels> levels;
  late MeterLevels latest;

  setUp(() {
    levels = StreamController<MeterLevels>.broadcast(sync: true);
    latest = const MeterLevels();
  });

  tearDown(() => unawaited(levels.close()));

  LiveCubit<MeterLevels, double> trackMeter(int channel) =>
      LiveCubit<MeterLevels, double>(
        values: levels.stream,
        latest: () => latest,
        select: (l) => meterPeak(l.track(channel).peak),
      );

  test('starts from the latest value', () {
    latest = const MeterLevels(tracks: [TrackLevels(peak: 1)]);
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

  test('stops following while not visible, and shows the latest value '
      'when visible again', () async {
    final cubit = trackMeter(0);
    addTearDown(cubit.close);
    final emitted = <double>[];
    final sub = cubit.stream.listen(emitted.add);
    addTearDown(sub.cancel);

    cubit.follow(visible: false);
    expect(levels.hasListener, isFalse);
    latest = const MeterLevels(tracks: [TrackLevels(peak: 1)]);
    levels.add(latest);
    await Future<void>.delayed(Duration.zero);
    expect(emitted, isEmpty);

    cubit.follow(visible: true);
    expect(levels.hasListener, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(emitted, [1]);

    // Following twice does not listen twice.
    cubit.follow(visible: true);
    levels.add(const MeterLevels());
    await Future<void>.delayed(Duration.zero);
    expect(emitted, [1, 0]);
  });

  test('stops following once closed', () async {
    final cubit = trackMeter(0);
    await cubit.close();

    expect(levels.hasListener, isFalse);
    cubit.follow(visible: true);
    expect(levels.hasListener, isFalse);
    expect(cubit.state, 0);
  });
}
