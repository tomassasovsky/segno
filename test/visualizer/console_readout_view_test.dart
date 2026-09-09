import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/performance_readout.dart';

void main() {
  group('readoutTempo', () {
    test('drops the decimal on a whole tempo, keeps one otherwise', () {
      expect(readoutTempo(84), '84');
      expect(readoutTempo(84.02), '84');
      expect(readoutTempo(84.5), '84.5');
      expect(readoutTempo(120.25), '120.3');
    });
  });

  group('readoutMeterStateOf', () {
    test("resolves the selected track's state, muted overlaying it", () {
      expect(
        readoutMeterStateOf(
          const ReadoutTrack(channel: 0, name: 'T', state: 'playing'),
        ),
        LooperMeterState.playing,
      );
      expect(
        readoutMeterStateOf(
          const ReadoutTrack(
            channel: 0,
            name: 'T',
            state: 'playing',
            muted: true,
          ),
        ),
        LooperMeterState.muted,
      );
    });

    test('reads none, or an unknown token, as empty rather than throwing', () {
      expect(readoutMeterStateOf(null), LooperMeterState.empty);
      expect(
        readoutMeterStateOf(
          const ReadoutTrack(channel: 0, name: 'T', state: 'transmogrifying'),
        ),
        LooperMeterState.empty,
      );
    });
  });

  group('ConsoleReadoutView', () {
    const selected = ReadoutTrack(
      channel: 0,
      name: 'Acoustic rhythm guitar',
      state: 'playing',
      primary: true,
      bars: 2,
      layers: 4,
      lengthFrames: 96000,
    );
    const readout = PerformanceReadout(
      selected: selected,
      tempoBpm: 84,
      hasTempo: true,
      isRunning: true,
    );

    Future<void> pump(
      WidgetTester tester, {
      PerformanceReadout readout = readout,
      Size size = const Size(1280, 720),
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              AppTextDefaults(child: child ?? const SizedBox.shrink()),
          home: Scaffold(
            body: ConsoleReadoutView(
              readout: readout,
              waveform: const ColoredBox(
                key: Key('test_waveform'),
                color: Colors.transparent,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('names the selected track: number, crown, name', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('1'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_crown')), findsOneWidget);
      expect(find.text('Acoustic rhythm guitar'), findsOneWidget);
    });

    testWidgets('shows the crown only when the selected track is primary', (
      tester,
    ) async {
      await pump(
        tester,
        readout: const PerformanceReadout(
          selected: ReadoutTrack(channel: 1, name: 'Lead', state: 'playing'),
        ),
      );
      expect(find.byKey(const Key('console_readout_crown')), findsNothing);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('reads the state word in the state colour and the bars', (
      tester,
    ) async {
      await pump(tester);
      final state = tester.widget<AppText>(
        find.byKey(const Key('console_readout_state')),
      );
      expect(state.data, 'Playing');
      expect(
        state.style!.color,
        AppTheme.neon.extension<LooperTheme>()!.waveformColor(
          LooperMeterState.playing,
        ),
      );
      expect(find.text('2 bars'), findsOneWidget);
    });

    testWidgets('an empty track says so and counts no bars', (tester) async {
      await pump(
        tester,
        readout: const PerformanceReadout(
          selected: ReadoutTrack(channel: 3, name: 'Lead', state: 'empty'),
        ),
      );
      expect(find.text('Empty'), findsOneWidget);
      expect(find.byKey(const Key('console_readout_bars')), findsNothing);
    });

    testWidgets('localizes a default track name', (tester) async {
      await pump(
        tester,
        readout: const PerformanceReadout(
          selected: ReadoutTrack(
            channel: 2,
            name: 'TRACK 3',
            state: 'stopped',
            defaultName: true,
          ),
        ),
      );
      expect(find.text('TRACK 3'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('keeps the waveform as the strip between header and footer', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('test_waveform')), findsOneWidget);
      final wave = tester.getRect(find.byKey(const Key('test_waveform')));
      final state = tester.getRect(
        find.byKey(const Key('console_readout_state')),
      );
      final footer = tester.getRect(
        find.byKey(const Key('console_readout_tempo')),
      );
      expect(wave.top, greaterThan(state.bottom));
      expect(wave.bottom, lessThan(footer.top));
    });

    testWidgets('the footer carries the tempo, signature and function · bank', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('84'), findsOneWidget);
      expect(find.text('4/4'), findsOneWidget);
      expect(find.text('Tracks · Bank A'), findsOneWidget);
    });

    testWidgets('the footer names Mute and FX as the current function', (
      tester,
    ) async {
      await pump(tester, readout: readout.copyWithMode('mute', bank: 1));
      expect(find.text('Mute · Bank B'), findsOneWidget);
      await pump(tester, readout: readout.copyWithMode('fx', bank: 1));
      expect(find.text('FX · Bank B'), findsOneWidget);
    });

    testWidgets('shows — for the tempo on the tempo-free path', (
      tester,
    ) async {
      await pump(
        tester,
        readout: const PerformanceReadout(selected: selected),
      );
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('with no track selected the header says so', (tester) async {
      await pump(tester, readout: const PerformanceReadout());
      expect(find.byKey(const Key('console_readout_noTrack')), findsOneWidget);
      expect(find.byKey(const Key('console_readout_name')), findsNothing);
    });

    testWidgets('nothing on the face takes a tap', (tester) async {
      await pump(tester);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(GestureDetector), findsNothing);
    });

    group('connectivity echo (#453)', () {
      testWidgets('absent while nothing is lost', (tester) async {
        await pump(tester);
        expect(
          find.byKey(const Key('console_readout_deviceLost')),
          findsNothing,
        );
      });

      testWidgets('echoes the device-lost line while the interface is gone', (
        tester,
      ) async {
        await pump(
          tester,
          readout: const PerformanceReadout(
            selected: selected,
            deviceLost: true,
          ),
        );
        expect(
          find.byKey(const Key('console_readout_deviceLost')),
          findsOneWidget,
        );
      });
    });

    testWidgets('survives the 7" panel\'s narrower aspect without overflow', (
      tester,
    ) async {
      await pump(
        tester,
        size: const Size(1024, 600),
        readout: const PerformanceReadout(
          selected: ReadoutTrack(
            channel: 7,
            name: 'A deliberately very long track name that keeps going',
            state: 'overdubbing',
            primary: true,
            bars: 64,
            layers: 12,
          ),
          tempoBpm: 300,
          hasTempo: true,
          tsNum: 15,
          tsDen: 16,
          mode: 'mute',
          activeBank: 1,
          deviceLost: true,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

extension on PerformanceReadout {
  PerformanceReadout copyWithMode(String mode, {required int bank}) =>
      PerformanceReadout(
        selected: selected,
        tempoBpm: tempoBpm,
        hasTempo: hasTempo,
        tsNum: tsNum,
        tsDen: tsDen,
        isRunning: isRunning,
        mode: mode,
        activeBank: bank,
        deviceLost: deviceLost,
        goodbye: goodbye,
      );
}
