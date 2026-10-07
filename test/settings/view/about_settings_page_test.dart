import 'dart:async';

import 'package:console_facts_client/console_facts_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/system/cubit/console_facts_cubit.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:update_repository/update_repository.dart';

import '../../helpers/helpers.dart';
import 'destination_harness.dart';

/// A console whose facts are exactly the ones given.
class _FactsClient extends UnsupportedConsoleFactsClient {
  const _FactsClient(this._facts);

  final ConsoleFacts _facts;

  @override
  bool get isSupported => true;

  @override
  Future<ConsoleFacts> facts() async => _facts;
}

void main() {
  late DestinationHarness harness;

  setUp(() {
    resetSegnoNavigatorForTest();
    resetAppToastsForTest();
    resetToastificationForTest();
    harness = DestinationHarness();
  });

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Scaffold).first));

  Finder inRow(String key, String text) => find.descendant(
    of: find.byKey(Key(key)),
    matching: find.text(text),
  );

  const console = ConsoleFacts(
    serial: '10000000abcd1234',
    systemImage: '1.2.3',
    panels: ['LG ULTRAFINE', 'Segno 7'],
    lastFlashed: ConsoleBoardFlash(firmware: '1.4', protocol: 3),
  );

  Future<void> openAbout(
    WidgetTester tester, {
    ConsoleFacts facts = console,
    FakePedalLink? link,
    AudioSetupState audioState = const AudioSetupState(),
  }) async {
    await harness.pump(
      tester,
      factsClient: _FactsClient(facts),
      pedalLink: link,
      audioState: audioState,
      updateState: UpdateState(currentVersion: Version.parse('1.0.0')),
    );
    unawaited(openAboutSettings());
    await tester.pumpAndSettle();
  }

  group('About', () {
    testWidgets('This console shows every fact the console read', (
      tester,
    ) async {
      await openAbout(
        tester,
        audioState: const AudioSetupState(
          engineStatus: EngineStatus(
            isConnected: true,
            deviceName: 'Scarlett 4i4 4th Gen',
            sampleRate: 48000,
            bufferFrames: 128,
          ),
        ),
      );
      final strings = l10n(tester);

      expect(find.text(strings.settingsAboutTitle), findsOneWidget);
      expect(find.text(strings.aboutThisConsolePanel), findsOneWidget);
      expect(inRow('about_name', strings.aboutDefaultName), findsOneWidget);
      expect(find.byKey(const Key('about_rename')), findsOneWidget);
      expect(inRow('about_version', '1.0.0'), findsOneWidget);
      expect(inRow('about_image', '1.2.3'), findsOneWidget);
      expect(inRow('about_serial', '10000000abcd1234'), findsOneWidget);
      expect(
        inRow('about_interface', 'Scarlett 4i4 4th Gen'),
        findsOneWidget,
      );
      expect(
        inRow('about_displays', 'LG ULTRAFINE\nSegno 7'),
        findsOneWidget,
      );
      // The pen's preview line is a mockup's, not the product's.
      expect(find.textContaining('simulated'), findsNothing);
    });

    testWidgets('a fact the console did not read has no row', (tester) async {
      await openAbout(
        tester,
        facts: const ConsoleFacts(systemImage: '1.2.3'),
      );
      expect(find.byKey(const Key('about_image')), findsOneWidget);
      expect(find.byKey(const Key('about_name')), findsNothing);
      expect(find.byKey(const Key('about_serial')), findsNothing);
      expect(find.byKey(const Key('about_displays')), findsNothing);
      // Nothing is open, so no interface is named.
      expect(find.byKey(const Key('about_interface')), findsNothing);
    });

    testWidgets('Rename opens the rename sheet; a new name shows on the row', (
      tester,
    ) async {
      await openAbout(tester);
      final strings = l10n(tester);
      await tester.tap(find.byKey(const Key('about_rename')));
      await tester.pumpAndSettle();
      expect(find.text(strings.aboutRenameTitle), findsOneWidget);
      expect(find.byKey(const Key('console_rename_sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('console_rename_cancel')));
      await tester.pumpAndSettle();

      // The name the sheet hands back goes through the cubit, keyed off the
      // serial the page read.
      await tester
          .element(find.byType(AboutSettingsPage))
          .read<ConsoleFactsCubit>()
          .rename('Stage left');
      await tester.pumpAndSettle();
      expect(inRow('about_name', 'Stage left'), findsOneWidget);
      expect(
        await harness.settings.loadConsoleName('10000000abcd1234'),
        'Stage left',
      );
    });

    testWidgets('a silent board shows the flash record, captioned', (
      tester,
    ) async {
      await openAbout(tester);
      final strings = l10n(tester);
      expect(
        inRow(
          'about_controller_connection',
          strings.aboutConnectionDisconnected,
        ),
        findsOneWidget,
      );
      expect(inRow('controller_firmware', '1.4'), findsOneWidget);
      expect(
        inRow('controller_firmware', strings.aboutLastFlashedCaption),
        findsOneWidget,
      );
      expect(inRow('controller_protocol', '3'), findsOneWidget);
    });

    testWidgets('a talking board reports itself, with no caption', (
      tester,
    ) async {
      final link = FakePedalLink();
      await openAbout(tester, link: link);
      link.hello(firmwareMinor: 6);
      await tester.pumpAndSettle();
      final strings = l10n(tester);
      expect(
        inRow('about_controller_connection', strings.aboutConnectionConnected),
        findsOneWidget,
      );
      expect(inRow('controller_firmware', '1.6'), findsOneWidget);
      expect(find.text(strings.aboutLastFlashedCaption), findsNothing);
      expect(find.text(strings.aboutNotReportedCaption), findsNothing);
      expect(
        inRow('controller_protocol', '${PedalLinkCodec.protocolVersion}'),
        findsOneWidget,
      );
      // Let the hello watchdog lapse so no timer outlives the test.
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('no board and no record is Not reported', (tester) async {
      await openAbout(tester, facts: ConsoleFacts.unknown);
      final strings = l10n(tester);
      expect(
        inRow('controller_firmware', strings.aboutNotReported),
        findsOneWidget,
      );
      expect(
        inRow('controller_firmware', strings.aboutNotReportedCaption),
        findsOneWidget,
      );
      expect(
        inRow('controller_protocol', strings.aboutNotReported),
        findsOneWidget,
      );
    });

    testWidgets('Open-source notices counts the registry and opens it', (
      tester,
    ) async {
      LicenseRegistry.addLicense(
        () => Stream.fromIterable([
          const LicenseEntryWithLineBreaks(['about_pkg'], 'ABOUT TERMS'),
        ]),
      );
      await openAbout(tester);
      await tester.tap(find.byKey(const Key('about_notices')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('console_licence_about_pkg')), findsOne);
    });

    testWidgets('the encoder reaches Controller firmware and opens it', (
      tester,
    ) async {
      await openAbout(tester);
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byKey(const Key('about_controller_firmware_row')),
            matching: find.byType(InkWell),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(ControllerFirmwarePage), findsOneWidget);
    });
  });

  group('Controller firmware', () {
    testWidgets('states the installed facts and that updating is not '
        'supported', (tester) async {
      await openAbout(tester);
      await tester.tap(find.byKey(const Key('about_controller_firmware_row')));
      await tester.pumpAndSettle();
      final strings = l10n(tester);

      expect(find.text(strings.controllerFirmwareTitle), findsOneWidget);
      expect(find.text(strings.controllerFirmwareCrumb), findsOneWidget);
      expect(find.text(strings.controllerInstalledPanel), findsOneWidget);
      expect(inRow('controller_firmware', '1.4'), findsOneWidget);
      expect(
        inRow('controller_firmware', strings.aboutLastFlashedCaption),
        findsOneWidget,
      );
      expect(inRow('controller_protocol', '3'), findsOneWidget);
      expect(find.text(strings.controllerUpdateUnsupported), findsOneWidget);
      expect(find.byKey(const Key('controller_software_updates')), findsOne);
      expect(find.textContaining('simulated'), findsNothing);
    });

    testWidgets('Software updates goes back down to Updates', (tester) async {
      await harness.pump(
        tester,
        factsClient: const _FactsClient(console),
      );
      unawaited(openUpdateSettings());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_about_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('about_controller_firmware_row')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('controller_software_updates')));
      await tester.pumpAndSettle();
      expect(find.byType(UpdatesSettingsPage), findsOneWidget);
      expect(find.byType(AboutSettingsPage), findsNothing);
      expect(find.byType(ControllerFirmwarePage), findsNothing);
    });

    testWidgets('Software updates opens Updates when it is not underneath', (
      tester,
    ) async {
      await harness.pump(tester);
      unawaited(openControllerFirmware());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('controller_software_updates')));
      await tester.pumpAndSettle();
      expect(find.byType(UpdatesSettingsPage), findsOneWidget);
    });
  });
}
