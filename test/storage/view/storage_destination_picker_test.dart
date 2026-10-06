import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/storage/view/storage_destination_picker.dart';
import 'package:storage_repository/storage_repository.dart';

import '../../helpers/helpers.dart';

RemovableVolume _volume(
  int generation, {
  String label = 'SEGNO USB',
  RemovableVolumeStatus status = RemovableVolumeStatus.mounted,
  int? writeBytesPerSecond = 16777216,
  String fsType = 'exfat',
}) => RemovableVolume(
  generation: generation,
  fingerprint: 'fp-$generation',
  label: label,
  fsType: fsType,
  sizeBytes: 32000000000,
  status: status,
  mountPoint: '/run/media/segno/$generation-$label',
  writeBytesPerSecond: writeBytesPerSecond,
);

void main() {
  group(StorageDestinationPicker, () {
    late List<StorageDestination> chosen;
    late int connects;

    setUp(() {
      chosen = [];
      connects = 0;
    });

    Future<AppLocalizations> pump(
      WidgetTester tester, {
      required List<RemovableVolume> volumes,
      StorageDestination value = const StorageDestination.internal(),
      int? requiredBytesPerSecond,
      bool enabled = true,
    }) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpApp(
        Scaffold(
          body: StorageDestinationPicker(
            volumes: volumes,
            value: value,
            requiredBytesPerSecond: requiredBytesPerSecond,
            enabled: enabled,
            onChanged: chosen.add,
            onConnectUsb: () => connects++,
          ),
        ),
      );
      return AppLocalizations.of(tester.element(find.byType(Scaffold)));
    }

    testWidgets('Internal and each mounted drive by its label; a tap chooses '
        'it, and the chosen one again changes nothing', (tester) async {
      final l10n = await pump(
        tester,
        volumes: [
          _volume(1),
          _volume(2, label: 'BACKUP'),
          _volume(3, status: RemovableVolumeStatus.ejecting),
          _volume(4, status: RemovableVolumeStatus.ejected),
        ],
      );

      expect(find.text(l10n.saveTo), findsOneWidget);
      expect(find.text(l10n.storageInternalTitle), findsOneWidget);
      expect(find.text('SEGNO USB'), findsOneWidget);
      expect(find.text('BACKUP'), findsOneWidget);
      expect(find.byKey(const Key('save_to_usb_3')), findsNothing);
      expect(find.byKey(const Key('save_to_usb_4')), findsNothing);

      await tester.tap(find.text('BACKUP'));
      await tester.tap(find.byKey(const Key('save_to_internal')));
      expect(chosen, [const StorageDestination.removable(2)]);
    });

    testWidgets('a read-only, an unsupported and a too slow drive are drawn '
        'disabled, each with its reason', (tester) async {
      final l10n = await pump(
        tester,
        requiredBytesPerSecond: 576000,
        volumes: [
          _volume(1, label: 'RO', status: RemovableVolumeStatus.readOnly),
          _volume(
            2,
            label: 'MAC',
            status: RemovableVolumeStatus.unsupported,
            fsType: 'apfs',
          ),
          _volume(3, label: 'SLOW', writeBytesPerSecond: 400000),
          _volume(4, label: 'FAST', writeBytesPerSecond: 576000),
        ],
      );

      expect(find.text(l10n.storageUsbReadOnly('RO')), findsOneWidget);
      expect(find.text(l10n.saveToUnsupported('MAC')), findsOneWidget);
      expect(find.text(l10n.saveToTooSlow('SLOW')), findsOneWidget);
      expect(find.text(l10n.saveToTooSlow('FAST')), findsNothing);

      for (final label in ['RO', 'MAC', 'SLOW', 'FAST']) {
        await tester.tap(find.text(label), warnIfMissed: false);
      }
      expect(chosen, [const StorageDestination.removable(4)]);
    });

    testWidgets('an unmeasured drive is not called too slow', (tester) async {
      final l10n = await pump(
        tester,
        requiredBytesPerSecond: 576000,
        volumes: [_volume(1, writeBytesPerSecond: null)],
      );
      expect(find.text(l10n.saveToTooSlow('SEGNO USB')), findsNothing);
    });

    testWidgets('with no drive, USB drive asks for one', (tester) async {
      final l10n = await pump(tester, volumes: const []);

      await tester.tap(find.text(l10n.storageUsbTitle));

      expect(connects, 1);
      expect(chosen, isEmpty);
    });

    testWidgets('locked while a take records: the chosen name in bold, no '
        'choices', (tester) async {
      await pump(
        tester,
        volumes: [_volume(1)],
        value: const StorageDestination.removable(1),
        enabled: false,
      );

      final chosenName = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('save_to_chosen')),
          matching: find.byType(RichText),
        ),
      );
      expect(chosenName.text.toPlainText(), 'SEGNO USB');
      expect(chosenName.text.style?.fontWeight, FontWeight.w700);
      expect(find.byKey(const Key('save_to_internal')), findsNothing);
    });
  });
}
