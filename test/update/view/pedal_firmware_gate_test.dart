import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/pedal_firmware_cubit.dart';
import 'package:segno/update/view/pedal_firmware_gate.dart';
import 'package:update_repository/update_repository.dart';

/// Drives the real cubit rather than a stand-in, so these assertions are about
/// what a user would actually see for a given helper response.
class _FakeBackend implements PlatformUpdateBackend {
  _FakeBackend({this.pending, this.flashError, this.failureClass});

  final String? pending;
  final Object? flashError;
  final PedalFlashFailureClass? failureClass;
  final progress = StreamController<double>();

  @override
  bool get isSupported => true;

  @override
  Future<String?> pendingPedalFirmware() async => pending;

  @override
  Stream<double> flashPedalFirmware() {
    if (flashError != null) return Stream.error(flashError!);
    return progress.stream;
  }

  @override
  Future<PedalFlashFailureClass?> lastPedalFlashFailure() async => failureClass;

  int abortCalls = 0;

  @override
  Future<void> abortPedalFlash() async {
    abortCalls++;
  }

  @override
  String get channel => 'experimental';

  @override
  Future<void> setChannel(String channel) async {}

  @override
  Future<Version> currentVersion() async => Version.none;

  @override
  Future<Version> stagedVersion() async => Version.none;

  @override
  Future<UpdateManifest?> fetchManifest() async => null;

  @override
  Stream<double> downloadAndStage(UpdateManifest manifest) =>
      const Stream.empty();

  @override
  Future<void> applyAndRestart() async {}
}

