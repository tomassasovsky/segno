import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/display_brightness_edit.dart';
import 'package:segno/appliance/display_role.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/cubit/waveform_window_cubit.dart';

import '../../helpers/helpers.dart';
import 'destination_harness.dart';

class _RefusingStore extends FakeKeyValueStore {
  bool refuse = true;

  @override
  Future<void> setDouble(String key, double value) async {
    if (key.startsWith('ui.brightness') && refuse) {
      throw StateError('brightness storage unavailable');
    }
    await super.setDouble(key, value);
  }
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

  Finder slider(DisplayRole role) =>
      find.byKey(Key('displays_brightness_${role.name}'));
  String readout(WidgetTester tester, DisplayRole role) => tester
      .widget<AppText>(
        find.byKey(Key('displays_brightness_readout_${role.name}')),
      )
      .data!;

  Future<void> openDisplays(
    WidgetTester tester, {
    WaveformWindowState waveformState = const WaveformWindowState(),
  }) async {
    await harness.pump(tester, waveformState: waveformState);
    unawaited(openDisplaySettings());
    await tester.pumpAndSettle();
  }

  void focusSlider(WidgetTester tester, DisplayRole role) => Focus.of(
    tester.element(
      find.descendant(of: slider(role), matching: find.byType(Container)),
    ),
  ).requestFocus();

  testWidgets('the Track display card comes first, then the Main display, '
      'Dim while idle and Display options', (tester) async {
    await openDisplays(tester);
    final strings = l10n(tester);
    final track = tester.getRect(find.byKey(const Key('displays_card_track')));
    final main = tester.getRect(find.byKey(const Key('displays_card_main')));
    expect(track.left, lessThan(main.left));
    expect(track.top, main.top);
    expect(find.text(strings.displaysTrackDisplay), findsOneWidget);
    expect(find.text(strings.displaysMainDisplay), findsOneWidget);
    expect(find.text(strings.displaysConnected), findsNWidgets(2));

    final dim = tester.getRect(find.byKey(const Key('displays_dim_0')));
    final options = tester.getRect(
      find.byKey(const Key('displays_waveform_switch')),
    );
    expect(dim.top, greaterThan(track.bottom));
    expect(options.top, greaterThan(dim.bottom));
    // Two brightness readouts at the 80% a fresh console starts on.
    expect(
      readout(tester, DisplayRole.track),
      strings.trayBrightnessPercent(80),
    );
    expect(
      readout(tester, DisplayRole.main),
      strings.trayBrightnessPercent(80),
    );
  });

