import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/touch_calibration/view/touch_calibration_page.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/visualizer.dart';
import 'package:touch_calibration_client/touch_calibration_client.dart';

import '../../../helpers/helpers.dart';
import '../../view/destination_harness.dart';
import '../fake_touch_calibration_client.dart';

/// A Track display link that records what calibration drew on it.
class _RecordingLink extends NoopWaveformWindowService {
  bool linked = true;
  final shown = <({TouchPoint? target, String label})>[];

  @override
  Future<bool> showCalibrationTarget(
    TouchPoint? target, {
    String label = '',
  }) async {
    shown.add((target: target, label: label));
    return linked;
  }
}

void main() {
  late DestinationHarness harness;
  late FakeTouchCalibrationClient client;
  late _RecordingLink link;

  setUp(() {
    resetSegnoNavigatorForTest();
    resetAppToastsForTest();
    resetToastificationForTest();
    client = FakeTouchCalibrationClient();
    link = _RecordingLink();
    harness = DestinationHarness()
      ..touch = client
      ..link = link;
  });

  AppLocalizations l10n(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Scaffold).last));

  final target = find.byKey(const Key('touch_calibration_target'));

  Future<void> openCalibration(WidgetTester tester, String card) async {
    await harness.pump(tester);
    unawaited(openDisplaySettings());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('displays_calibrate_$card')));
    await tester.pumpAndSettle();
  }

  String text(WidgetTester tester, String key) =>
      tester.widget<AppText>(find.byKey(Key(key))).data!;

  testWidgets('Calibrate touch is offered only when the console supports it', (
    tester,
  ) async {
    harness.touch = const UnsupportedTouchCalibrationClient();
    await harness.pump(tester);
    unawaited(openDisplaySettings());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('displays_calibrate_main')), findsNothing);
    expect(find.byKey(const Key('displays_calibrate_track')), findsNothing);
  });

  group('main display', () {
    testWidgets('five taps on the targets, then Keep, store the calibration', (
      tester,
    ) async {
      await openCalibration(tester, 'main');
      final strings = l10n(tester);
      expect(
        find.text(strings.touchCalibrationTitle(strings.displaysMainDisplay)),
        findsOneWidget,
      );
      expect(
        text(tester, 'touch_calibration_heading'),
        strings.touchCalibrationInstruction,
      );

      for (var i = 0; i < TouchCalibrationPage.captureTargets.length; i++) {
        expect(text(tester, 'touch_calibration_step'), '${i + 1} of 5');
        await tester.tapAt(tester.getCenter(target));
        await tester.pumpAndSettle();
      }

      expect(client.calls, ['read main', 'apply main']);
      expect(client.stored, isNull);
      // Taps that land on the targets fit the identity.
      final stored = client.inForce!;
      for (final (got, want) in [
        (stored.a, 1.0),
        (stored.b, 0.0),
        (stored.c, 0.0),
        (stored.d, 0.0),
        (stored.e, 1.0),
        (stored.f, 0.0),
      ]) {
        expect(got, closeTo(want, 1e-6));
      }
      expect(
        text(tester, 'touch_calibration_heading'),
        strings.touchCalibrationTestInstruction,
      );
      expect(text(tester, 'touch_calibration_step'), 'Test 1 of 3');
      expect(text(tester, 'touch_calibration_countdown'), '30s');

      await tester.tapAt(tester.getCenter(target));
      await tester.pump();
      expect(text(tester, 'touch_calibration_step'), 'Test 2 of 3');

      await tester.tap(find.byKey(const Key('touch_calibration_keep')));
      await tester.pumpAndSettle();
      expect(find.byType(TouchCalibrationPage), findsNothing);
      expect(client.calls, ['read main', 'apply main', 'write main']);
      expect(client.stored, stored);
    });

    testWidgets('the main targets sit in the pen 30 area', (tester) async {
      await openCalibration(tester, 'main');
      final area = tester.getRect(
        find.byKey(const Key('touch_calibration_area')),
      );
      expect(area, MainCalibrationArea.rect);
      final first = TouchCalibrationPage.captureTargets.first;
      expect(
        tester.getCenter(target),
        Offset(
          area.left + first.x * area.width,
          area.top + first.y * area.height,
        ),
      );
      await tester.tap(find.byKey(const Key('touch_calibration_cancel')));
      await tester.pumpAndSettle();
    });

    testWidgets('Cancel in the test reverts and leaves', (tester) async {
      await openCalibration(tester, 'main');
      for (var i = 0; i < 5; i++) {
        await tester.tapAt(tester.getCenter(target));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('touch_calibration_cancel')));
      await tester.pumpAndSettle();
      expect(client.calls.last, 'restore main');
      expect(find.byType(TouchCalibrationPage), findsNothing);
    });

    testWidgets('the countdown running out reverts and leaves', (tester) async {
      await openCalibration(tester, 'main');
      for (var i = 0; i < 5; i++) {
        await tester.tapAt(tester.getCenter(target));
        await tester.pumpAndSettle();
      }
      await tester.pump(const Duration(seconds: 29));
      expect(text(tester, 'touch_calibration_countdown'), '1s');
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(client.calls.last, 'restore main');
      expect(find.byType(TouchCalibrationPage), findsNothing);
    });
  });

  group('Track display', () {
    testWidgets('draws its targets on the Track display and measures the taps '
        'there', (tester) async {
      await openCalibration(tester, 'track');
      final strings = l10n(tester);
      expect(
        text(tester, 'touch_calibration_heading'),
        strings.touchCalibrationTrackInstruction,
      );
      expect(
        find.byKey(const Key('touch_calibration_track_mirror')),
        findsOneWidget,
      );
      expect(link.shown.single, (
        target: TouchCalibrationPage.captureTargets.first,
        label: '1 of 5',
      ));

      // A tap on this page's mirror is not a tap on the Track display.
      await tester.tapAt(tester.getCenter(target));
      await tester.pump();
      expect(text(tester, 'touch_calibration_step'), '1 of 5');

      for (final point in TouchCalibrationPage.captureTargets) {
        link.onCalibrationTap!(point);
        await tester.pumpAndSettle();
      }
      expect(client.calls, ['read readout', 'apply readout']);
      expect(link.shown.last, (
        target: TouchCalibrationPage.testTargets.first,
        label: 'Test 1 of 3',
      ));

      await tester.tap(find.byKey(const Key('touch_calibration_keep')));
      await tester.pumpAndSettle();
      expect(find.byType(TouchCalibrationPage), findsNothing);
      expect(link.shown.last.target, isNull);
      expect(link.onCalibrationTap, isNull);
    });

    testWidgets('an unreachable Track display ends the calibration', (
      tester,
    ) async {
      link.linked = false;
      await openCalibration(tester, 'track');
      expect(find.byType(TouchCalibrationPage), findsNothing);
      expect(client.calls, ['read readout']);
    });
  });
}
