import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/model/record_options.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  late SettingsRepository settings;
  late LooperRepository repository;
  late StreamController<LooperState> looperStates;
  late int confirmedLength;

  setUp(() {
    settings = SettingsRepository(store: FakeKeyValueStore());
    repository = _MockLooperRepository();
    confirmedLength = 0;
    registerFallbackValue(LooperMode.multi);
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.recordLengthCaptureLocked).thenReturn(false);
    when(() => repository.lengthSettingsSettled).thenReturn(true);
    when(() => repository.lengthRecoveryRequired).thenReturn(false);
    when(
      () => repository.lengthSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(() => repository.trackLengthPresetOverrides).thenReturn({});
    when(() => repository.state).thenReturn(const LooperState());
    when(() => repository.lengthRestartIntent).thenAnswer(
      (_) => (
        defaultBars: confirmedLength,
        trackOverrides: <int, int>{},
        mode: LooperMode.multi,
      ),
    );
    when(
      () => repository.setLengthSettings(
        defaultBars: any(named: 'defaultBars'),
        overrides: any(named: 'overrides'),
        mode: any(named: 'mode'),
        released: any(named: 'released'),
      ),
    ).thenAnswer((call) {
      confirmedLength = call.namedArguments[#defaultBars] as int;
      return EngineResult.ok;
    });
    when(() => repository.sessionRevision).thenReturn(0);
    when(() => repository.sessionTransport).thenAnswer(
      (_) => TransportState(defaultLengthPresetBars: confirmedLength),
    );
    when(
      () => repository.settleLengthSettings(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.setRecDub(enabled: any(named: 'enabled')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setDefaultMultiple(multiple: any(named: 'multiple')),
    ).thenReturn(EngineResult.ok);
    when(() => repository.setDefaultLengthPreset(any())).thenAnswer((call) {
      confirmedLength = call.positionalArguments.single as int;
      return EngineResult.ok;
    });
    looperStates = StreamController<LooperState>.broadcast();
    when(() => repository.looperState).thenAnswer((_) => looperStates.stream);
  });

  tearDown(() => looperStates.close());

  RecordSettings build() =>
      RecordSettings(repository: repository, settings: settings);

  test(
    'failed ordinary startup still permits complete owner disposal',
    () async {
      final store = FakeKeyValueStore()..values['looper.rec_dub'] = 'broken';
      final owner = RecordSettings(
        repository: repository,
        settings: SettingsRepository(store: store),
      );
      final streamsDone = Future.wait([
        owner.stream.drain<void>(),
        owner.owner.failures.drain<void>(),
        owner.ordinaryRecordLengthChanges.drain<void>(),
      ]);
      final loading = owner.load();
      await expectLater(loading, throwsA(isA<TypeError>()));
      expect(looperStates.hasListener, isTrue);
      await owner.close();
      await streamsDone;
      expect(looperStates.hasListener, isFalse);
      await owner.close();
      await expectLater(loading, throwsA(isA<TypeError>()));
    },
  );

  group('RecordSettings', () {
    test('defaults to RecDub off', () {
      expect(build().state, const RecordOptions());
    });

    test('load restores persisted options and applies them', () async {
      await (() async {
        await settings.saveRecDub(value: true);
      })();
      final owner = build();
      addTearDown(owner.close);
      final states = <RecordOptions>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((RecordSettings cubit) => cubit.load())(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(
        states,
        (() => [
          const RecordOptions(recDub: true),
          const RecordOptions(recDub: true, recordLengthReady: true),
        ])(),
      );
      ((_) {
        verify(() => repository.setRecDub(enabled: true)).called(1);
      })(owner);
    });

    test('setRecDub emits, applies, and persists', () async {
      final owner = build();
      addTearDown(owner.close);
      final states = <RecordOptions>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((RecordSettings cubit) => cubit.setRecDub(value: true))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(states, (() => [const RecordOptions(recDub: true)])());
      await ((_) async {
        verify(() => repository.setRecDub(enabled: true)).called(1);
        expect(await settings.loadRecDub(), isTrue);
      })(owner);
    });

    test('setDefaultMultiple emits, applies, and persists', () async {
      final owner = build();
      addTearDown(owner.close);
      final states = <RecordOptions>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((RecordSettings cubit) => cubit.setDefaultMultiple(2))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(states, (() => [const RecordOptions(defaultMultiple: 2)])());
      await ((_) async {
        verify(() => repository.setDefaultMultiple(multiple: 2)).called(1);
        expect(await settings.loadDefaultMultiple(), 2);
      })(owner);
    });
    test(
      'setDefaultLengthBars emits, persists and applies the clamped default',
      () async {
        final owner = build();
        addTearDown(owner.close);
        final states = <RecordOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((RecordSettings cubit) => cubit.setDefaultLengthBars(80))(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(
          states,
          (() => [
            const RecordOptions(recordLengthReady: true),
            const RecordOptions(defaultLengthBars: 64, recordLengthReady: true),
          ])(),
        );
        await ((_) async {
          expect(await settings.loadDefaultLengthPreset(), 64);
          verify(
            () => repository.setLengthSettings(
              defaultBars: 64,
              overrides: any(named: 'overrides'),
              mode: any(named: 'mode'),
              released: any(named: 'released'),
            ),
          ).called(1);
        })(owner);
      },
    );

    test('late length refusal keeps the displayed and saved default', () async {
      (() => when(
        () => repository.settleLengthSettings(),
      ).thenAnswer((_) async => EngineResult.invalid))();
      final owner = build();
      addTearDown(owner.close);
      final states = <RecordOptions>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((RecordSettings cubit) => cubit.setDefaultLengthBars(8))(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      // A refused restore never publishes a ready length.
      expect(states.where((state) => state.recordLengthReady), isEmpty);
      await ((_) async =>
          expect(await settings.loadDefaultLengthPreset(), 0))(owner);
    });

    test(
      'an accepted length still persists after a rejected tap and RecDub edit',
      () async {
        final pending = Completer<EngineResult>();
        when(
          () => repository.setLengthSettings(
            defaultBars: any(named: 'defaultBars'),
            overrides: any(named: 'overrides'),
            mode: any(named: 'mode'),
            released: any(named: 'released'),
          ),
        ).thenAnswer((call) {
          final bars = call.namedArguments[#defaultBars] as int;
          return bars == 12 ? EngineResult.notReady : EngineResult.ok;
        });
        when(
          () => repository.settleLengthSettings(),
        ).thenAnswer((_) => pending.future);
        final cubit = build();
        addTearDown(cubit.close);

        // Initialize before withholding the transaction receipt.
        when(
          () => repository.settleLengthSettings(),
        ).thenAnswer((_) async => EngineResult.ok);
        await cubit.load();
        when(
          () => repository.settleLengthSettings(),
        ).thenAnswer((_) => pending.future);
        final accepted = cubit.setDefaultLengthBars(8);
        // In flight before the next tap, so the tap queues instead of
        // replacing it.
        await Future<void>.delayed(Duration.zero);
        final rejected = cubit.setDefaultLengthBars(12);
        await Future<void>.delayed(Duration.zero);
        await cubit.setRecDub(value: true);
        confirmedLength = 8;
        pending.complete(EngineResult.ok);
        await accepted;
        await rejected;

        expect(cubit.state.defaultLengthBars, 8);
        expect(cubit.state.recDub, isTrue);
        expect(await settings.loadDefaultLengthPreset(), 8);
        expect(await settings.loadRecDub(), isTrue);
      },
    );

    test(
      'follows the repository before load without overwriting saved defaults',
      () async {
        await (() => settings.saveRecDub(value: true))();
        final owner = build();
        addTearDown(owner.close);
        final states = <RecordOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((RecordSettings cubit) async {
          looperStates.add(const LooperState());
          await Future<void>.delayed(Duration.zero);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => [const RecordOptions()])());
        await ((_) async => expect(await settings.loadRecDub(), isTrue))(owner);
      },
    );

    test('explicit matching values still reach the repository', () async {
      final owner = build();
      addTearDown(owner.close);
      final states = <RecordOptions>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((RecordSettings cubit) async {
        await cubit.setRecDub(value: false);
        await cubit.setDefaultMultiple(0);
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(states, (() => [const RecordOptions()])());
      ((_) {
        verify(() => repository.setRecDub(enabled: false)).called(1);
        verify(() => repository.setDefaultMultiple(multiple: 0)).called(1);
      })(owner);
    });

    test(
      'refused edits preserve displayed and saved recording options',
      () async {
        await (() {
          when(
            () => repository.setRecDub(enabled: true),
          ).thenReturn(EngineResult.invalid);
          when(
            () => repository.setDefaultMultiple(multiple: 2),
          ).thenReturn(EngineResult.invalid);
        })();
        final owner = build();
        addTearDown(owner.close);
        final states = <RecordOptions>[];
        final subscription = owner.stream.listen(states.add);
        addTearDown(subscription.cancel);
        await ((RecordSettings cubit) async {
          await cubit.setRecDub(value: true);
          await cubit.setDefaultMultiple(2);
        })(owner);
        await Future<void>.delayed(Duration.zero);
        await owner.close();
        expect(states, (() => <RecordOptions>[])());
        await ((_) async {
          expect(await settings.loadRecDub(), isFalse);
          expect(await settings.loadDefaultMultiple(), 0);
        })(owner);
      },
    );

    test('follows recalled and reset recording defaults', () async {
      final owner = build();
      addTearDown(owner.close);
      final states = <RecordOptions>[];
      final subscription = owner.stream.listen(states.add);
      addTearDown(subscription.cancel);
      await ((_) async {
        looperStates.add(
          const LooperState(
            transport: TransportState(
              recDub: true,
              defaultMultiple: 3,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        looperStates.add(const LooperState());
        await Future<void>.delayed(Duration.zero);
      })(owner);
      await Future<void>.delayed(Duration.zero);
      await owner.close();
      expect(
        states,
        (() => [
          const RecordOptions(recDub: true, defaultMultiple: 3),
          const RecordOptions(),
        ])(),
      );
      await ((_) async {
        expect(await settings.loadRecDub(), isFalse);
        expect(await settings.loadDefaultMultiple(), 0);
      })(owner);
    });
  });
}
