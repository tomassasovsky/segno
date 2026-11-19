import 'dart:async';

import 'package:console_facts_client/console_facts_client.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/storage/cubit/storage_cubit.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/system/view/storage_system_tab.dart';
import 'package:segno/theme/theme.dart';
import 'package:settings_repository/settings_repository.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import '../../helpers/helpers.dart';

/// The fake, except that the housekeeping write is refused.
class _FailingDeleteFactsClient implements ConsoleFactsClient {
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

/// A client whose reads hang until [release] is called.
class _SlowFactsClient implements ConsoleFactsClient {
  @override
  Future<int> retiredBluetoothPairings() async => 0;

  final _gate = Completer<void>();
  final _inner = FakeConsoleFactsClient(latency: Duration.zero);

  void release() => _gate.complete();

  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() async {
    await _gate.future;
    return await _inner.storage();
  }

  @override
  Future<ConsoleFacts> facts() async {
    await _gate.future;
    return await _inner.facts();
  }

  @override
  Future<int> deleteCapturesOlderThan(int days) async => 0;
}

/// A client that throws every read, for the "cannot read the disk" face.
class _FailingFactsClient implements ConsoleFactsClient {
  @override
  Future<int> retiredBluetoothPairings() async => 0;

  @override
  bool get isSupported => true;

  @override
  Future<StorageUsage> storage() async => throw StateError('no disk');

  @override
  Future<ConsoleFacts> facts() async => throw StateError('no disk');

  @override
  Future<int> deleteCapturesOlderThan(int days) async => 0;
}

void main() {
  late ConsoleFactsCubit facts;
  late StorageCubit storage;

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Scaffold)));

  /// Mounts the Storage body with the cubits it reads.
  ///
  /// 1920x1080, deliberately: the face is drawn for that surface, and the
  /// default 800x600 view pushes the lower rows below the fold where a tap
  /// lands on nothing.
  Future<void> pump(WidgetTester tester, {ConsoleFactsClient? client}) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    facts = ConsoleFactsCubit(
      // Zero latency: even `Future.delayed(Duration.zero)` schedules a timer,
      // and a testWidgets body that awaits one without pumping waits forever.
      client: client ?? FakeConsoleFactsClient(latency: Duration.zero),
      settings: SettingsRepository(store: FakeKeyValueStore()),
    );
    final storageRepository = StorageRepository(
      guards: GuardRegistry(),
      client: FakeUsbStorageClient(),
      exportsRoot: () async => '/data/exports',
      volumeSpace: (_) => null,
    );
    storage = StorageCubit(
      repository: storageRepository,
      sampleRate: () => 48000,
    );

    // unawaited: awaiting a cubit close inside a testWidgets body deadlocks on
    // the binding's stream cancellation (flutter/flutter#139870).
    addTearDown(() => unawaited(facts.close()));
    addTearDown(() => unawaited(storage.close()));
    addTearDown(() => unawaited(storageRepository.dispose()));

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
            SpacingTheme.standard,
            NoticeTheme.standard,
          ],
        ),
        home: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: facts),
            BlocProvider.value(value: storage),
          ],
          child: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(19),
              child: StorageSystemTab(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('SYSTEM / storage', () {
    testWidgets('deleting captures asks first, and the figures afterwards '
        'come from a re-read', (tester) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      expect(find.text(l10n.storageGigabytes(6.2)), findsOneWidget);

      await tester.tap(find.byKey(const Key('system_storage_delete_captures')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('console_confirm_confirm')), findsOneWidget);

      // Backing out changes nothing.
      await tester.tap(find.byKey(const Key('console_confirm_cancel')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.storageGigabytes(6.2)), findsOneWidget);

      await tester.tap(find.byKey(const Key('system_storage_delete_captures')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();

      // The fake mutates its own figures, so this number could not have been
      // guessed by subtracting anything the face already held.
      expect(find.text(l10n.storageGigabytes(6.2)), findsNothing);
      expect(find.text(l10n.storageGigabytes(2.1)), findsOneWidget);
    });

    testWidgets('the volumes and safe eject open the tab, and there is no '
        '"Export everything" row any more', (tester) async {
      await pump(tester);

      // The pen's Storage page (31) heads the tab; the breakdown and the
      // housekeeping action follow it.
      expect(find.byKey(const Key('storage_internal_card')), findsOneWidget);
      expect(find.byKey(const Key('storage_usb_card_none')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('storage_internal_card'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('system_storage_card'))).dy,
        ),
      );
      // Never tappable on any real client, and no accepted screen has it.
      expect(find.byKey(const Key('system_storage_export')), findsNothing);
      expect(find.textContaining('Export everything'), findsNothing);
    });

    testWidgets('a housekeeping write that throws says so WHERE THE ACTION '
        'IS, and does not take the disk figures down with it', (tester) async {
      await pump(tester, client: _FailingDeleteFactsClient());
      final l10n = l10nOf(tester);

      await tester.scrollUntilVisible(
        find.byKey(const Key('system_storage_delete_captures')),
        200,
      );
      await tester.tap(find.byKey(const Key('system_storage_delete_captures')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('console_confirm_confirm')));
      await tester.pumpAndSettle();

      // A refused WRITE is not an unreadable disk. The five figures were
      // measured and are still true.
      expect(find.byKey(const Key('system_storage_card')), findsOneWidget);
      expect(find.text(l10n.storageUnknown), findsNothing);
      expect(facts.state.hasStorage, isTrue);

      // And the failure is named, at the top of the list the action lives in.
      expect(
        find.byKey(const Key('system_storage_action_failed')),
        findsOneWidget,
      );
      expect(facts.state.busy, isFalse);
    });

    testWidgets('nothing is claimed while the read is still in flight', (
      tester,
    ) async {
      final client = _SlowFactsClient();
      await pump(tester, client: client);
      final l10n = l10nOf(tester);

      // Mid-read: an answer that has not arrived is not an answer of no.
      expect(find.text(l10n.storageUnknown), findsNothing);
      expect(find.byKey(const Key('system_storage_card')), findsNothing);

      client.release();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('system_storage_card')), findsOneWidget);
    });

    testWidgets('every readout of the breakdown is drawn, not just the two '
        "the golden happens to frame; free space is the Internal card's "
        'alone', (tester) async {
      await pump(tester);
      final l10n = l10nOf(tester);

      for (final (key, figure) in const [
        (Key('system_storage_sessions'), 41.6),
        (Key('system_storage_captures'), 6.2),
        (Key('system_storage_plugins'), 1.1),
        (Key('system_storage_system'), 4.7),
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key');
        expect(
          find.text(l10n.storageGigabytes(figure)),
          findsOneWidget,
          reason: '$key reads $figure GB',
        );
      }
      expect(find.text(l10n.storagePluginsSubtitle(103)), findsOneWidget);
      // The breakdown's own free figure, read once on open, would disagree
      // with the card's, read every few seconds (#1217 review).
      expect(find.byKey(const Key('system_storage_free')), findsNothing);
      expect(find.text(l10n.storageGigabytes(12.4)), findsNothing);
    });

    testWidgets('a build that cannot read the disk says so and draws no '
        'rows — zeroes as facts would be worse', (tester) async {
      await pump(tester, client: _FailingFactsClient());
      final l10n = l10nOf(tester);

      expect(find.text(l10n.storageUnknown), findsOneWidget);
      expect(find.byKey(const Key('system_storage_card')), findsNothing);
      expect(find.text(l10n.storageGigabytes(0)), findsNothing);
    });
  });
}
