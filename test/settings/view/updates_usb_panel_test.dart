import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/settings/view/updates_usb_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/usb/usb_update_cubit.dart';
import 'package:segno/update/usb/usb_update_package.dart';
import 'package:update_repository/update_repository.dart';

class _MockUsb extends MockCubit<UsbUpdateState> implements UsbUpdateCubit {}

/// Load from USB's panel (#1270 Part 8): each state says what it is.
void main() {
  late _MockUsb usb;

  setUp(() => usb = _MockUsb());

  Future<AppLocalizations> pump(
    WidgetTester tester,
    UsbUpdateState state,
  ) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    whenListen(usb, const Stream<UsbUpdateState>.empty(), initialState: state);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: BlocProvider<UsbUpdateCubit>.value(
            value: usb,
            child: SizedBox(
              width: 848,
              child: UpdatesUsbPanel(onClosed: () {}),
            ),
          ),
        ),
      ),
    );
    return AppLocalizations.of(tester.element(find.byType(UpdatesUsbPanel)));
  }

  testWidgets('no drive, reading and an empty drive each say so', (
    tester,
  ) async {
    var l10n = await pump(
      tester,
      const UsbUpdateState(phase: UsbUpdatePhase.noDrive),
    );
    expect(find.text(l10n.updatesUsbNoDrive), findsOneWidget);
    l10n = await pump(
      tester,
      const UsbUpdateState(phase: UsbUpdatePhase.reading),
    );
    expect(find.text(l10n.updatesUsbReading), findsOneWidget);
    l10n = await pump(
      tester,
      const UsbUpdateState(phase: UsbUpdatePhase.empty, driveLabel: 'STICK'),
    );
    expect(find.text(l10n.updatesUsbEmpty('STICK')), findsOneWidget);
  });

  testWidgets('a package row names its version, size and file; a press '
      'chooses it', (tester) async {
    final package = UsbUpdatePackage(
      generation: 1,
      path: '/media/1/segno-1.1.0.raucb',
      sizeBytes: 3 * 1024 * 1024 + 1,
      version: Version(1, 1, 0),
    );
    final l10n = await pump(
      tester,
      UsbUpdateState(phase: UsbUpdatePhase.list, packages: [package]),
    );
    expect(find.text('Segno 1.1.0'), findsOneWidget);
    expect(
      find.text('${l10n.updatesUsbMegabytes(4)} · segno-1.1.0.raucb'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('updates_usb_package_0')));
    verify(() => usb.choose(package)).called(1);
  });

  testWidgets('the copy shows progress with Cancel', (tester) async {
    final l10n = await pump(
      tester,
      const UsbUpdateState(phase: UsbUpdatePhase.copying),
    );
    expect(find.text(l10n.updatesUsbCopying), findsOneWidget);
    expect(find.byKey(const Key('updates_usb_progress')), findsOneWidget);
    await tester.tap(find.byKey(const Key('updates_usb_cancel_copy')));
    verify(() => usb.cancel()).called(1);
  });

  testWidgets('each failure says what happened', (tester) async {
    for (final (state, text)
        in <(UsbUpdateState, String Function(AppLocalizations))>[
          (
            const UsbUpdateState(
              phase: UsbUpdatePhase.failed,
              error: UsbUpdateError.unverified,
            ),
            (l) => l.updatesUsbUnverified,
          ),
          (
            UsbUpdateState(
              phase: UsbUpdatePhase.failed,
              error: UsbUpdateError.notNewer,
              refusedVersion: Version(0, 9, 0),
              installedVersion: Version(1, 0, 0),
            ),
            (l) => l.updatesUsbNotNewer('0.9.0', '1.0.0'),
          ),
          (
            const UsbUpdateState(
              phase: UsbUpdatePhase.failed,
              error: UsbUpdateError.removed,
            ),
            (l) => l.updatesUsbRemoved,
          ),
          (
            const UsbUpdateState(
              phase: UsbUpdatePhase.failed,
              error: UsbUpdateError.noSpace,
              neededBytes: 70 * 1024 * 1024,
            ),
            (l) => l.updatesUsbNoSpace(l.updatesUsbMegabytes(70)),
          ),
        ]) {
      final l10n = await pump(tester, state);
      expect(find.text(text(l10n)), findsOneWidget);
    }
  });
}