void main() {
  Future<PedalFirmwareCubit> pumpGate(
    WidgetTester tester,
    _FakeBackend backend,
  ) async {
    final cubit = PedalFirmwareCubit(
      updates: UpdateRepository(backend: backend),
    );
    // Guarded, because a test that closes the cubit itself must not close it
    // twice: the second close returns the done future the FIRST one created
    // inside the widget-test fake-async zone, and nothing drives that zone
    // once the body is over — the tear-down would hang forever.
    addTearDown(() async {
      if (!cubit.isClosed) await cubit.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BlocProvider<PedalFirmwareCubit>.value(
          value: cubit,
          child: const PedalFirmwareGate(
            child: Text('looper', key: Key('looper')),
          ),
        ),
      ),
    );
    return cubit;
  }

  testWidgets('draws nothing while the answer is still unknown', (
    tester,
  ) async {
    // The check resolves in milliseconds on desktop; flashing a screen for it
    // would be worse than not having one.
    await pumpGate(tester, _FakeBackend());

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });

  testWidgets('nothing pending leaves the looper alone', (tester) async {
    final cubit = await pumpGate(tester, _FakeBackend());

    await cubit.run();
    await tester.pump();

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });

  testWidgets('shows progress and seals the looper off while flashing', (
    tester,
  ) async {
    final backend = _FakeBackend(pending: '0.4.0');
    final cubit = await pumpGate(tester, backend);

    unawaited(cubit.run());
    await tester.pump();
    await tester.pump();
    backend.progress.add(0.4);
    await tester.idle();
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.pedalFirmwareGateTitle), findsOneWidget);
    expect(find.textContaining('0.4.0'), findsOneWidget);
    // The pen's `firmware-gate` draws a 31px progress ring, determinate — the
    // helper reports PROGRESS from 0, and a ring that sits still is more
    // honest than a spinner.
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byKey(const Key('pedal_firmware_gate_progress')),
          )
          .value,
      0.4,
    );
    // The face is the console's dialog shell at the pen's 552 width, not a
    // hand-rolled card.
    final shell = tester.widget<ConsoleDialogShell>(
      find.byKey(const Key('pedal_firmware_gate')),
    );
    expect(shell.width, 552);
    // A non-dismissible barrier, not just a panel drawn on top: a stray tap on
    // a transport control while the pedal is in its bootloader must not reach
    // the looper.
    final barrier = tester.widget<ModalBarrier>(
      find.byKey(const Key('pedal_firmware_gate_barrier')),
    );
    expect(barrier.dismissible, isFalse);

    await backend.progress.close();
  });

  testWidgets('the gate brings its own Material', (tester) async {
    // The gate wraps the looper from `home:`, so it renders ABOVE the page's
    // Scaffold and inherits no Material. Without one of its own the text falls
    // back to the debug style and the button has nothing to paint on — which
    // is exactly how it shipped and what the console showed (#456).
    final backend = _FakeBackend(pending: '0.4.0');
    final cubit = await pumpGate(tester, backend);

    unawaited(cubit.run());
    await tester.pump();
    await tester.pump();

    expect(
      find.ancestor(
        of: find.byKey(const Key('pedal_firmware_gate')),
        matching: find.byType(Material),
      ),
      findsWidgets,
    );

    await backend.progress.close();
  });

  testWidgets('a failure explains itself and lets the user through', (
    tester,
  ) async {
    final cubit = await pumpGate(
      tester,
      _FakeBackend(
        pending: '0.4.0',
        flashError: Exception('avrdude failed'),
        // The write never began, so the comforting body is the true one.
        failureClass: PedalFlashFailureClass.notStarted,
      ),
    );

    await cubit.run();
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.pedalFirmwareGateFailedTitle), findsOneWidget);
    expect(find.text(l10n.pedalFirmwareGateFailedBody), findsOneWidget);
    expect(find.byKey(const Key('pedal_firmware_gate_progress')), findsNothing);

    // Continue is the pen's accent action — outlined and lettered in the
    // accent, not solid: it commits nothing, it only lets the user through.
    final continueButton = tester.widget<ConsoleDialogButton>(
      find.byKey(const Key('pedal_firmware_gate_continue')),
    );
    expect(continueButton.tone, ConsoleDialogTone.accent);
    expect(continueButton.label, l10n.pedalFirmwareGateContinue);

    await tester.tap(find.byKey(const Key('pedal_firmware_gate_continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });

  testWidgets('disposing mid-flash leaves no pending stall timer', (
    tester,
  ) async {
    // testWidgets itself fails on any timer still armed at the end of the
    // test, so this test IS the assertion that close() disarms the 6-minute
    // stall guard when the tree goes down mid-flash.
    final backend = _FakeBackend(pending: '0.4.0');
    final cubit = await pumpGate(tester, backend);

    unawaited(cubit.run());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('pedal_firmware_gate')), findsOneWidget);

    // Tear the tree down first, as the framework does on shutdown, THEN
    // close. The close is deliberately NOT awaited inline: under the
    // widget-test fake clock nothing drains the microtask queue while the test
    // body is suspended, so `await cubit.close()` here deadlocks the whole
    // suite (the same stream-cancel gotcha the repo's testWidgets notes
    // document). `pump()` drives the zone instead.
    await tester.pumpWidget(const SizedBox());
    unawaited(cubit.close());
    await tester.pump();

    // The helper is killed rather than left flashing unsupervised.
    expect(backend.abortCalls, 1);
    // Not awaited: the gate's subscription is already cancelled, so the
    // controller's done future has no listener to wait on.
    unawaited(backend.progress.close());
  });

  testWidgets('an interrupted flash gets the honest copy, not comfort', (
    tester,
  ) async {
    // Once a write began, "your pedal still works on its previous firmware"
    // is false in exactly the worst case — the pedal may be parked in its
    // bootloader with the old firmware already erased. The body must say what
    // actually happened.
    final cubit = await pumpGate(
      tester,
      _FakeBackend(
        pending: '0.4.0',
        flashError: Exception('avrdude failed'),
        failureClass: PedalFlashFailureClass.interrupted,
      ),
    );

    await cubit.run();
    await tester.pump();

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.pedalFirmwareGateFailedTitle), findsOneWidget);
    expect(
      find.text(l10n.pedalFirmwareGateFailedInterruptedBody),
      findsOneWidget,
    );
    expect(find.text(l10n.pedalFirmwareGateFailedBody), findsNothing);

    // Continue still lets the user through — the gate informs, it does not
    // imprison.
    await tester.tap(find.byKey(const Key('pedal_firmware_gate_continue')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pedal_firmware_gate')), findsNothing);
    expect(find.byKey(const Key('looper')), findsOneWidget);
  });
}
