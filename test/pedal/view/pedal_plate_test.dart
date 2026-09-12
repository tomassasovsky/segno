import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/common/pedal_color_display.dart';
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
  Map<PedalButton, PedalColor> colors = const {},
}) => PedalStateFrame.blank().copyWith(
  trackLeds: [
    for (var i = 0; i < PedalStateFrame.trackCount; i++)
      leds[i] ?? PedalTrackLed.off,
  ],
  activeBank: activeBank,
  selectedTrack: activeBank * 4,
  pedalColors: [
    for (final button in PedalButton.values)
      colors[button] ?? PedalColor.defaultColor,
  ],
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
              mode: InteractionMode.record,
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

  testWidgets('the frame lights an indicator and the palette colours it', (
    tester,
  ) async {
    await pumpPlate(
      tester,
      frame: _frame(
        leds: {0: PedalTrackLed.red, 1: PedalTrackLed.green},
        colors: const {
          PedalButton.track1: PedalColor.violet,
          PedalButton.track2: PedalColor.cyan,
          PedalButton.track3: PedalColor.red,
        },
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
    // What LIGHTS the indicator is the frame's own state; what colour it comes
    // up in is the performer's. Track 1 is recording and track 2 is playing —
    // the two states that used to be red and green, and are now each that
    // switch's own hue.
    expect(ledColor(0), PedalColor.violet.display);
    expect(ledColor(1), PedalColor.cyan.display);
    // Unlit: the dark dot, never a dimmed version of the configured colour.
    expect(ledColor(2), SurfaceTheme.dark.ledOff);
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

  testWidgets('the MODE LED is dark in the normal mode and the configured '
      'colour in every other one', (tester) async {
    Color modeColor(WidgetTester tester) =>
        (tester
                    .widget<Container>(
                      find.byKey(const Key('pedalFaceplate_led_mode')),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;

    const colors = {PedalButton.mode: PedalColor.amber};
    // Every mode, not only FX: the plate is the on-screen twin of both
    // sketches' `indicatorFor`, and a mode added to the wire with nothing said
    // about it here would light whatever the comparison fell through to.
    await pumpPlate(
      tester,
      frame: _frame(colors: colors).copyWith(mode: PedalMode.rec),
    );
    expect(modeColor(tester), SurfaceTheme.dark.ledOff);

    for (final mode in [PedalMode.play, PedalMode.fx, PedalMode.custom]) {
      await pumpPlate(
        tester,
        frame: _frame(colors: colors).copyWith(mode: mode),
      );
      expect(
        modeColor(tester),
        PedalColor.amber.display,
        reason: 'PedalMode.$mode',
      );
    }

    // The shutdown frame darkens it whatever mode it was in.
    await pumpPlate(
      tester,
      frame: _frame(
        colors: colors,
      ).copyWith(mode: PedalMode.fx, isGoodbye: true),
    );
    expect(modeColor(tester), SurfaceTheme.dark.ledOff);
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
