import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/pedal/pedal.dart';

import '../../helpers/pump_app.dart';

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

    Future<void> pumpSection(WidgetTester tester, PedalCubit cubit) =>
        tester.pumpApp(
          BlocProvider.value(
            value: cubit,
            child: const Scaffold(body: PedalSettingsSection()),
          ),
        );

    testWidgets('the link status is a live region (WCAG 4.1.3)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final cubit = PedalCubit(pedal: PedalRepository(FakePedalLink()));
      addTearDown(cubit.close);
      await pumpSection(tester, cubit);

      final status = find.byKey(const Key('pedalSettings_status'));
      expect(status, findsOneWidget);
      expect(
        tester.getSemantics(status),
        matchesSemantics(isLiveRegion: true),
      );
      handle.dispose();
    });

    testWidgets('shows disconnected until the board says hello, then the '
        'firmware version', (tester) async {
      final link = FakePedalLink();
      final pedal = PedalRepository(link);
      final cubit = PedalCubit(pedal: pedal);
      addTearDown(cubit.close);
      await pumpSection(tester, cubit);
      expect(find.textContaining('not connected'), findsOneWidget);

      link.hello(firmwareMinor: 3);
      await tester.pump();
      expect(find.textContaining('1.3'), findsOneWidget);

      // Let the hello watchdog run out: the board goes quiet and the line
      // says so again. This also leaves no timer pending at teardown.
      await tester.pump(pedal.helloTimeout + const Duration(seconds: 1));
      expect(find.textContaining('not connected'), findsOneWidget);
    });

    testWidgets('names a board that speaks another link protocol', (
      tester,
    ) async {
      final link = FakePedalLink();
      final pedal = PedalRepository(link);
      final cubit = PedalCubit(pedal: pedal);
      addTearDown(cubit.close);
      await pumpSection(tester, cubit);

      link.emit(
        const HelloMessage(
          protocolVersion: PedalLinkCodec.protocolVersion + 1,
          firmwareMajor: 2,
          firmwareMinor: 1,
        ),
      );
      await tester.pump();
      expect(find.textContaining('different link protocol'), findsOneWidget);
      expect(find.textContaining('2.1'), findsOneWidget);
      await tester.pump(pedal.helloTimeout + const Duration(seconds: 1));
    });

    testWidgets('offers the footswitch assignments', (tester) async {
      final cubit = PedalCubit(pedal: PedalRepository(FakePedalLink()));
      addTearDown(cubit.close);
      await pumpSection(tester, cubit);
      expect(
        find.byKey(const Key('pedalSettings_openAssignments')),
        findsOneWidget,
      );
    });
  });
}
