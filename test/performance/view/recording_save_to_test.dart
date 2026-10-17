import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/performance/cubit/recording_destination_cubit.dart';
import 'package:segno/performance/view/recording_save_to.dart';
import 'package:storage_repository/storage_repository.dart';

import '../../helpers/helpers.dart';
import '../../storage/helpers/storage_rig.dart';

class _MockRecorder extends MockCubit<PerformanceRecorderState>
    implements PerformanceRecorderCubit {}

void main() {
  group(RecordingSaveTo, () {
    late StorageRig rig;
    late RecordingDestinationCubit destination;
    late _MockRecorder recorder;

    Future<AppLocalizations> pump(
      WidgetTester tester, {
      PerformanceRecorderState recording = const PerformanceRecorderIdle(),
    }) async {
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      rig = StorageRig();
      destination = RecordingDestinationCubit(
        repository: rig.repository,
        sampleRate: () => 48000,
      );
      recorder = _MockRecorder();
      when(() => recorder.state).thenReturn(recording);
      // unawaited: awaiting a close inside a testWidgets body deadlocks on the
      // binding's stream cancellation (flutter/flutter#139870).
      addTearDown(() => unawaited(destination.close()));
      addTearDown(() => unawaited(rig.dispose()));
      await tester.pumpApp(
        MultiBlocProvider(
          providers: [
            BlocProvider.value(value: destination),
            BlocProvider<PerformanceRecorderCubit>.value(value: recorder),
          ],
          child: const Scaffold(body: RecordingSaveTo()),
        ),
      );
      await tester.pumpAndSettle();
      return AppLocalizations.of(tester.element(find.byType(Scaffold)));
    }

    testWidgets('USB with no drive opens Connect a USB drive; Cancel closes '
        'it and the take stays on Internal', (tester) async {
      final l10n = await pump(tester);

      await tester.tap(find.byKey(const Key('save_to_connect_usb')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.connectUsbTitle), findsOneWidget);
      expect(find.text(l10n.connectUsbBody), findsOneWidget);

      await tester.tap(find.byKey(const Key('connect_usb_cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connect_usb_sheet')), findsNothing);
      expect(
        destination.state.destination,
        const StorageDestination.internal(),
      );
      expect(destination.state.awaitingDrive, isFalse);
    });

    testWidgets('a drive plugged while the sheet is up closes it and is '
        'chosen', (tester) async {
      await pump(tester);

      await tester.tap(find.byKey(const Key('save_to_connect_usb')));
      await tester.pumpAndSettle();
      // Try again with nothing plugged keeps waiting.
      await tester.tap(find.byKey(const Key('connect_usb_try_again')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connect_usb_sheet')), findsOneWidget);

      rig.client.attach(usbRecord(1));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('connect_usb_sheet')), findsNothing);
      expect(
        destination.state.destination,
        const StorageDestination.removable(1),
      );
      expect(find.byKey(const Key('save_to_usb_1')), findsOneWidget);
    });

    testWidgets('while a take records the choice is locked', (tester) async {
      final l10n = await pump(
        tester,
        recording: const PerformanceRecorderArmed(
          elapsed: Duration(seconds: 5),
          overrun: false,
        ),
      );

      expect(find.byKey(const Key('save_to_chosen')), findsOneWidget);
      expect(find.text(l10n.storageInternalTitle), findsOneWidget);
      expect(find.byKey(const Key('save_to_connect_usb')), findsNothing);
    });
  });
}
