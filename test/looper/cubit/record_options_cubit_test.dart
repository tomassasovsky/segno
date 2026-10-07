import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/looper/application/record_settings.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_options.dart';
import 'package:segno/looper/model/record_options_view_state.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockSettings extends Mock implements RecordSettings {}

class _Store extends FakeKeyValueStore {
  Completer<void>? writeGate;
  bool writeEntered = false;
  @override
  Future<void> setInt(String key, int value) async {
    if (key == 'looper.default_length_bars') {
      writeEntered = true;
      await writeGate?.future;
    }
    await super.setInt(key, value);
  }
}

void main() {
  group('length attempt acknowledgement', () {
    late _MockSettings owner;
    late StreamController<RecordOptions> states;
    late RecordLengthLifetime lifetime;
    late RecordOptionsCubit cubit;
    late List<Completer<RecordLengthOutcome>> writes;

    setUp(() {
      owner = _MockSettings();
      states = StreamController<RecordOptions>.broadcast(sync: true);
      lifetime = (sessionRevision: 0, mixGeneration: 0);
      writes = [];
      when(() => owner.state).thenReturn(
        const RecordOptions(recordLengthReady: true, defaultLengthBars: 4),
      );
      when(() => owner.stream).thenAnswer((_) => states.stream);
      when(() => owner.recordLengthLifetime).thenAnswer((_) => lifetime);
      Future<RecordLengthOutcome> write() {
        final pending = Completer<RecordLengthOutcome>();
        writes.add(pending);
        return pending.future;
      }

      when(() => owner.setDefaultLengthBars(any())).thenAnswer((_) => write());
      when(
        () => owner.setTrackRecordLength(
          channel: any(named: 'channel'),
          bars: any(named: 'bars'),
        ),
      ).thenAnswer((_) => write());
      cubit = RecordOptionsCubit(settings: owner);
    });
    tearDown(() async {
      await cubit.close();
      await states.close();
    });

    blocTest<RecordOptionsCubit, RecordOptionsViewState>(
      'refused candidate remains distinct from the accepted length',
      build: () => cubit,
      act: (cubit) async {
        final edit = cubit.setDefaultLengthBars(8);
        expect(cubit.state.lengthAttempt?.phase, LengthEditPhase.pending);
        expect(cubit.state.options.defaultLengthBars, 4);
        writes.single.complete(
          const RecordLengthOutcome(RecordLengthStatus.rejected),
        );
        await edit;
        expect(cubit.state.lengthAttempt?.phase, LengthEditPhase.refused);
        expect(cubit.state.lengthAttempt?.bars, 8);
        expect(cubit.state.options.defaultLengthBars, 4);
      },
    );

    for (final nextChannel in <int?>[null, 1]) {
      blocTest<RecordOptionsCubit, RecordOptionsViewState>(
        'older completion cannot replace a newer same-bars attempt '
        'on $nextChannel',
        build: () => cubit,
        act: (cubit) async {
          final first = cubit.setDefaultLengthBars(8);
          final firstId = cubit.state.lengthAttempt!.id;
          final second = nextChannel == null
              ? cubit.setDefaultLengthBars(8)
              : cubit.setTrackRecordLength(channel: nextChannel, bars: 8);
          final secondId = cubit.state.lengthAttempt!.id;
          expect(secondId, greaterThan(firstId));
          writes.first.complete(
            const RecordLengthOutcome(RecordLengthStatus.rejected),
          );
          await first;
          expect(cubit.state.lengthAttempt?.id, secondId);
          expect(cubit.state.lengthAttempt?.phase, LengthEditPhase.pending);
          writes.last.complete(
            const RecordLengthOutcome(RecordLengthStatus.applied),
          );
          await second;
          expect(cubit.state.lengthAttempt?.channel, nextChannel);
          expect(cubit.state.lengthAttempt?.phase, LengthEditPhase.applied);
        },
      );
    }

    for (final publish in [false, true]) {
      blocTest<RecordOptionsCubit, RecordOptionsViewState>(
        'replacement lifetime ignores old completion with publication $publish',
        build: () => cubit,
        act: (cubit) async {
          final edit = cubit.setDefaultLengthBars(8);
          lifetime = (sessionRevision: 1, mixGeneration: 1);
          if (publish) states.add(owner.state);
          writes.single.complete(
            const RecordLengthOutcome(RecordLengthStatus.rejected),
          );
          await edit;
          expect(cubit.state.lengthAttempt, isNull);
          expect(cubit.state.options.defaultLengthBars, 4);
        },
      );
    }
  });

  group('borrowed application owner', () {
    late _Store store;
    late LooperRepository repository;
    late RecordSettings owner;
    late RecordOptionsCubit cubit;
    setUp(() {
      store = _Store()..values['looper.mode'] = LooperMode.free.code;
      repository = LooperRepository(engine: FakeAudioEngine());
      owner = RecordSettings(
        repository: repository,
        settings: SettingsRepository(store: store),
      );
      cubit = RecordOptionsCubit(settings: owner);
    });
    tearDown(() async {
      await cubit.close();
      await owner.close();
      await repository.dispose();
    });

    blocTest<RecordOptionsCubit, RecordOptionsViewState>(
      'explicit Auto remains Custom until Use default removes membership',
      build: () => cubit,
      act: (cubit) async {
        await owner.load();
        await cubit.setTrackRecordLength(channel: 0, bars: 0);
        expect(cubit.state.options.trackLengthPresetOverrides, {0: 0});
        expect(cubit.state.lengthAttempt?.phase, LengthEditPhase.applied);
        await cubit.setTrackRecordLength(channel: 0, bars: null);
        expect(cubit.state.options.trackLengthPresetOverrides, isEmpty);
        expect(cubit.state.lengthAttempt?.bars, isNull);
      },
    );

    blocTest<RecordOptionsCubit, RecordOptionsViewState>(
      'closing and remounting preserves the core and excludes old attempts',
      build: () => cubit,
      act: (cubit) async {
        await owner.load();
        await cubit.setDefaultLengthBars(4);
        await cubit.close();
        expect((await owner.setDefaultLengthBars(8)).isOk, isTrue);
        final reopened = RecordOptionsCubit(settings: owner);
        expect(reopened.state.options, same(owner.state));
        expect(reopened.state.options.defaultLengthBars, 8);
        expect(reopened.state.lengthAttempt, isNull);
        await reopened.close();
      },
    );

    blocTest<RecordOptionsCubit, RecordOptionsViewState>(
      'an admitted edit completes after view disposal '
      'without late acknowledgement',
      build: () => cubit,
      act: (cubit) async {
        await owner.load();
        final gate = Completer<void>();
        store.writeGate = gate;
        final edit = cubit.setDefaultLengthBars(8);
        await pumpEventQueue();
        expect(store.writeEntered, isTrue);
        expect(owner.state.defaultLengthBars, 0);
        await cubit.close();
        final closedState = cubit.state;
        gate.complete();
        await edit;
        expect(cubit.state, same(closedState));
        expect(owner.state.defaultLengthBars, 8);
        expect((await owner.owner.flush()).isOk, isTrue);
      },
    );
  });
}