  group('brightness', () {
    testWidgets('the whole travel is 20-100%, and each panel keeps its own', (
      tester,
    ) async {
      await openDisplays(tester);

      await tester.drag(slider(DisplayRole.track), const Offset(-4000, 0));
      await tester.pumpAndSettle();
      expect(harness.brightness.state.levelOf(DisplayRole.track), 0.2);
      expect(
        readout(tester, DisplayRole.track),
        l10n(tester).trayBrightnessPercent(20),
      );
      expect(
        await harness.settings.loadDisplayBrightness(DisplayRole.track),
        0.2,
      );
      // The other panel is untouched.
      expect(harness.brightness.state.levelOf(DisplayRole.main), 0.8);

      // Halfway along is halfway between the floor and full.
      await tester.tapAt(tester.getCenter(slider(DisplayRole.main)));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(
        harness.brightness.state.levelOf(DisplayRole.main),
        closeTo(0.6, 0.01),
      );
      expect(harness.brightness.state.levelOf(DisplayRole.track), 0.2);
    });

    testWidgets('a double tap returns to 80%', (tester) async {
      await openDisplays(tester);
      await tester.drag(slider(DisplayRole.main), const Offset(4000, 0));
      await tester.pumpAndSettle();
      expect(harness.brightness.state.levelOf(DisplayRole.main), 1);

      await tester.tap(slider(DisplayRole.main));
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(slider(DisplayRole.main));
      await tester.pumpAndSettle();
      expect(harness.brightness.state.levelOf(DisplayRole.main), 0.8);
      expect(
        await harness.settings.loadDisplayBrightness(DisplayRole.main),
        0.8,
      );
    });

    testWidgets('the encoder steps it by 5%: Enter, turn, Enter; Back '
        'cancels the edit and stays on the page', (tester) async {
      await openDisplays(tester);
      focusSlider(tester, DisplayRole.track);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(harness.brightness.state.levelOf(DisplayRole.track), 0.7);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(harness.brightness.state.levelOf(DisplayRole.track), 0.7);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(harness.brightness.state.levelOf(DisplayRole.track), 0.75);
      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(harness.brightness.state.levelOf(DisplayRole.track), 0.7);
      expect(find.byType(DisplaysSettingsPage), findsOneWidget);
      expect(
        await harness.settings.loadDisplayBrightness(DisplayRole.track),
        0.7,
      );

      // With no edit open, Back leaves.
      await tester.tap(find.byKey(const Key('loop_settings_back')));
      await tester.pumpAndSettle();
      expect(find.byType(DisplaysSettingsPage), findsNothing);
    });

    testWidgets('a screen reader can increase and decrease it', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openDisplays(tester);
      final node = tester.getSemantics(slider(DisplayRole.main));
      expect(node.label, l10n(tester).trayBrightnessLabel);
      expect(node.value, l10n(tester).trayBrightnessPercent(80));
      expect(node.decreasedValue, l10n(tester).trayBrightnessPercent(75));
      node.owner!.performAction(node.id, SemanticsAction.decrease);
      await tester.pumpAndSettle();
      expect(harness.brightness.state.levelOf(DisplayRole.main), 0.75);
      semantics.dispose();
    });

    testWidgets('a brightness that did not save says so over the page, and '
        'the next change that saves clears it', (tester) async {
      final store = _RefusingStore();
      harness = DestinationHarness(store: store);
      await openDisplays(tester);

      await tester.drag(slider(DisplayRole.track), const Offset(-4000, 0));
      await tester.pumpAndSettle();
      // The level applies even though the write failed.
      expect(harness.brightness.state.levelOf(DisplayRole.track), 0.2);
      expect(debugAppToastActive(displayBrightnessSaveFailedToast), isTrue);

      store.refuse = false;
      await tester.drag(slider(DisplayRole.track), const Offset(4000, 0));
      await tester.pumpAndSettle();
      expect(
        await harness.settings.loadDisplayBrightness(DisplayRole.track),
        1,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(debugAppToastActive(displayBrightnessSaveFailedToast), isFalse);
    });
  });

