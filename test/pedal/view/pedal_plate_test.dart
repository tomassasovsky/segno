import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/theme/theme.dart';

const _recPlayKey = Key('pedalFaceplate_footswitch_recPlay');
const _mainScreenKey = Key('mainScreen');
const _waveformScreenKey = Key('waveformScreen');

PedalStateFrame _frame({
  int activeBank = 0,
  Map<int, PedalTrackLed> leds = const {},
  int activeButtonMask = 0,
  List<PedalColor>? pedalColors,
}) => PedalStateFrame.blank().copyWith(
  trackLeds: [
    for (var i = 0; i < PedalStateFrame.trackCount; i++)
      leds[i] ?? PedalTrackLed.off,
  ],
  activeBank: activeBank,
  selectedTrack: activeBank * 4,
  activeButtonMask: activeButtonMask,
  pedalColors: pedalColors,
);

void main() {
  /// Pumps [PedalPlate] with no transport, cubit, or bloc providers — only the
  /// theme/localization scaffolding every widget under test needs.
  Future<
    (
      List<({PedalButton button, bool down})>,
      List<int>,
      bool Function(),
    )
  >
  pumpPlate(
    WidgetTester tester, {
    PedalStateFrame? frame,
    InteractionMode mode = InteractionMode.record,
    Set<PedalButton> selected = const {},
  }) async {
    final presses = <({PedalButton button, bool down})>[];
    final turns = <int>[];
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: Builder(
          builder: (context) => Scaffold(
            body: PedalPlate(
              frame: frame ?? _frame(),
              trackNames: const ['drums', 'bass', 'rhythm', 'lead'],
              onPress: (button, {required down}) =>
                  presses.add((button: button, down: down)),
              onTurn: turns.add,
              mode: mode,
              l10n: AppLocalizations.of(context),
              mainScreen: const SizedBox(key: _mainScreenKey),
              waveformScreen: const SizedBox(key: _waveformScreenKey),
              onClose: () => closed = true,
              selected: selected,
            ),
          ),
        ),
      ),
    );
    return (presses, turns, () => closed);
  }

  testWidgets('pumps standalone with no transport/cubit/bloc providers', (
    tester,
  ) async {
    await pumpPlate(tester);
    expect(find.byKey(_mainScreenKey), findsOneWidget);
    expect(find.byKey(_waveformScreenKey), findsOneWidget);
    expect(find.byKey(_recPlayKey), findsOneWidget);
  });

  testWidgets('physical activity and hue drive LEDs, not logical track state', (
    tester,
  ) async {
    await pumpPlate(
      tester,
      frame: _frame(
        leds: {2: PedalTrackLed.red},
        activeButtonMask: 0x30,
        pedalColors: [
          for (var i = 0; i < 10; i++)
            if (i == 4)
              const PedalColor(219, 24, 62)
            else
              const PedalColor(47, 208, 96),
        ],
      ),
    );

    Color ledColor(int channel) =>
        (tester
                    .widget<Container>(
                      find.byKey(Key('pedalFaceplate_led_track$channel')),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    expect(ledColor(0), const Color(0xFFDB183E));
    expect(ledColor(1), const Color(0xFF2FD060));
    expect(ledColor(2), SurfaceTheme.dark.ledOff);
  });

  testWidgets('Custom LED labels describe active state, not assignment', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpPlate(
      tester,
      mode: InteractionMode.custom,
      frame: _frame(activeButtonMask: 0x10),
    );
    expect(find.bySemanticsLabel('drums, action active'), findsOneWidget);
    expect(find.bySemanticsLabel('bass, action inactive'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('onPress fires with the pressed button on down and up', (
    tester,
  ) async {
    final (presses, _, _) = await pumpPlate(tester);
    await tester.tap(find.byKey(_recPlayKey));
    await tester.pump();

    expect(presses, [
      (button: PedalButton.recPlay, down: true),
      (button: PedalButton.recPlay, down: false),
    ]);
  });

  testWidgets('onTurn fires with the drag-derived detent delta', (
    tester,
  ) async {
    final (_, turns, _) = await pumpPlate(tester);
    await tester.drag(
      find.byKey(const Key('pedalFaceplate_encoder')),
      const Offset(30, 0),
    );
    await tester.pump();

    // A rightward drag turns the encoder forward (positive detents); the
    // exact detent math is the widget's own business, so this only asserts
    // the direction and that something reached onTurn.
    expect(turns, isNotEmpty);
    expect(turns, everyElement(1));
  });

  testWidgets('onClose fires from the close button', (tester) async {
    final (_, _, isClosed) = await pumpPlate(tester);
    await tester.tap(find.byType(CloseButton));
    expect(isClosed(), isTrue);
  });

  testWidgets('the ring breathes green once the loop is cleared', (
    tester,
  ) async {
    Color ringBorderColor(WidgetTester tester) =>
        ((tester
                            .widget<Container>(
                              find.byKey(const Key('pedalFaceplate_encoder')),
                            )
                            .decoration!
                        as BoxDecoration)
                    .border!
                as Border)
            .top
            .color;

    // Recording a loop: the rim wears the red activity colour.
    await pumpPlate(
      tester,
      frame: _frame().copyWith(
        globalColor: GlobalColor.red,
        loopLengthMicros: 1000000,
      ),
    );
    expect(ringBorderColor(tester), SurfaceTheme.dark.ledRed);

    // Cleared (activity off, no loop left): the ring breathes green, so the
    // rim is green rather than dark.
    await pumpPlate(tester, frame: _frame());
    expect(ringBorderColor(tester), SurfaceTheme.dark.ledGreen);
  });

  testWidgets('a mode value cannot override the physical mask or saved hue', (
    tester,
  ) async {
    for (final mode in PedalMode.values) {
      await pumpPlate(
        tester,
        frame: _frame(activeButtonMask: 0x08).copyWith(mode: mode),
      );
      final led = tester.widget<Container>(
        find.byKey(const Key('pedalFaceplate_led_mode')),
      );
      expect((led.decoration! as BoxDecoration).color, Colors.white);
    }
    await pumpPlate(
      tester,
      frame: _frame().copyWith(mode: PedalMode.custom),
    );
    final off = tester.widget<Container>(
      find.byKey(const Key('pedalFaceplate_led_mode')),
    );
    expect((off.decoration! as BoxDecoration).color, SurfaceTheme.dark.ledOff);
  });

  testWidgets('all ten pills use their own bit, and Goodbye darkens them', (
    tester,
  ) async {
    const names = [
      'recPlay',
      'stop',
      'undo',
      'mode',
      'track0',
      'track1',
      'track2',
      'track3',
      'clear',
      'bank',
    ];
    final colors = [
      for (var i = 0; i < 10; i++) PedalColor(20 + i, 60 + i, 100 + i),
    ];
    Color color(int index) =>
        (tester
                    .widget<Container>(
                      find.byKey(Key('pedalFaceplate_led_${names[index]}')),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    for (var active = 0; active < 10; active++) {
      await pumpPlate(
        tester,
        frame: _frame(
          activeButtonMask: 1 << active,
          pedalColors: colors,
        ),
        selected: {PedalButton.values[(active + 1) % 10]},
      );
      for (var index = 0; index < 10; index++) {
        expect(
          color(index),
          index == active
              ? Color.fromARGB(255, 20 + index, 60 + index, 100 + index)
              : SurfaceTheme.dark.ledOff,
        );
      }
    }
    await pumpPlate(
      tester,
      frame: _frame(
        activeButtonMask: 0x3ff,
        pedalColors: colors,
      ).copyWith(isGoodbye: true),
    );
    for (var index = 0; index < 10; index++) {
      expect(color(index), SurfaceTheme.dark.ledOff);
    }
  });

  group('selection state', () {
    Border footswitchBorder(WidgetTester tester, Key key) =>
        (tester.widget<Container>(find.byKey(key)).decoration! as BoxDecoration)
                .border!
            as Border;

    testWidgets('empty selection renders identically to no selection', (
      tester,
    ) async {
      await pumpPlate(tester);
      final border = footswitchBorder(tester, _recPlayKey);
      expect(border.top.color, SurfaceTheme.dark.line);
      expect(border.top.width, 1);
    });

    testWidgets('a selected button renders highlighted', (tester) async {
      await pumpPlate(tester, selected: {PedalButton.recPlay});
      final border = footswitchBorder(tester, _recPlayKey);
      expect(border.top.color, SurfaceTheme.dark.accent);

      // Only the selected button is highlighted — a sibling switch is
      // unaffected.
      final undoBorder = footswitchBorder(
        tester,
        const Key('pedalFaceplate_footswitch_undo'),
      );
      expect(undoBorder.top.color, SurfaceTheme.dark.line);
    });
  });
}
