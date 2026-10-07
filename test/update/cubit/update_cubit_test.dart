import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:update_repository/update_repository.dart';

class _MockUpdateRepository extends Mock implements UpdateRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

final _v1 = Version.parse('0.1.0');
final _v2Number = Version.parse('0.2.0');
final _v2 = UpdateManifest(
  version: _v2Number,
  bundle: 'segno-appliance-0.2.0.raucb',
  sha256: 's',
  channel: 'experimental',
);

void main() {
  late UpdateRepository updates;
  late SettingsRepository settings;

  setUpAll(() {
    registerFallbackValue(_v2);
    registerFallbackValue(Version.none);
  });

  setUp(() {
    updates = _MockUpdateRepository();
    settings = _MockSettingsRepository();
    // Sensible defaults; individual tests override.
    when(() => updates.isSupported).thenReturn(true);
    when(() => updates.channel).thenReturn('experimental');
    when(() => updates.currentVersion()).thenAnswer((_) async => _v1);
    when(() => updates.stagedVersion()).thenAnswer((_) async => Version.none);
    when(() => updates.checkForUpdate()).thenAnswer((_) async => null);
    when(() => settings.loadUpdateAutoCheck()).thenAnswer((_) async => true);
    when(() => settings.loadUpdateChannel()).thenAnswer((_) async => null);
    when(
      () => settings.loadDismissedUpdateVersions(),
    ).thenAnswer((_) async => const {});
    when(
      () => settings.saveUpdateAutoCheck(value: any(named: 'value')),
    ).thenAnswer((_) async {});
    when(() => settings.saveUpdateChannel(any())).thenAnswer((_) async {});
    when(
      () => settings.saveDismissedUpdateVersions(any()),
    ).thenAnswer((_) async {});
    when(() => updates.setChannel(any())).thenAnswer((_) async {});
    when(
      () => updates.recover(),
    ).thenAnswer((_) async => const UpdateRecovery());
    when(() => updates.clearInterrupted()).thenAnswer((_) async {});
    when(() => settings.loadUpdateRollback()).thenAnswer((_) async => null);
    when(
      () => settings.saveUpdateRollback(
        attempted: any(named: 'attempted'),
        restored: any(named: 'restored'),
      ),
    ).thenAnswer((_) async {});
    when(() => settings.clearUpdateRollback()).thenAnswer((_) async {});
  });

  UpdateCubit build() => UpdateCubit(updates: updates, settings: settings);

  group('load', () {
    blocTest<UpdateCubit, UpdateState>(
      'restores prefs and auto-checks when enabled + supported',
      setUp: () {
        when(
          () => settings.loadDismissedUpdateVersions(),
        ).thenAnswer((_) async => {Version.parse('0.5.0')});
        when(() => updates.checkForUpdate()).thenAnswer((_) async => _v2);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.supported, 'supported', true)
            .having((s) => s.channel, 'channel', 'experimental')
            .having((s) => s.currentVersion, 'currentVersion', _v1)
            .having((s) => s.autoCheck, 'autoCheck', true)
            .having((s) => s.dismissed, 'dismissed', {Version.parse('0.5.0')}),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.available)
            .having((s) => s.available, 'available', _v2),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'does not auto-check when the preference is off',
      setUp: () => when(
        () => settings.loadUpdateAutoCheck(),
      ).thenAnswer((_) async => false),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>().having((s) => s.autoCheck, 'autoCheck', false),
      ],
      verify: (_) => verifyNever(() => updates.checkForUpdate()),
    );

    blocTest<UpdateCubit, UpdateState>(
      'does not auto-check on an unsupported platform',
      setUp: () => when(() => updates.isSupported).thenReturn(false),
      build: build,
      act: (cubit) => cubit.load(),
      verify: (_) => verifyNever(() => updates.checkForUpdate()),
    );

    test('is idempotent across repeated calls', () async {
      final cubit = build();
      await cubit.load();
      await cubit.load();
      // load() once + check()'s currentVersion() once; second load is a no-op.
      verify(() => updates.currentVersion()).called(2);
      verify(() => updates.checkForUpdate()).called(1);
    });
  });

  group('check', () {
    blocTest<UpdateCubit, UpdateState>(
      'emits upToDate when nothing newer is published',
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.upToDate,
        ),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'emits staged when a prior stage is still ahead of current',
      setUp: () {
        when(() => updates.checkForUpdate()).thenAnswer((_) async => null);
        when(() => updates.stagedVersion()).thenAnswer((_) async => _v2Number);
      },
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.staged)
            .having((s) => s.available?.version, 'available', _v2Number),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'emits error when the check throws',
      setUp: () => when(
        () => updates.checkForUpdate(),
      ).thenThrow(Exception('offline')),
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.error)
            .having((s) => s.errorMessage, 'errorMessage', contains('offline')),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op on an unsupported platform',
      setUp: () => when(() => updates.isSupported).thenReturn(false),
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => const <UpdateState>[],
    );
  });

  group('startDownload', () {
    blocTest<UpdateCubit, UpdateState>(
      'streams progress then reaches staged',
      seed: () => UpdateState(available: _v2),
      setUp: () => when(
        () => updates.downloadAndStage(_v2),
      ).thenAnswer((_) => Stream.fromIterable([0.5, 1.0])),
      build: build,
      act: (cubit) => cubit.startDownload(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.downloading)
            .having((s) => s.progress, 'progress', 0),
        isA<UpdateState>().having((s) => s.progress, 'progress', 0.5),
        isA<UpdateState>().having((s) => s.progress, 'progress', 1.0),
        isA<UpdateState>().having((s) => s.phase, 'phase', UpdatePhase.staged),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op when nothing is available',
      build: build,
      act: (cubit) => cubit.startDownload(),
      expect: () => const <UpdateState>[],
    );

    blocTest<UpdateCubit, UpdateState>(
      'emits error when staging fails',
      seed: () => UpdateState(available: _v2),
      setUp: () => when(
        () => updates.downloadAndStage(_v2),
      ).thenAnswer((_) => Stream.error(Exception('sha mismatch'))),
      build: build,
      act: (cubit) => cubit.startDownload(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.downloading,
        ),
        isA<UpdateState>().having((s) => s.phase, 'phase', UpdatePhase.error),
      ],
    );
  });

  group('cancelDownload', () {
    test('kills the helper, forgets the attempt its kill left, and returns '
        'to the offer with nothing staged', () async {
      var cancelled = false;
      final helper = StreamController<double>(
        onCancel: () => cancelled = true,
      );
      when(
        () => updates.downloadAndStage(_v2),
      ).thenAnswer((_) => helper.stream);
      final cubit = build()..emit(UpdateState(available: _v2));

      final download = cubit.startDownload();
      helper.add(0.2);
      await Future<void>.delayed(Duration.zero);
      expect(cubit.state.phase, UpdatePhase.downloading);
      expect(cubit.state.progress, 0.2);

      await cubit.cancelDownload();
      // The download's own future ends with the cancel rather than hanging.
      await download;

      expect(cancelled, isTrue);
      verify(() => updates.clearInterrupted()).called(1);
      expect(cubit.state.phase, UpdatePhase.available);
      expect(cubit.state.available, _v2);
      expect(cubit.state.progress, 0);
      await cubit.close();
    });

    test('is refused once RAUC is writing the slot', () async {
      var cancelled = false;
      final helper = StreamController<double>(
        onCancel: () => cancelled = true,
      );
      when(
        () => updates.downloadAndStage(_v2),
      ).thenAnswer((_) => helper.stream);
      final cubit = build()..emit(UpdateState(available: _v2));
      unawaited(cubit.startDownload());
      helper.add(0.6);
      await Future<void>.delayed(Duration.zero);

      await cubit.cancelDownload();

      expect(cancelled, isFalse);
      expect(cubit.state.phase, UpdatePhase.downloading);
      verifyNever(() => updates.clearInterrupted());
      await helper.close();
      await cubit.close();
    });

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op with nothing downloading',
      build: build,
      act: (cubit) => cubit.cancelDownload(),
      expect: () => const <UpdateState>[],
      verify: (_) => verifyNever(() => updates.clearInterrupted()),
    );

    test('closing the cubit kills a download in flight', () async {
      var cancelled = false;
      final helper = StreamController<double>(
        onCancel: () => cancelled = true,
      );
      when(
        () => updates.downloadAndStage(_v2),
      ).thenAnswer((_) => helper.stream);
      final cubit = build()..emit(UpdateState(available: _v2));
      unawaited(cubit.startDownload());
      await Future<void>.delayed(Duration.zero);

      await cubit.close();

      expect(cancelled, isTrue);
    });
  });

  group('an interrupted install', () {
    final paused = Version.parse('0.2.0');

    blocTest<UpdateCubit, UpdateState>(
      'loads as interrupted with nothing staged, and waits rather than '
      'checking over it',
      setUp: () => when(
        () => updates.recover(),
      ).thenAnswer((_) async => UpdateRecovery(interrupted: paused)),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.interrupted)
            .having((s) => s.interrupted, 'interrupted', paused),
      ],
      verify: (_) {
        verifyNever(() => updates.checkForUpdate());
        verifyNever(() => updates.clearInterrupted());
      },
    );

    blocTest<UpdateCubit, UpdateState>(
      'is moot when a build was staged since',
      setUp: () {
        when(
          () => updates.recover(),
        ).thenAnswer((_) async => UpdateRecovery(interrupted: paused));
        when(() => updates.stagedVersion()).thenAnswer((_) async => _v2Number);
        when(
          () => settings.loadUpdateAutoCheck(),
        ).thenAnswer((_) async => false);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.idle)
            .having((s) => s.interrupted, 'interrupted', isNull),
      ],
      verify: (_) => verify(() => updates.clearInterrupted()).called(1),
    );

    blocTest<UpdateCubit, UpdateState>(
      'Retry forgets the attempt, checks, and starts the download',
      seed: () => UpdateState(
        supported: true,
        phase: UpdatePhase.interrupted,
        interrupted: paused,
      ),
      setUp: () {
        when(() => updates.checkForUpdate()).thenAnswer((_) async => _v2);
        when(
          () => updates.downloadAndStage(_v2),
        ).thenAnswer((_) => Stream.fromIterable([1.0]));
      },
      build: build,
      act: (cubit) => cubit.retryInterrupted(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.checking)
            .having((s) => s.interrupted, 'interrupted', isNull),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.available,
        ),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.downloading,
        ),
        isA<UpdateState>().having((s) => s.progress, 'progress', 1.0),
        isA<UpdateState>().having((s) => s.phase, 'phase', UpdatePhase.staged),
      ],
      verify: (_) {
        verify(() => updates.clearInterrupted()).called(1);
        verify(() => updates.downloadAndStage(_v2)).called(1);
      },
    );

    blocTest<UpdateCubit, UpdateState>(
      'Retry that finds nothing newer shows that instead',
      seed: () => UpdateState(
        supported: true,
        phase: UpdatePhase.interrupted,
        interrupted: paused,
      ),
      build: build,
      act: (cubit) => cubit.retryInterrupted(),
      skip: 1,
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.upToDate,
        ),
      ],
      verify: (_) => verifyNever(() => updates.downloadAndStage(any())),
    );

    test('a second Retry press while the first runs does nothing', () async {
      final checked = Completer<UpdateManifest?>();
      when(() => updates.checkForUpdate()).thenAnswer((_) => checked.future);
      final cubit = build()
        ..emit(
          UpdateState(
            supported: true,
            phase: UpdatePhase.interrupted,
            interrupted: paused,
          ),
        );

      final first = cubit.retryInterrupted();
      await cubit.retryInterrupted();
      checked.complete(null);
      await first;

      verify(() => updates.checkForUpdate()).called(1);
      verify(() => updates.clearInterrupted()).called(1);
      await cubit.close();
    });

    blocTest<UpdateCubit, UpdateState>(
      'Check instead of Retry settles the attempt too',
      seed: () => UpdateState(
        supported: true,
        phase: UpdatePhase.interrupted,
        interrupted: paused,
      ),
      build: build,
      act: (cubit) => cubit.check(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.checking)
            .having((s) => s.interrupted, 'interrupted', isNull),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.upToDate,
        ),
      ],
      verify: (_) => verify(() => updates.clearInterrupted()).called(1),
    );

    blocTest<UpdateCubit, UpdateState>(
      'switching channel settles the attempt too',
      seed: () => UpdateState(
        supported: true,
        channel: 'experimental',
        phase: UpdatePhase.interrupted,
        interrupted: paused,
      ),
      build: build,
      act: (cubit) => cubit.setExperimentalChannel(value: false),
      verify: (cubit) {
        verify(() => updates.clearInterrupted()).called(1);
        expect(cubit.state.interrupted, isNull);
      },
    );

    blocTest<UpdateCubit, UpdateState>(
      'Cancel forgets the attempt and goes back to Software updates',
      seed: () => UpdateState(
        supported: true,
        phase: UpdatePhase.interrupted,
        interrupted: paused,
      ),
      build: build,
      act: (cubit) => cubit.discardInterrupted(),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.idle)
            .having((s) => s.interrupted, 'interrupted', isNull),
      ],
      verify: (_) => verify(() => updates.clearInterrupted()).called(1),
    );
  });

  group('a rolled-back update', () {
    final staged = Version.parse('1.1.0');
    final installed = Version.parse('1.0.0');

    blocTest<UpdateCubit, UpdateState>(
      'tryboot-not-taken: a notice naming the staged and installed versions, '
      'saved so it outlives a restart',
      setUp: () {
        when(
          () => updates.currentVersion(),
        ).thenAnswer((_) async => installed);
        when(
          () => updates.recover(),
        ).thenAnswer((_) async => UpdateRecovery(rolledBack: staged));
        when(
          () => settings.loadUpdateAutoCheck(),
        ).thenAnswer((_) async => false);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.rollback,
          'rollback',
          (attempted: staged, restored: installed),
        ),
      ],
      verify: (_) => verify(
        () => settings.saveUpdateRollback(
          attempted: staged,
          restored: installed,
        ),
      ).called(1),
    );

    blocTest<UpdateCubit, UpdateState>(
      'already-running (no rollback reported): no notice',
      setUp: () => when(
        () => settings.loadUpdateAutoCheck(),
      ).thenAnswer((_) async => false),
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>().having((s) => s.rollback, 'rollback', isNull),
      ],
      verify: (_) => verifyNever(
        () => settings.saveUpdateRollback(
          attempted: any(named: 'attempted'),
          restored: any(named: 'restored'),
        ),
      ),
    );

    blocTest<UpdateCubit, UpdateState>(
      'an undismissed notice from an earlier start is still shown',
      setUp: () {
        when(
          () => settings.loadUpdateRollback(),
        ).thenAnswer((_) async => (attempted: staged, restored: installed));
        when(
          () => settings.loadUpdateAutoCheck(),
        ).thenAnswer((_) async => false);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.rollback,
          'rollback',
          (attempted: staged, restored: installed),
        ),
      ],
    );

    blocTest<UpdateCubit, UpdateState>(
      'a notice whose build is running now is dropped',
      setUp: () {
        when(() => updates.currentVersion()).thenAnswer((_) async => staged);
        when(
          () => settings.loadUpdateRollback(),
        ).thenAnswer((_) async => (attempted: staged, restored: installed));
        when(
          () => settings.loadUpdateAutoCheck(),
        ).thenAnswer((_) async => false);
      },
      build: build,
      act: (cubit) => cubit.load(),
      expect: () => [
        isA<UpdateState>().having((s) => s.rollback, 'rollback', isNull),
      ],
      verify: (_) => verify(() => settings.clearUpdateRollback()).called(1),
    );

    blocTest<UpdateCubit, UpdateState>(
      'dismissing clears it for good',
      seed: () =>
          UpdateState(rollback: (attempted: staged, restored: installed)),
      build: build,
      act: (cubit) => cubit.dismissRollback(),
      expect: () => [
        isA<UpdateState>().having((s) => s.rollback, 'rollback', isNull),
      ],
      verify: (_) => verify(() => settings.clearUpdateRollback()).called(1),
    );
  });

  group('dismiss', () {
    blocTest<UpdateCubit, UpdateState>(
      'adds the version and persists',
      seed: () => UpdateState(dismissed: {Version.parse('0.1.0')}),
      build: build,
      act: (cubit) => cubit.dismiss(_v2Number),
      expect: () => [
        isA<UpdateState>().having(
          (s) => s.dismissed,
          'dismissed',
          {Version.parse('0.1.0'), _v2Number},
        ),
      ],
      verify: (_) => verify(
        () => settings.saveDismissedUpdateVersions({
          Version.parse('0.1.0'),
          _v2Number,
        }),
      ).called(1),
    );

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op when already dismissed',
      seed: () => UpdateState(dismissed: {_v2Number}),
      build: build,
      act: (cubit) => cubit.dismiss(_v2Number),
      expect: () => const <UpdateState>[],
      verify: (_) =>
          verifyNever(() => settings.saveDismissedUpdateVersions(any())),
    );
  });

  group('setAutoCheck', () {
    blocTest<UpdateCubit, UpdateState>(
      'emits and persists the new value',
      seed: UpdateState.new,
      build: build,
      act: (cubit) => cubit.setAutoCheck(value: false),
      expect: () => [
        isA<UpdateState>().having((s) => s.autoCheck, 'autoCheck', false),
      ],
      verify: (_) =>
          verify(() => settings.saveUpdateAutoCheck(value: false)).called(1),
    );
  });

  group('setExperimentalChannel', () {
    blocTest<UpdateCubit, UpdateState>(
      'pins experimental, clears the prior offer, and re-checks',
      seed: () => UpdateState(
        supported: true,
        channel: 'production',
        phase: UpdatePhase.available,
        available: _v2,
      ),
      setUp: () {
        when(() => updates.channel).thenReturn('experimental');
        when(() => updates.checkForUpdate()).thenAnswer((_) async => _v2);
      },
      build: build,
      act: (cubit) => cubit.setExperimentalChannel(value: true),
      expect: () => [
        isA<UpdateState>()
            .having((s) => s.channel, 'channel', 'experimental')
            .having((s) => s.phase, 'phase', UpdatePhase.idle)
            .having((s) => s.available, 'available', isNull),
        isA<UpdateState>().having(
          (s) => s.phase,
          'phase',
          UpdatePhase.checking,
        ),
        isA<UpdateState>()
            .having((s) => s.phase, 'phase', UpdatePhase.available)
            .having((s) => s.available, 'available', _v2),
      ],
      verify: (_) {
        verify(() => updates.setChannel('experimental')).called(1);
        verify(() => settings.saveUpdateChannel('experimental')).called(1);
      },
    );

    blocTest<UpdateCubit, UpdateState>(
      'is a no-op while downloading',
      seed: () => const UpdateState(
        supported: true,
        channel: 'production',
        phase: UpdatePhase.downloading,
      ),
      build: build,
      act: (cubit) => cubit.setExperimentalChannel(value: true),
      expect: () => const <UpdateState>[],
      verify: (_) {
        verifyNever(() => updates.setChannel(any()));
        verifyNever(() => settings.saveUpdateChannel(any()));
      },
    );
  });

  group('load applies a saved channel', () {
    blocTest<UpdateCubit, UpdateState>(
      'calls setChannel before the first check',
      setUp: () {
        when(
          () => settings.loadUpdateChannel(),
        ).thenAnswer((_) async => 'experimental');
        when(() => updates.channel).thenReturn('experimental');
        when(
          () => settings.loadUpdateAutoCheck(),
        ).thenAnswer((_) async => false);
      },
      build: build,
      act: (cubit) => cubit.load(),
      verify: (_) => verify(() => updates.setChannel('experimental')).called(1),
    );
  });
}
