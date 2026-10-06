import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/connectivity_banners.dart';
import 'package:segno/looper/view/tracks_chrome.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/wifi/wifi_cubit.dart';

import 'destination_harness.dart';

void main() {
  late DestinationHarness harness;

  setUp(() {
    resetSegnoNavigatorForTest();
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
        expect(find.byKey(const Key('settings_destination_panel')), findsOne);

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
      await tester.tap(find.byKey(const Key('settings_about_row')));
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
    testWidgets('opens on Device, with the interface rows', (tester) async {
      await pump(tester);
      unawaited(openDeviceSettings());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device_settings_tabs')), findsOneWidget);
      expect(find.byKey(const Key('audio_device_tab')), findsOneWidget);
      expect(find.byKey(const Key('audio_routing_card')), findsOneWidget);
    });

    testWidgets(
      'Recording keeps only the loop cap and the default length; what a '
      'record press does lives in Loop settings',
      (tester) async {
        await pump(tester);
        unawaited(openDeviceSettings());
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n(tester).audioRecordingTab));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('audio_recording_tab')), findsOneWidget);
        expect(find.byKey(const Key('audio_max_loop_row')), findsOneWidget);
        expect(
          find.byKey(const Key('audio_default_length_row')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('audio_quantize_row')), findsNothing);
        expect(find.byKey(const Key('audio_rec_dub_row')), findsNothing);
        expect(find.byKey(const Key('audio_auto_record_row')), findsNothing);
      },
    );
  });

  group('Displays', () {
    testWidgets('brightness reads the cubit and writes through it', (
      tester,
    ) async {
      await pump(tester);
      unawaited(openDisplaySettings());
      await tester.pumpAndSettle();
      final bar = find.byKey(const Key('displays_brightness'));
      expect(bar, findsOneWidget);
      expect(find.text(l10n(tester).trayBrightnessPercent(100)), findsOne);

      // Dragging to the far left asks for zero; the console keeps its
      // floor, so the screen stays readable enough to undo it.
      await tester.drag(bar, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(harness.brightness.state, 0.1);
      expect(find.text(l10n(tester).trayBrightnessPercent(10)), findsOne);
      expect(await harness.settings.loadBrightness(), 0.1);
    });

    testWidgets('the screen rows from the tray follow the brightness', (
      tester,
    ) async {
      await pump(tester);
      unawaited(openDisplaySettings());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('system_display_tab')), findsOneWidget);
      expect(find.byKey(const Key('system_waveform_row')), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('displays_brightness'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('system_waveform_row'))).dy,
        ),
      );
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
      expect(find.byKey(const Key('wifi_tray_body')), findsOneWidget);
      final cubit = BlocProvider.of<WifiCubit>(
        tester.element(find.byKey(const Key('wifi_tray_body'))),
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

    testWidgets('Updates hosts the update face and leads to About', (
      tester,
    ) async {
      await pump(tester);
      unawaited(openUpdateSettings());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('system_updates_tab')), findsOneWidget);
      expect(isSegnoUpdatesSettingsOpen, isTrue);

      await tester.tap(find.byKey(const Key('settings_about_row')));
      await tester.pumpAndSettle();
      expect(find.byType(AboutSettingsPage), findsOneWidget);
      expect(find.byKey(const Key('system_about_tab')), findsOneWidget);

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
