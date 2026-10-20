import 'package:bloc_test/bloc_test.dart';
import 'package:console_facts_client/console_facts_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

/// A client that reads fine and refuses every write.
class _FailingWriteClient implements ConsoleFactsClient {
  @override
  Future<int> retiredBluetoothPairings() async => 0;

  final _inner = FakeConsoleFactsClient(latency: Duration.zero);

  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() => _inner.storage();

  @override
  Future<ConsoleFacts> facts() => _inner.facts();

  @override
  Future<int> deleteCapturesOlderThan(int days) async =>
      throw StateError('read-only');
}

/// A client that throws every read.
class _FailingClient implements ConsoleFactsClient {
  @override
  Future<int> retiredBluetoothPairings() async => 0;

  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() async => throw StateError('no disk');

  @override
  Future<ConsoleFacts> facts() async => throw StateError('no disk');

  @override
  Future<int> deleteCapturesOlderThan(int days) async =>
      throw StateError('no disk');
}

void main() {
  late SettingsRepository settings;

  ConsoleFactsCubit build({ConsoleFactsClient? client}) => ConsoleFactsCubit(
    client: client ?? FakeConsoleFactsClient(latency: Duration.zero),
    settings: settings,
  );

  setUp(() => settings = SettingsRepository(store: FakeKeyValueStore()));

  group('ConsoleFactsCubit', () {
    test('an unsupported build says so before anything is read', () {
      final cubit = ConsoleFactsCubit(
        client: const UnsupportedConsoleFactsClient(),
        settings: settings,
      );
      addTearDown(cubit.close);
      expect(cubit.state.supported, isFalse);
      expect(cubit.state.hasStorage, isFalse);
    });

    blocTest<ConsoleFactsCubit, ConsoleFactsState>(
      'load reads the disk and the box',
      build: build,
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(cubit.state.status, ConsoleFactsStatus.ready);
        expect(cubit.state.hasStorage, isTrue);
        expect(cubit.state.facts.serial, 'VMP-16-0042');
      },
    );

    blocTest<ConsoleFactsCubit, ConsoleFactsState>(
      'a read that throws reports failure rather than zeroes drawn as facts',
      build: () => build(client: _FailingClient()),
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(cubit.state.status, ConsoleFactsStatus.failed);
        expect(cubit.state.hasStorage, isFalse);
      },
    );

    test('the housekeeping action re-reads rather than modelling its own '
        'effect', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();
      final before = cubit.state.storage.captureBytes;

      await cubit.deleteCapturesOlderThan(30);

      // The figure came back off the client, not off arithmetic here.
      expect(cubit.state.storage.captureBytes, lessThan(before));
      expect(cubit.state.status, ConsoleFactsStatus.ready);
      expect(cubit.state.busy, isFalse);
    });

    test('a housekeeping write that throws does NOT invalidate a good '
        'read', () async {
      final cubit = build(client: _FailingWriteClient());
      addTearDown(cubit.close);
      await cubit.load();
      expect(cubit.state.hasStorage, isTrue);

      await cubit.deleteCapturesOlderThan(30);

      // The figures were measured; the WRITE is what failed.
      expect(cubit.state.hasStorage, isTrue);
      expect(cubit.state.storage.captureBytes, greaterThan(0));
      expect(cubit.state.actionFailed, isTrue);
      expect(cubit.state.busy, isFalse);

      // The next good read clears it.
      await cubit.load();
      expect(cubit.state.actionFailed, isFalse);
    });

    test('a read that throws IS the case where nothing can be drawn', () async {
      final cubit = build(client: _FailingClient());
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.status, ConsoleFactsStatus.failed);
      expect(cubit.state.settled, isTrue);
      expect(cubit.state.hasStorage, isFalse);
    });

    test('a read in flight is not settled — it has not answered yet', () async {
      final cubit = build();
      addTearDown(cubit.close);
      expect(cubit.state.settled, isFalse);

      await cubit.load();
      expect(cubit.state.settled, isTrue);
    });

    test('the given name keys off the serial, and an empty one hands the box '
        'back its shipped name', () async {
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.rename('  Stage left  ');
      expect(cubit.state.consoleName, 'Stage left');
      expect(await settings.loadConsoleName('VMP-16-0042'), 'Stage left');

      await cubit.rename('');
      expect(cubit.state.consoleName, 'VAMP 16');
      expect(await settings.loadConsoleName('VMP-16-0042'), isNull);
    });

    test('a build with no serial has nothing to hang a name off', () async {
      final cubit = build(client: const UnsupportedConsoleFactsClient());
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.rename('Stage left');

      expect(cubit.state.consoleName, isEmpty);
    });

    test('a persisted name is restored on the next load', () async {
      await settings.saveConsoleName('VMP-16-0042', 'Stage left');
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.consoleName, 'Stage left');
    });
  });
}
