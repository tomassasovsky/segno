import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:cpu_load_repository/cpu_load_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/cubit/cpu_load_cubit.dart';

/// A repository whose readings a test pushes by hand.
class _ManualCpuLoad extends CpuLoadRepository {
  _ManualCpuLoad() : super(readStat: () async => '');

  final controller = StreamController<int>.broadcast();

  @override
  Stream<int> watch() => controller.stream;
}

void main() {
  group(CpuLoadCubit, () {
    late _ManualCpuLoad repository;

    setUp(() => repository = _ManualCpuLoad());
    tearDown(() => repository.controller.close());

    test('starts with no reading', () async {
      final cubit = CpuLoadCubit(repository: repository);
      expect(cubit.state, isNull);
      await cubit.close();
    });

    blocTest<CpuLoadCubit, int?>(
      'emits each new figure and nothing for a repeat',
      build: () => CpuLoadCubit(repository: repository),
      act: (_) async {
        for (final load in [23, 23, 40, 40, 7]) {
          repository.controller.add(load);
          await Future<void>.delayed(Duration.zero);
        }
      },
      expect: () => [23, 40, 7],
    );

    test('stops following the repository when closed', () async {
      final cubit = CpuLoadCubit(repository: repository);
      expect(repository.controller.hasListener, isTrue);
      await cubit.close();
      await Future<void>.delayed(Duration.zero);
      expect(repository.controller.hasListener, isFalse);
    });

    test('an unsupported repository leaves it unread', () async {
      final cubit = CpuLoadCubit(
        repository: const CpuLoadRepository.unsupported(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state, isNull);
      await cubit.close();
    });
  });
}
