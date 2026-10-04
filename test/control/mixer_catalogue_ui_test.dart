import 'package:controller_repository/controller_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routing_graph/routing_graph.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/external_controls.dart';
import 'package:segno/control/binding/external_expression.dart';
import 'package:segno/control/view/control_value_readout.dart';
import 'package:segno/control/view/midi_controls/midi_control_cards.dart';
import 'package:segno/control/view/pedal_setup/expression_controls_panel.dart';
import 'package:segno/control/view/pedal_setup/external_controls_editor.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

void main() {
  Future<void> pumpPanel(WidgetTester tester, Widget child) async {
    tester.view
      ..physicalSize = const Size(1800, 1200)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('all eight Mixer endpoints display the physical unit', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    const gains = <MixValueTarget>[
      TrackVolumeTarget(0),
      LaneVolumeTarget(0, 1),
    ];
    for (final target in gains) {
      expect(controlValueReadout(l10n, target, 0.5), '−27.0 dB');
      expect(controlValueReadout(l10n, target, 0), '−∞');
      expect(controlValueReadout(l10n, target, 1), '+6.0 dB');
    }
    for (final (position, label) in [
      (0.0, '0%'),
      (0.5, '50%'),
      (1.0, '100%'),
    ]) {
      expect(
        controlValueReadout(l10n, const MonitorVolumeTarget(0), position),
        label,
      );
    }
    for (final target in <MixValueTarget>[
      const TrackPanTarget(0),
      const InputPanTarget(0),
      const PairBalanceTarget(0),
      const OutputBalanceTarget(0),
    ]) {
      expect(controlValueReadout(l10n, target, 0), '100% left');
      expect(controlValueReadout(l10n, target, 0.5), 'Center');
      expect(controlValueReadout(l10n, target, 1), '100% right');
    }
    expect(
      controlValueReadout(l10n, const OutputLevelTarget(0), 0.75),
      '75%',
    );
  });

  test('Click endpoints show percent of physical unity', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    for (final (position, label) in <(double, String)>[
      (0, '0%'),
      (0.125, '25%'),
      (0.5, '100%'),
      (0.75, '150%'),
      (1, '200%'),
    ]) {
      expect(
        controlValueReadout(l10n, const ClickVolumeTarget(), position),
        label,
      );
    }
  });

  test('Hear click endpoints show named modes, never a percent', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    for (final (position, label) in <(double, String)>[
      (0, l10n.loopClickOff),
      (1 / 3, l10n.loopClickFirst),
      (2 / 3, l10n.loopClickRecording),
      (1, l10n.loopClickAlways),
    ]) {
      expect(
        controlValueReadout(l10n, const ClickModeValueTarget(), position),
        label,
      );
    }
  });

  test('Count-in endpoints name Off, 1, 2 and 4 bars', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    for (final (position, label) in <(double, String)>[
      (0, 'Off'),
      (1 / 3, '1 bar'),
      (2 / 3, '2 bars'),
      (1, '4 bars'),
    ]) {
      expect(
        controlValueReadout(l10n, const CountInValueTarget(), position),
        label,
      );
    }
  });

  testWidgets('expression endpoint shows Mixer gain in dB', (tester) async {
    const target = TrackVolumeTarget(0);
    final semantics = tester.ensureSemantics();
    await pumpPanel(
      tester,
      ExpressionControlsPanel(
        rows: [
          ExpressionRow(
            mapping: ExpressionMapping(target: target, heel: 0.5),
            destination: 'Track 1',
            control: 'Volume',
            available: true,
          ),
        ],
        selected: target,
        position: null,
        onSelect: (_) {},
        onAdd: () {},
        onChange: () {},
        onRemove: () {},
        onEndpoint: ({required isHeel, required value}) {},
        onEndpointCancel: ({required isHeel, required value}) {},
      ),
    );

    expect(find.text('−27.0 dB'), findsOneWidget);
    expect(find.text('+6.0 dB'), findsOneWidget);
    expect(find.text('50%'), findsNothing);

    final slider = find.byKey(const Key('expression_endpoint_heel'));
    expect(tester.getSemantics(slider).value, '−27.0 dB');
    final gesture = find.descendant(
      of: slider,
      matching: find.byType(GestureDetector),
    );
    Focus.of(tester.element(gesture.first)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.getSemantics(slider).value, '−26.3 dB');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.getSemantics(slider).value, '−27.0 dB');
    semantics.dispose();
  });

  testWidgets('Click endpoint text and semantics use percent of unity', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpPanel(
      tester,
      ExpressionControlsPanel(
        rows: [
          ExpressionRow(
            mapping: ExpressionMapping(
              target: const ClickVolumeTarget(),
              heel: 0.5,
            ),
            destination: 'Click',
            control: 'Volume',
            available: true,
          ),
        ],
        selected: const ClickVolumeTarget(),
        position: null,
        onSelect: (_) {},
        onAdd: () {},
        onChange: () {},
        onRemove: () {},
        onEndpoint: ({required isHeel, required value}) {},
        onEndpointCancel: ({required isHeel, required value}) {},
      ),
    );
    final heel = find.byKey(const Key('expression_endpoint_heel'));
    final toe = find.byKey(const Key('expression_endpoint_toe'));
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('200%'), findsOneWidget);
    expect(tester.getSemantics(heel).value, '100%');
    expect(tester.getSemantics(toe).value, '200%');
    semantics.dispose();
  });

  testWidgets('external button endpoints show pan placement', (tester) async {
    const target = TrackPanTarget(0);
    await pumpPanel(
      tester,
      ExternalControlsEditor(
        rows: [
          ExternalControlRow.parameter(
            parameter: ExternalParameter(
              target: target,
              active: 0.5,
              inactive: 0,
            ),
            destination: 'Track 1',
            name: 'Pan',
            available: true,
          ),
        ],
        selected: target,
        latching: false,
        onSelect: (_) {},
        onAdd: () {},
        onChange: () {},
        onRemove: () {},
        onCondition: (_) {},
        onValueCondition: (_) {},
        onValue: ({required active, required value}) {},
      ),
    );

    expect(find.text('Center'), findsWidgets);
    expect(find.text('100% left'), findsOneWidget);
    expect(find.text('50%'), findsNothing);
  });

  testWidgets('MIDI endpoints use the same gain law as External', (
    tester,
  ) async {
    const target = LaneVolumeTarget(0, 1);
    await pumpPanel(
      tester,
      MidiControlCards(
        cards: [
          MidiControlCard(
            control: MidiParameterControl(
              key: target.canonicalString(),
              low: 0.5,
              high: 1,
            ),
            label: 'Lane 2 volume',
            available: true,
          ),
        ],
        behavior: MidiBehavior.continuous,
        program: false,
        onAdd: () {},
        onChange: (_) {},
        onRemove: (_) {},
        onRange: (_, {low, high}) {},
        onTrigger: (_, _) {},
      ),
    );

    expect(find.text('−27.0 dB'), findsOneWidget);
    expect(find.text('+6.0 dB'), findsOneWidget);
    expect(find.text('50%'), findsNothing);
  });
}
