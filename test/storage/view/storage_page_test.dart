import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/storage/cubit/storage_cubit.dart';
import 'package:segno/storage/view/storage_page.dart';
import 'package:segno/storage/view/storage_volume_card.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

import '../../helpers/helpers.dart';
import '../helpers/storage_rig.dart';

void main() {
  group(StoragePage, () {
    late StorageRig rig;
    late StorageCubit cubit;
    late List<String> opened;

    setUp(() => opened = []);

    Future<AppLocalizations> pump(
      WidgetTester tester, {
      List<RemovableVolumeRecord> volumes = const [],
      void Function(StorageRig rig)? arrange,
      bool page = true,
    }) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      rig = StorageRig(volumes: volumes);
      for (final record in volumes) {
        rig.spaces[mountPoint(record.generation)] = const VolumeSpace(
          totalBytes: usbTotal,
          freeBytes: usbFree,
        );
      }
      arrange?.call(rig);
      cubit = StorageCubit(repository: rig.repository, sampleRate: () => 48000);
      // unawaited: awaiting a close inside a testWidgets body deadlocks on the
      // binding's stream cancellation (flutter/flutter#139870).
      addTearDown(() => unawaited(cubit.close()));
      addTearDown(() => unawaited(rig.dispose()));
      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Scaffold(
            body: SingleChildScrollView(
              child: page
                  ? StoragePage(onOpenLibrary: () => opened.add('library'))
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return AppLocalizations.of(tester.element(find.byType(Scaffold)));
    }

    Finder inCard(int generation, Finder finder) => find.descendant(
      of: find.byKey(Key('storage_usb_card_$generation')),
      matching: finder,
    );

    testWidgets('no drive: Not connected, and how to get one', (tester) async {
      final l10n = await pump(tester);

      final card = find.byKey(const Key('storage_usb_card_none'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text(l10n.storageUsbTitle)),
        findsOneWidget,
      );
      expect(find.text(l10n.storageUsbNotConnected), findsOneWidget);
      expect(find.text(l10n.storageUsbConnectHint), findsOneWidget);
      expect(find.byKey(const Key('storage_eject')), findsNothing);
    });

    testWidgets('Internal at the pen numbers: 64.0 GB free of 128 GB, 60 hr '
        '45 min at 48 kHz 24-bit stereo, the reserve note, no '
        'banner', (tester) async {
      final l10n = await pump(tester);

      final internal = find.byKey(const Key('storage_internal_card'));
      expect(
        find.descendant(of: internal, matching: find.text('64.0 GB free')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: internal, matching: find.text('of 128 GB')),
        findsOneWidget,
      );
      expect(find.text(l10n.storageInternalSubtitle), findsOneWidget);
      expect(
        find.text('60 hr 45 min recording remaining · estimated'),
        findsOneWidget,
      );
      expect(find.text('48 kHz · 24-bit · Stereo'), findsOneWidget);
      expect(
        find.text(
          'Internal storage · 1.0 GB reserved. Extra recordings and Undo '
          'audio use more space.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('storage_low_space_banner')), findsNothing);
      final bar = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: internal,
          matching: find.byKey(StorageCapacity.barKey),
        ),
      );
      expect(bar.value, closeTo(0.5, 1e-9), reason: 'the used half');
    });

    testWidgets('0.2 GB free: the low-space banner and No recording '
        'space', (tester) async {
      final l10n = await pump(
        tester,
        arrange: (rig) => rig.internal(free: 200000000),
      );

      expect(find.byKey(const Key('storage_low_space_banner')), findsOneWidget);
      expect(find.text(l10n.storageLowInternal), findsOneWidget);
      expect(find.text(l10n.storageNoRecordingSpace), findsOneWidget);
      expect(find.text('0.2 GB free'), findsOneWidget);
    });

    testWidgets('unknown Internal: Remaining time unavailable, Capacity '
        'unavailable, and no banner', (tester) async {
      final l10n = await pump(tester, arrange: (rig) => rig.internal());

      expect(find.text(l10n.storageRecordingTimeUnavailable), findsOneWidget);
      expect(find.text(l10n.storageCapacityUnavailable), findsOneWidget);
      expect(find.byKey(const Key('storage_low_space_banner')), findsNothing);
    });

    testWidgets('a mounted 32 GB SEGNO USB: 24.2 GB free, of 32 GB, and '
        'Eject; no Browse until the Library can open at a drive', (
      tester,
    ) async {
      await pump(
        tester,
        volumes: [
          usbRecord(1),
          usbRecord(2, status: RemovableVolumeRecordStatus.readOnly),
        ],
      );

      expect(inCard(1, find.text('SEGNO USB')), findsOneWidget);
      expect(inCard(1, find.text('24.2 GB free')), findsOneWidget);
      expect(inCard(1, find.text('of 32 GB')), findsOneWidget);
      expect(inCard(1, find.byKey(const Key('storage_eject'))), findsOneWidget);
      // A Browse that opened Internal would show the wrong files as the
      // drive's (#1217 review).
      expect(find.text('Browse'), findsNothing);
      expect(
        inCard(2, find.byKey(const Key('storage_eject'))),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('storage_open_library')));
      expect(opened, ['library']);
    });

    testWidgets('Eject is set at 700, as the pen draws it', (tester) async {
      await pump(tester, volumes: [usbRecord(1)]);

      final label = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('storage_eject')),
          matching: find.byType(RichText),
        ),
      );
      expect(label.text.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('Eject: Ejecting… with Cancel, then Safe to remove and the '
        'reassurance', (tester) async {
      final l10n = await pump(tester, volumes: [usbRecord(1)]);

      await tester.tap(find.byKey(const Key('storage_eject')));
      await tester.pumpAndSettle();

      expect(inCard(1, find.text(l10n.storageUsbEjecting)), findsOneWidget);
      expect(
        inCard(1, find.byKey(const Key('storage_eject_cancel'))),
        findsOneWidget,
      );
      expect(find.byKey(const Key('storage_eject')), findsNothing);
      expect(rig.client.pendingRequests, {'req-1': 1});

      rig.client.settleEject('req-1', ok: true);
      await tester.pumpAndSettle();

      expect(inCard(1, find.text(l10n.storageUsbSafeToRemove)), findsOneWidget);
      expect(
        inCard(1, find.text(l10n.storageUsbSafeToRemoveBody)),
        findsOneWidget,
      );
      expect(find.byKey(const Key('storage_eject_cancel')), findsNothing);
    });

    testWidgets('a refused eject says so under the drive, and Eject is there '
        'to try again', (tester) async {
      final l10n = await pump(tester, volumes: [usbRecord(1)]);

      await tester.tap(find.byKey(const Key('storage_eject')));
      await tester.pumpAndSettle();
      rig.client.settleEject('req-1', ok: false, reason: 'busy');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('storage_eject_failed')), findsOneWidget);
      expect(find.text(l10n.storageEjectFailed), findsOneWidget);
      expect(inCard(1, find.text('SEGNO USB')), findsOneWidget);

      await tester.tap(find.byKey(const Key('storage_eject')));
      await tester.pumpAndSettle();
      expect(rig.client.pendingRequests, {'req-2': 1});
      expect(find.byKey(const Key('storage_eject_failed')), findsNothing);
      rig.client.settleEject('req-2', ok: true);
      await tester.pumpAndSettle();
    });

    testWidgets('Cancel withdraws the request and the drive stays', (
      tester,
    ) async {
      await pump(tester, volumes: [usbRecord(1)]);

      await tester.tap(find.byKey(const Key('storage_eject')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('storage_eject_cancel')));
      await tester.pumpAndSettle();

      expect(rig.client.pendingRequests, isEmpty);
      expect(inCard(1, find.text('SEGNO USB')), findsOneWidget);
      expect(find.byKey(const Key('storage_eject')), findsOneWidget);
      expect(find.byKey(const Key('storage_eject_failed')), findsNothing);
    });

    testWidgets('a Cancel after the helper took the eject drops Cancel and '
        'says the eject cannot be stopped', (tester) async {
      final l10n = await pump(tester, volumes: [usbRecord(1)]);

      await tester.tap(find.byKey(const Key('storage_eject')));
      await tester.pumpAndSettle();
      rig.client.take('req-1');
      await tester.tap(find.byKey(const Key('storage_eject_cancel')));
      await tester.pumpAndSettle();

      expect(inCard(1, find.text(l10n.storageUsbEjecting)), findsOneWidget);
      expect(find.byKey(const Key('storage_eject_cancel')), findsNothing);
      expect(find.text(l10n.storageEjectUnderway), findsOneWidget);

      rig.client.settleEject('req-1', ok: true);
      await tester.pumpAndSettle();
      expect(inCard(1, find.text(l10n.storageUsbSafeToRemove)), findsOneWidget);
      expect(find.byKey(const Key('storage_eject_underway')), findsNothing);
    });

    testWidgets('while a lease holds the drive Eject is disabled and the '
        'card names the work; a tap files nothing', (tester) async {
      final l10n = await pump(tester, volumes: [usbRecord(1)]);
      rig.repository
        ..acquire(const StorageDestination.removable(1), WritePurpose.copy)
        ..acquire(const StorageDestination.removable(1), WritePurpose.copy)
        ..acquire(
          const StorageDestination.removable(1),
          WritePurpose.recording,
        );
      // Leases have no event of their own; the next read (at most 5 s away
      // while the page is open) shows it.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      expect(
        inCard(
          1,
          find.text(
            l10n.storageUsbInUse(
              'SEGNO USB',
              '${l10n.storagePurposeCopy}, ${l10n.storagePurposeRecording}',
            ),
          ),
        ),
        findsOneWidget,
      );
      final eject = tester.widget<StorageCardButton>(
        find.byKey(const Key('storage_eject')),
      );
      expect(eject.onPressed, isNull);

      await tester.tap(
        find.byKey(const Key('storage_eject')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(rig.client.pendingRequests, isEmpty);
    });

    testWidgets('read-only, unsupported, unformatted and failed drives say '
        'what they are, with nothing to eject but the mounted one', (
      tester,
    ) async {
      final l10n = await pump(
        tester,
        volumes: [
          usbRecord(1, status: RemovableVolumeRecordStatus.readOnly),
          usbRecord(
            2,
            label: '',
            fsType: 'hfsplus',
            status: RemovableVolumeRecordStatus.unsupported,
            mounted: false,
          ),
          usbRecord(
            3,
            fsType: 'none',
            status: RemovableVolumeRecordStatus.unsupported,
            mounted: false,
          ),
          usbRecord(
            4,
            status: RemovableVolumeRecordStatus.mountFailed,
            mounted: false,
          ),
          usbRecord(
            5,
            fsType: 'btrfs',
            status: RemovableVolumeRecordStatus.unsupported,
            mounted: false,
          ),
          usbRecord(
            6,
            fsType: 'zfs',
            status: RemovableVolumeRecordStatus.unsupported,
            mounted: false,
          ),
        ],
      );

      expect(
        inCard(1, find.text(l10n.storageUsbReadOnly('SEGNO USB'))),
        findsOneWidget,
      );
      expect(inCard(1, find.text('24.2 GB free')), findsOneWidget);
      expect(inCard(1, find.byKey(const Key('storage_eject'))), findsOneWidget);
      expect(inCard(2, find.text(l10n.storageUsbUnnamed)), findsOneWidget);
      expect(
        inCard(
          2,
          find.text("HFS+ isn't supported. Format the drive as exFAT."),
        ),
        findsOneWidget,
      );
      expect(inCard(3, find.text(l10n.storageUsbUnformatted)), findsOneWidget);
      expect(inCard(4, find.text(l10n.storageUsbMountFailed)), findsOneWidget);
      expect(
        inCard(5, find.text(l10n.storageUsbUnsupported('Btrfs'))),
        findsOneWidget,
      );
      expect(
        inCard(6, find.text(l10n.storageUsbUnsupported('ZFS'))),
        findsOneWidget,
      );
      for (final g in [2, 3, 4, 5, 6]) {
        expect(inCard(g, find.byType(StorageCardButton)), findsNothing);
      }
    });

    testWidgets('a mounted drive that cannot be measured says so', (
      tester,
    ) async {
      final l10n = await pump(
        tester,
        volumes: [usbRecord(1)],
        arrange: (rig) => rig.spaces.remove(mountPoint(1)),
      );
      expect(
        inCard(1, find.text(l10n.storageCapacityUnavailable)),
        findsOneWidget,
      );
    });

    testWidgets('capacity is read on open and every 5 s while the page is '
        'up, and the timer goes with the page', (tester) async {
      await pump(tester, page: false);
      final closed = rig.reads;
      await tester.pump(const Duration(seconds: 30));
      expect(rig.reads, closed, reason: 'no page, no periodic read');

      await tester.pumpApp(
        BlocProvider.value(
          value: cubit,
          child: Scaffold(
            body: SingleChildScrollView(
              child: StoragePage(onOpenLibrary: () {}),
            ),
          ),
        ),
      );
      await tester.pump();
      final opened = rig.reads;
      expect(opened, greaterThan(closed), reason: 'a read on open');

      await tester.pump(const Duration(seconds: 5));
      expect(rig.reads, greaterThan(opened), reason: 'a read at 5 s');

      await tester.pumpApp(const SizedBox.shrink());
      final gone = rig.reads;
      await tester.pump(const Duration(seconds: 30));
      expect(rig.reads, gone, reason: 'the timer left with the page');
    });
  });
}