  group('presence', () {
    testWidgets('an unplugged Track display says Not connected', (
      tester,
    ) async {
      harness.outputs.status['HDMI-A-2'] = false;
      await openDisplays(tester);
      final strings = l10n(tester);
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('displays_status_track')))
            .data,
        strings.displaysNotConnected,
      );
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('displays_status_main')))
            .data,
        strings.displaysConnected,
      );
    });

    testWidgets('a panel plugged in while the page is open says so', (
      tester,
    ) async {
      harness.outputs.status['HDMI-A-2'] = false;
      await openDisplays(tester);
      harness.outputs.status['HDMI-A-2'] = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        tester
            .widget<AppText>(find.byKey(const Key('displays_status_track')))
            .data,
        l10n(tester).displaysConnected,
      );
    });

    testWidgets('a disconnected display disables its Calibrate button', (
      tester,
    ) async {
      var calibrations = 0;
      Future<void> card({required bool connected}) async {
        await harness.pump(
          tester,
          home: DisplayCard(
            role: DisplayRole.track,
            title: 'Track display',
            roleLabel: 'Selected track and waveform',
            panelLabel: '7″',
            connected: connected,
            onCalibrate: () => calibrations++,
          ),
        );
      }

      const button = Key('displays_calibrate_track');
      await card(connected: false);
      await tester.tap(find.byKey(button));
      await tester.pump();
      expect(calibrations, 0);
      expect(
        tester.widget<LoopOutlinedButton>(find.byKey(button)).onTap,
        isNull,
      );

      await card(connected: true);
      await tester.tap(find.byKey(button));
      await tester.pump();
      expect(calibrations, 1);
    });
  });

  group('Dim while idle', () {
    testWidgets('Never is chosen until a period is picked, and the pick is '
        'saved', (tester) async {
      await openDisplays(tester);
      final strings = l10n(tester);
      expect(find.text(strings.displaysDimNever), findsOneWidget);
      for (final minutes in const [2, 5, 10]) {
        expect(find.text(strings.displaysDimMinutes(minutes)), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('displays_dim_120')));
      await tester.pumpAndSettle();
      expect(harness.idle.state.seconds, 120);
      expect(await harness.settings.loadIdleDimSeconds(), 120);
      // The idle period is running; closing the owner stops it.
      unawaited(harness.idle.close());
    });
  });

  group('Display options', () {
    testWidgets('the switches and the refresh rate drive their settings', (
      tester,
    ) async {
      await openDisplays(tester);
      when(
        () => harness.waveform.setEnabled(value: any(named: 'value')),
      ).thenAnswer((_) async {});
      when(
        () => harness.contrast.setEnabled(value: any(named: 'value')),
      ).thenAnswer((_) async {});
      when(() => harness.refresh.setHz(any())).thenAnswer((_) async {});

      await tester.tap(find.byKey(const Key('displays_waveform_switch')));
      verify(() => harness.waveform.setEnabled(value: false)).called(1);
      await tester.tap(find.byKey(const Key('displays_high_contrast_switch')));
      verify(() => harness.contrast.setEnabled(value: true)).called(1);

      await tester.tap(find.byKey(const Key('displays_refresh_rate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('displays_refresh_rate_30')));
      await tester.pumpAndSettle();
      verify(() => harness.refresh.setHz(30)).called(1);
    });

    testWidgets('the shortcuts button opens the legend', (tester) async {
      await openDisplays(tester);
      await tester.tap(find.byKey(const Key('displays_shortcuts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shortcutsHelp_dialog')), findsOneWidget);
    });

    testWidgets('a Track display window that did not open says so, and '
        'offers a retry', (tester) async {
      await openDisplays(
        tester,
        waveformState: const WaveformWindowState(openFailed: true),
      );
      when(harness.waveform.retryOpen).thenReturn(null);
      expect(
        find.text(l10n(tester).waveformWindowFailedBanner),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('displays_waveform_retry')));
      verify(harness.waveform.retryOpen).called(1);
    });
  });

  testWidgets('focus reaches every control, so the encoder can', (
    tester,
  ) async {
    await openDisplays(tester);
    focusSlider(tester, DisplayRole.track);
    await tester.pump();

    final reached = <Key>{};
    const wanted = [
      Key('displays_brightness_track'),
      Key('displays_brightness_main'),
      Key('displays_dim_0'),
      Key('displays_dim_600'),
      Key('displays_waveform_switch'),
      Key('displays_high_contrast_switch'),
      Key('displays_refresh_rate'),
      Key('displays_shortcuts'),
    ];
    for (var i = 0; i < 30; i++) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null) {
        for (final key in wanted) {
          final owner = find.byKey(key);
          if (find
                  .ancestor(
                    of: find.byElementPredicate((e) => e == focused),
                    matching: owner,
                  )
                  .evaluate()
                  .isNotEmpty ||
              find
                  .descendant(
                    of: owner,
                    matching: find.byElementPredicate(
                      (e) => e == focused,
                    ),
                  )
                  .evaluate()
                  .isNotEmpty) {
            reached.add(key);
          }
        }
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(reached, containsAll(wanted));
  });
}
