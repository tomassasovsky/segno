import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/connectivity_banners.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/wifi/wifi_cubit.dart';

import '../../helpers/helpers.dart';
import 'destination_harness.dart';

void main() {
  late DestinationHarness harness;

  setUp(() {
    resetSegnoNavigatorForTest();
    resetAppToastsForTest();
    resetToastificationForTest();
    harness = DestinationHarness();
  });

  Future<void> pump(
    WidgetTester tester, {
    Widget home = const SizedBox.shrink(),
    AudioSetupState audioState = const AudioSetupState(),
  }) => harness.pump(tester, home: home, audioState: audioState);

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Scaffold).first));

  final opens = <String, (Future<void> Function(), Type)>{
    'Device': (openDeviceSettings, DeviceSettingsPage),
    'Network': (openNetworkSettings, NetworkSettingsPage),
    'Displays': (openDisplaySettings, DisplaysSettingsPage),
    'Storage': (openStorageSettings, StorageSettingsPage),
    'Updates': (openUpdateSettings, UpdatesSettingsPage),
    'About': (openAboutSettings, AboutSettingsPage),
  };

  group('each destination', () {
    for (final MapEntry(key: name, value: (open, page)) in opens.entries) {
      testWidgets('$name opens once, Back leaves it and it opens again', (
        tester,
      ) async {
        await pump(tester);

        unawaited(open());
        unawaited(open());
        await tester.pumpAndSettle();
        expect(find.byType(page), findsOneWidget);
        // About, Network, Displays and Updates have their accepted pages; the
        // others still host a tray body on the interim destination panel.
        if (page != AboutSettingsPage &&
            page != NetworkSettingsPage &&
            page != DisplaysSettingsPage &&
            page != UpdatesSettingsPage) {
          expect(find.byKey(const Key('settings_destination_panel')), findsOne);
        }

        await tester.tap(find.byKey(const Key('loop_settings_back')));
        await tester.pumpAndSettle();
        expect(find.byType(page), findsNothing);

        unawaited(open());
        await tester.pumpAndSettle();
        expect(find.byType(page), findsOneWidget);
      });
    }

    testWidgets('Stage leaves every page above the stage at once', (
      tester,
    ) async {
      await pump(tester);
      unawaited(openUpdateSettings());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('updates_about_row')));
      await tester.pumpAndSettle();
      expect(find.byType(AboutSettingsPage), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_settings_stage')));
      await tester.pumpAndSettle();
      expect(find.byType(AboutSettingsPage), findsNothing);
      expect(find.byType(UpdatesSettingsPage), findsNothing);
    });

    testWidgets('the crumb names the page under SETTINGS', (tester) async {
      await pump(tester);
      unawaited(openDisplaySettings());
      await tester.pumpAndSettle();
      final strings = l10n(tester);
      expect(
        find.text(strings.settingsCrumb(strings.settingsDisplaysTitle)),
        findsOneWidget,
      );
      expect(find.text(strings.settingsDisplaysTitle), findsOneWidget);
    });
  });

  group('Device', () {
    testWidgets('is one page: the interface rows and the loop cap, no tabs; '
        'what a record press does and how long later tracks record live in '
        'Loop settings', (tester) async {
      await pump(tester);
      unawaited(openDeviceSettings());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audio_device_tab')), findsOneWidget);
      expect(find.byKey(const Key('audio_routing_card')), findsOneWidget);
      expect(find.byKey(const Key('audio_max_loop_row')), findsOneWidget);
      expect(find.byKey(const Key('device_settings_tabs')), findsNothing);
      expect(find.byKey(const Key('audio_default_length_row')), findsNothing);
      expect(find.byKey(const Key('audio_quantize_row')), findsNothing);
      expect(find.byKey(const Key('audio_rec_dub_row')), findsNothing);
      expect(find.byKey(const Key('audio_auto_record_row')), findsNothing);
    });
  });

  group('Network', () {
    testWidgets('reads the radio only while open, and lets go on leave', (
      tester,
    ) async {
      await pump(tester);
      expect(harness.wifi.statusReads, 0);

      unawaited(openNetworkSettings());
      await tester.pumpAndSettle();
      expect(harness.wifi.statusReads, 1);
      expect(
        find.byKey(const Key('network_connection_card')),
        findsOneWidget,
      );
      final cubit = BlocProvider.of<WifiCubit>(
        tester.element(find.byKey(const Key('network_connection_card'))),
      );

      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(cubit.isClosed, isTrue);
    });
  });

  group('Storage and Updates', () {
    testWidgets('Storage hosts the storage face', (tester) async {
      await pump(tester);
      unawaited(openStorageSettings());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('system_storage_tab')), findsOneWidget);
    });

    testWidgets('opening Updates drops the update toast', (tester) async {
      await pump(tester);
      showAppToast(id: AppToastId.update, title: const Text('Update'));
      await tester.pump();
      expect(debugAppToastActive(AppToastId.update), isTrue);

      unawaited(openUpdateSettings());
      await tester.pumpAndSettle();
      expect(debugAppToastActive(AppToastId.update), isFalse);
      // Let the dismissed toast's exit animation finish.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Updates is the accepted page and leads to About', (
      tester,
    ) async {
      await pump(tester);
      unawaited(openUpdateSettings());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('updates_status')), findsOneWidget);
      expect(isSegnoUpdatesSettingsOpen, isTrue);

      await tester.tap(find.byKey(const Key('updates_about_row')));
      await tester.pumpAndSettle();
      expect(find.byType(AboutSettingsPage), findsOneWidget);
      expect(find.byKey(const Key('about_this_console')), findsOneWidget);

      await tester.tap(find.byKey(const Key('loop_settings_stage')));
      await tester.pumpAndSettle();
      expect(isSegnoUpdatesSettingsOpen, isFalse);
    });
  });

  group('notices that lead to Device', () {
    testWidgets('the device-lost banner opens Device', (tester) async {
      await pump(
        tester,
        home: const ConnectivityBanners(),
        audioState: const AudioSetupState(
          deviceConnectivity: DeviceConnectivity.lost,
          connectivityDeviceName: 'Scarlett 2i2',
        ),
      );
      await tester.tap(
        find.byKey(const Key('connectivity_banner_device_action')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSettingsPage), findsOneWidget);
      expect(find.byKey(const Key('audio_device_tab')), findsOneWidget);
    });

    testWidgets('the engine-stopped banner opens Device', (tester) async {
      await pump(tester, home: const AudioNotRunningBanner());
      await tester.tap(find.byKey(const Key('tracks_audioNotRunning')));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceSettingsPage), findsOneWidget);
    });
  });
}
