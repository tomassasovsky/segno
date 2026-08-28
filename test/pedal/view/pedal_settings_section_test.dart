import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:midi_client/midi_client.dart' show MidiDevice;
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/fake_key_value_store.dart';
import '../../helpers/pump_app.dart';
import '../helpers/fake_pedal_transport.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

void main() {
  group('PedalSettingsSection', () {
    late _MockLooperRepository looper;

    setUp(() {
      looper = _MockLooperRepository();
      when(
        () => looper.looperState,
      ).thenAnswer((_) => const Stream<LooperState>.empty());
    });

    PedalCubit cubitWith(FakePedalTransport transport) {
      final settings = SettingsRepository(store: FakeKeyValueStore());
      return PedalCubit(
        pedal: PedalRepository(transport),
        settings: settings,
        pollInterval: Duration.zero, // no hotplug timer in widget tests
      );
    }

    Future<void> pumpSection(WidgetTester tester, PedalCubit cubit) =>
        tester.pumpApp(
          BlocProvider.value(
            value: cubit,
            child: const Scaffold(body: PedalSettingsSection()),
          ),
        );

    testWidgets('the bind status is a live region (WCAG 4.1.3)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final cubit = cubitWith(
        FakePedalTransport(
          outputs: const [MidiDevice(id: 'out', name: 'Segno Pedal')],
        ),
      );
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);

      expect(
        tester.getSemantics(find.byKey(const Key('pedalSettings_status'))),
        isSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('selecting a device binds it and shows the bound status', (
      tester,
    ) async {
      final cubit = cubitWith(
        FakePedalTransport(
          outputs: const [MidiDevice(id: 'out', name: 'Segno Pedal')],
        ),
      );
      addTearDown(cubit.close);

      await pumpSection(tester, cubit);
      await cubit.selectOutput(
        const PedalOutput(id: 'out', name: 'Segno Pedal'),
      );
      await tester.pump();

      expect(cubit.state.bindStatus, PedalBindStatus.bound);
      expect(find.textContaining('Segno Pedal'), findsWidgets);
    });

    group('the firmware-update banner (flow err-4)', () {
      const bannerKey = Key('pedalSettings_firmwareUpdate_banner');

      /// A cubit with [device] bound, so the banner's "a pedal is actually
      /// connected" precondition holds.
      Future<PedalCubit> boundCubit(String device) async {
        final cubit = cubitWith(
          FakePedalTransport(
            outputs: [MidiDevice(id: device, name: 'Segno Pedal')],
          ),
        );
        await cubit.selectOutput(PedalOutput(id: device, name: 'Segno Pedal'));
        return cubit;
      }

      testWidgets('is absent while no pedal is bound', (tester) async {
        final cubit = cubitWith(FakePedalTransport());
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsNothing);
      });

      testWidgets('appears for a bound pedal with no version set', (
        tester,
      ) async {
        final cubit = await boundCubit('out');
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        // Unknown keeps the v2 floor, so FX mode is degraded on the wire —
        // the banner explains why rather than leaving it looking broken.
        expect(find.byKey(bannerKey), findsOneWidget);
        expect(find.text('Pedal firmware update available'), findsOneWidget);
      });

      testWidgets('appears for a bound pedal pinned below v3', (tester) async {
        final cubit = await boundCubit('out');
        addTearDown(cubit.close);
        await cubit.selectFirmwareVersion(PedalCodec.protocolVersionV1);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsOneWidget);
      });

      testWidgets('never appears for the on-screen pedal', (tester) async {
        // It renders in this build — there is no firmware behind it to be
        // out of date, and it already encodes at the codec max.
        final cubit = await boundCubit(kSimulatorOutputId);
        addTearDown(cubit.close);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsNothing);
      });

      testWidgets('disappears once the pedal is known to speak the newest '
          'protocol', (tester) async {
        final cubit = await boundCubit('out');
        addTearDown(cubit.close);
        await cubit.selectFirmwareVersion(PedalCodec.protocolVersionMax);

        await pumpSection(tester, cubit);

        expect(find.byKey(bannerKey), findsNothing);
      });
    });

  });
}
