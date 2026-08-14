import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
import 'package:segno/looper/view/signal/fx_param_editor.dart';
import 'package:segno/looper/view/signal/fx_param_tile.dart';
import 'package:segno/looper/view/signal/signal_fx_editor.dart';
import 'package:segno/theme/theme.dart';

class _FakeScope extends Fake implements FxScope {
  _FakeScope(this.chain, {this.chainOn = true, this.formatted});

  /// The sheet's breadcrumb names the chain, so the fake has to have one.
  @override
  String label(AppLocalizations l10n) => 'Input 1';

  List<TrackEffect> chain;
  bool chainOn;
  String? formatted;

  /// The live instance's own string, by chain position.
  final Map<int, String> formattedPerEntry = {};

  final List<(int, int, double)> pluginWrites = [];
  final List<(int, int, double)> builtInWrites = [];

  /// Entries whose own editor window was asked for.
  final List<int> opened = [];

  /// Relinks, as (entry, what it was pointed at).
  final List<(int, PluginRef)> relinked = [];

  @override
  List<TrackEffect> get effects => chain;

  @override
  bool get chainEnabled => chainOn;

  @override
  void setPluginParam(int index, int paramId, double value) =>
      pluginWrites.add((index, paramId, value));

  @override
  void setParam(int index, int param, double value) =>
      builtInWrites.add((index, param, value));

  @override
  void openPluginEditor(int index) => opened.add(index);

  @override
  void relinkPlugin(int index, PluginRef ref) => relinked.add((index, ref));

  /// Per ENTRY, deliberately: a fake that ignores the index cannot tell the
  /// sheet formatting through the entry it edits from the sheet formatting
  /// through whatever happens to sit at that position.
  @override
  String? formatPluginValue(int index, int paramId, double value) =>
      formattedPerEntry[index] ?? formatted;
}

/// A filter frequency: the shape that made the unit bug destructive — a plain
/// range far outside the `0..1` a normalized control speaks.
const _freq = PluginParamInfo(
  id: 7,
  name: 'Freq',
  unit: 'Hz',
  min: 20,
  max: 20000,
  def: 440,
  stepCount: 0,
  // Automatable and visible — the only kind the editor draws a fader for.
  flags: 0x01,
);

/// A meter and the plugin's own bypass: present in `params`, but not controls.
/// A read-only meter — automatable, so the host may READ it, and read-only,
/// so it may not set it.
const _meter = PluginParamInfo(
  id: 8,
  name: 'Gain Reduction',
  unit: 'dB',
  min: -60,
  max: 0,
  def: 0,
  stepCount: 0,
  flags: 0x01 | 0x02,
);

/// A mode selector the plugin will not have automated: visible, writable by
/// hand in the plugin's own window, and NOT automatable.
///
/// `isAutomatable` is optional per parameter, and `isUserVisible` is
/// `isAutomatable && !isHidden` — so a filter written against that hid this
/// one entirely. A plugin whose parameters are all of this shape was told it
/// exposes no controls at all.
const _mode = PluginParamInfo(
  id: 10,
  name: 'Mode',
  unit: '',
  min: 0,
  max: 2,
  def: 0,
  stepCount: 2,
  flags: 0x10,
  valueTexts: ['Lowpass', 'Bandpass', 'Highpass'],
);

/// The octaver's Shift: 48 divisions, past the menu's 24-step ceiling, so it
/// routes to the tile and its sheet.
const _shift = PluginParamInfo(
  id: 13,
  name: 'Shift',
  unit: 'st',
  min: -24,
  max: 24,
  def: 0,
  stepCount: 48,
  flags: 0x01,
);

const _pluginBypass = PluginParamInfo(
  id: 9,
  name: 'Bypass',
  unit: '',
  min: 0,
  max: 1,
  def: 0,
  stepCount: 1,
  flags: 0x01 | 0x04,
);

PluginEffect _plugin({Map<int, double> values = const {}}) => PluginEffect(
  ref: const PluginRef(format: PluginFormat.vst3, id: 'test.filter'),
  name: 'Filter',
  params: const [_freq],
  paramValues: values,
);

Future<AppLocalizations> _l10n(WidgetTester tester) async =>
    AppLocalizations.of(tester.element(find.byType(SignalFxEditor)));

void main() {
  Future<void> pump(WidgetTester tester, _FakeScope scope) async {
    tester.view
      // Tall enough for the grid AND an open editor under it — the editor
      // lives in the card now, so a 400px harness overflows the moment a
      // parameter opens. The real panel scrolls; this has no reason to.
      ..physicalSize = const Size(1920, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Both extensions, from the app's own mapping: the switch cell draws
        // a `ConsoleSwitch`, whose focus ring reads `context.routingGraph`.
        theme: ThemeData(
          extensions: [
            SurfaceTheme.dark,
            routingGraphThemeFromSurface(SurfaceTheme.dark),
          ],
        ),
        home: Scaffold(
          body: SignalFxEditor(
            scope: scope,
            index: 0,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('a hosted plugin speaks plain units, the tile speaks its own', () {
    testWidgets('a plain value sits where it belongs in its range', (
      tester,
    ) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 10010}),
      ]);
      await pump(tester, scope);

      // Halfway up a 20..20000 range. Fed straight to an indicator, anything
      // above 1 pins it full and every plugin reads the same.
      final tile = tester.widget<FxParamTile>(find.byType(FxParamTile));
      expect(tile.value, 10010);
      expect(tile.spec.min, _freq.min);
      expect(tile.spec.max, _freq.max);
    });

    testWidgets('a tile opens the editor and changes nothing on its own', (
      tester,
    ) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 10010}),
      ]);
      await pump(tester, scope);

      await tester.tap(find.byKey(const Key('signal_fx_param_0')));
      await tester.pumpAndSettle();

      // THE rule the grid exists for: the console lies on the floor under
      // someone playing, so a touch on the surface cannot be audible.
      expect(scope.pluginWrites, isEmpty);
      expect(find.byType(FxParamEditor), findsOneWidget);
    });

    testWidgets("the sheet writes back in the plugin's own units", (
      tester,
    ) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 10010}),
      ]);
      await pump(tester, scope);
      await tester.tap(find.byKey(const Key('signal_fx_param_0')));
      await tester.pumpAndSettle();

      final bar = find.byKey(const Key('fxParamEditor_track'));
      final left = tester.getTopLeft(bar);
      final size = tester.getSize(bar);
      // A quarter along, measured — so this pins the MAPPING and not merely
      // that the write landed in range. An inverted map passes a range check
      // and fails this.
      await tester.tapAt(left + Offset(size.width * 0.25, size.height / 2));
      await tester.pumpAndSettle();

      expect(scope.pluginWrites, isNotEmpty);
      final (entry, id, written) = scope.pluginWrites.last;
      // The chain entry, not just the parameter: writing the right value to
      // the wrong slot is the other half of getting this right.
      expect(entry, 0);
      expect(id, 7);
      final expected = _freq.min + 0.25 * (_freq.max - _freq.min);
      expect(written, closeTo(expected, (_freq.max - _freq.min) * 0.05));
    });

    testWidgets('an untouched parameter reads the plugin default', (
      tester,
    ) async {
      final scope = _FakeScope([_plugin()]);
      await pump(tester, scope);

      // Absent means "the plugin's default", not zero.
      final tile = tester.widget<FxParamTile>(find.byType(FxParamTile));
      expect(tile.value, 440);
    });

    testWidgets('the live instance names its own value when it can', (
      tester,
    ) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 440}),
      ], formatted: 'A4');
      await pump(tester, scope);

      // Deliberately NOT what the fallback would produce: two tests that both
      // expect '440 Hz' cannot tell the live path from the fallback, and the
      // whole "ask the instance first" decision would be untested.
      expect(find.text('A4'), findsOneWidget);
      expect(find.text('440 Hz'), findsNothing);
    });

    testWidgets('and falls back to plain units when it cannot', (tester) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 440}),
      ]);
      await pump(tester, scope);

      // No live instance to ask — the plain value with the parameter's own
      // unit, rather than a percentage of a number that is not a fraction.
      expect(find.text('440 Hz'), findsOneWidget);
      expect(find.text('A4'), findsNothing);
    });
  });

  testWidgets('a tile says whose parameter it is, and a meter says it reads', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scope = _FakeScope([
      const PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'test.filter'),
        name: 'Filter',
        params: [_freq, _meter],
        paramValues: {7: 440},
      ),
    ]);
    await pump(tester, scope);

    // "FREQ" alone tells a reader nothing about whose freq it is, and 78px of
    // mono at 9pt is all the tile itself can print.
    final tile = tester.getSemantics(
      find.byKey(const Key('signal_fx_param_0')),
    );
    expect(tile.label, 'Freq of Filter');

    // And a meter has to announce that it only reports — a reader cannot see
    // that it is borderless.
    final meter = tester.getSemantics(
      find.byKey(const Key('signal_fx_param_1')),
    );
    // Equality, not `contains`: the leak this guards against ADDS to the
    // label — "Meter of Filter / METER / 0.00" contains 'Filter' too.
    expect(meter.label, 'Gain Reduction of Filter');
    expect(meter.getSemanticsData().flagsCollection.isReadOnly, isTrue);
    handle.dispose();
  });

  testWidgets('a meter is not drawn as a box a finger could aim at', (
    tester,
  ) async {
    final scope = _FakeScope([
      const PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'test.filter'),
        name: 'Filter',
        params: [_freq, _meter],
        paramValues: {7: 440},
      ),
    ]);
    await pump(tester, scope);

    Color? boxColour(Key key) {
      final box = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(DecoratedBox),
        ),
      );
      return (box.first.decoration as BoxDecoration).color;
    }

    // The control has a box; the meter has none. Untappable is not something
    // a finger can see, and a meter that looks like every other tile is a
    // control that ignores you.
    expect(boxColour(const Key('signal_fx_param_0')), isNotNull);
    expect(boxColour(const Key('signal_fx_param_1')), isNull);

    // And its indicator is off the accent, which is what says "live" on every
    // other cell on this surface.
    // By its own key, not by position in the tile: `boxes.last` is the
    // indicator only while every cell has a fill, and it silently becomes the
    // TRACK — grey, and so passing `isNot(accent)` — for one that does not.
    Color? indicatorColour(Key key) {
      final fill = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byKey(const Key('fx_param_indicator_fill')),
        ),
      );
      return (fill.decoration as BoxDecoration).color;
    }

    const surface = SurfaceTheme.dark;
    expect(indicatorColour(const Key('signal_fx_param_0')), surface.accent);
    // Exactly tertiary, not merely "not the accent": `textMuted` — what this
    // drew before, at 1.1:1 on the track — satisfies `isNot(accent)` too, so
    // the loose form is a test the bug passes.
    expect(
      indicatorColour(const Key('signal_fx_param_1')),
      surface.textTertiary,
    );
  });

  testWidgets('the sheet track can be adjusted, not just announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final scope = _FakeScope([
      _plugin(values: const {7: 440}),
    ]);
    await pump(tester, scope);
    await tester.tap(find.byKey(const Key('signal_fx_param_0')));
    await tester.pumpAndSettle();

    // `slider: true` with no increase/decrease tells a screen-reader user the
    // control is adjustable and then gives them no way to adjust it — WCAG
    // 2.1.1. The values on either side are asserted too: Flutter accepts the
    // actions with `increasedValue` equal to `value`, which announces a
    // nudge that goes nowhere.
    expect(
      tester.getSemantics(find.byKey(const Key('fxParamEditor_slider'))),
      matchesSemantics(
        isSlider: true,
        label: 'Freq',
        value: '2%',
        increasedValue: '7%',
        decreasedValue: '0%',
        hasIncreaseAction: true,
        hasDecreaseAction: true,
        hasTapAction: true,
        hasScrollLeftAction: true,
        hasScrollRightAction: true,
      ),
    );

    handle.dispose();
  });

  testWidgets('a stepped parameter can only land on a step', (tester) async {
    final scope = _FakeScope([
      const PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'test.oct'),
        name: 'Octaver',
        params: [_shift],
        paramValues: {13: 0},
      ),
    ]);
    await pump(tester, scope);

    await tester.tap(find.byKey(const Key('signal_fx_param_0')));
    await tester.pumpAndSettle();

    // Dragged across the track, not tapped once: the octaver's Shift has 48
    // divisions and lives past the menu's 24-step ceiling, so the sheet is
    // the ONLY thing keeping a pitch shift on a semitone. Every value it
    // writes has to be one.
    final track = find.byKey(const Key('fxParamEditor_track'));
    final box = tester.getRect(track);
    final drag = await tester.startGesture(box.centerLeft);
    for (var i = 1; i <= 12; i++) {
      await drag.moveTo(
        Offset(box.left + box.width * i / 12.7, box.center.dy),
      );
      await tester.pump();
    }
    await drag.up();
    await tester.pumpAndSettle();

    expect(scope.pluginWrites, isNotEmpty);
    for (final (_, _, value) in scope.pluginWrites) {
      expect(
        value,
        closeTo(value.roundToDouble(), 1e-9),
        reason: '$value is between two semitones',
      );
    }
  });

  testWidgets('the sheet closes when its entry leaves the chain', (
    tester,
  ) async {
    final scope = _FakeScope([
      const PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'test.a'),
        name: 'A',
        params: [_freq],
        slotId: 'slot-a',
      ),
    ]);
    await pump(tester, scope);
    await tester.tap(find.byKey(const Key('signal_fx_param_0')));
    await tester.pumpAndSettle();
    expect(find.byType(FxParamEditor), findsOneWidget);

    scope.chain = [];
    final track = find.byKey(const Key('fxParamEditor_track'));
    await tester.tapAt(
      tester.getTopLeft(track) + Offset(tester.getSize(track).width * 0.25, 12),
    );
    await tester.pumpAndSettle();

    // The panel behind it has already collapsed to nothing. A sheet left over
    // an entry that no longer exists takes drags that go nowhere and cancels
    // to nothing — closing says so, swallowing them does not.
    expect(find.byType(FxParamEditor), findsNothing);
    expect(scope.pluginWrites, isEmpty);
  });

  testWidgets('the sheet follows its entry when the chain moves under it', (
    tester,
  ) async {
    final scope = _FakeScope([
      const PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'test.a'),
        name: 'A',
        params: [_freq],
        slotId: 'slot-a',
      ),
      const PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'test.b'),
        name: 'B',
        params: [_freq],
        slotId: 'slot-b',
      ),
    ]);
    await pump(tester, scope);

    await tester.tap(find.byKey(const Key('signal_fx_param_0')));
    await tester.pumpAndSettle();

    // The chain is rewritten while the sheet is up — a record pass snapshots
    // a monitor chain onto the lane, another surface removes an entry. The
    // sheet is modal and stays open for as long as someone takes to settle a
    // value, so this is not a rare frame.
    scope
      ..chain = [scope.chain[1], scope.chain[0]]
      ..formattedPerEntry[0] = 'WRONG'
      ..formattedPerEntry[1] = 'RIGHT';

    final track = find.byKey(const Key('fxParamEditor_track'));
    await tester.tapAt(
      tester.getTopLeft(track) + Offset(tester.getSize(track).width * 0.25, 12),
    );
    await tester.pumpAndSettle();

    // Entry 1 now, because that is where the entry it was opened for went. By
    // position it would have moved a parameter of the OTHER plugin.
    expect(scope.pluginWrites, isNotEmpty);
    expect(scope.pluginWrites.last.$1, 1);

    // And it READS through the same entry. Writing to the right effect while
    // showing the other one's value is the same bug wearing a disguise: the
    // live readout asks the instance to name the value, and asking by
    // position would ask the plugin that slid into the slot.
    expect(find.text('RIGHT'), findsWidgets);
    expect(find.text('WRONG'), findsNothing);
  });

  group('a built-in speaks 0..1, and the sheet keeps it that way', () {
    testWidgets('the sheet writes a normalized value back', (tester) async {
      final scope = _FakeScope([
        BuiltInEffect(type: TrackEffectType.drive),
      ]);
      await pump(tester, scope);

      await tester.tap(find.byKey(const Key('signal_fx_param_0')));
      await tester.pumpAndSettle();
      final track = find.byKey(const Key('fxParamEditor_track'));
      await tester.tapAt(
        tester.getTopLeft(track) +
            Offset(tester.getSize(track).width * 0.25, 12),
      );
      await tester.pumpAndSettle();

      // A built-in takes `0..1`, a plugin takes its own units, and one grid
      // now feeds both. A plain value written here would set a knob far past
      // its own ceiling — the mirror of the bug the plugin side had.
      expect(scope.builtInWrites, isNotEmpty);
      final (entry, param, written) = scope.builtInWrites.last;
      expect(entry, 0);
      expect(param, 0);
      expect(written, closeTo(0.25, 0.05));
    });

    testWidgets("the octaver's mode says which mode it is in", (tester) async {
      final scope = _FakeScope([
        BuiltInEffect(type: TrackEffectType.octaver),
      ]);
      await pump(tester, scope);
      final l10n = await _l10n(tester);

      // Two states with NAMES — the one built-in shaped like that. The tile
      // shows which one is running; opening it lists both by name. A bare
      // switch would say neither, and a bar would ask a player to find a
      // named mode by fraction.
      expect(find.text(l10n.octaverModeLabel(0)), findsWidgets);

      // Mode is the octaver's FOURTH parameter — Shift, Tone, Mix, Mode.
      // Tapping param 1 opened Tone, which is continuous and correctly gets a
      // track; the test was reading the editor's answer to a different
      // question.
      await tester.tap(find.byKey(const Key('signal_fx_param_3')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fxParamEditor_steps')), findsOneWidget);
      expect(find.byKey(const Key('fxParamEditor_track')), findsNothing);
      for (final step in [0.0, 1.0]) {
        expect(find.text(l10n.octaverModeLabel(step)), findsWidgets);
      }
    });

    testWidgets('reset puts back the effect default, not zero', (tester) async {
      final scope = _FakeScope([
        BuiltInEffect(type: TrackEffectType.drive),
      ]);
      await pump(tester, scope);

      await tester.tap(find.byKey(const Key('signal_fx_param_0')));
      await tester.pumpAndSettle();
      // Moved off the default first: reset from the default is a no-op, and a
      // no-op cannot tell a right default from a wrong one.
      final track = find.byKey(const Key('fxParamEditor_track'));
      await tester.tapAt(
        tester.getTopLeft(track) +
            Offset(tester.getSize(track).width * 0.9, 12),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fxParamEditor_reset')));
      await tester.pumpAndSettle();

      // Zero is silence for most built-ins: a reset that switches the effect
      // off is not a reset.
      expect(scope.builtInWrites, isNotEmpty);
      expect(
        scope.builtInWrites.last.$3,
        TrackEffectType.drive.defaultParams.first,
      );
      expect(scope.builtInWrites.last.$3, isNot(0));
    });
  });

  testWidgets('the sheet reads the same words the tile does', (tester) async {
    final scope = _FakeScope([
      _plugin(values: const {7: 440}),
    ], formatted: 'A4');
    await pump(tester, scope);
    expect(find.text('A4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('signal_fx_param_0')));
    await tester.pumpAndSettle();

    expect(find.text('A4'), findsWidgets);
  });

  testWidgets('and the same words when nothing can name the value', (
    tester,
  ) async {
    // No live instance to ask — which is not an edge case: a bus stage never
    // has one, so this is what the Track and Master stages always do.
    final scope = _FakeScope([
      _plugin(values: const {7: 440}),
    ]);
    await pump(tester, scope);
    expect(find.text('440 Hz'), findsOneWidget);

    await tester.tap(find.byKey(const Key('signal_fx_param_0')));
    await tester.pumpAndSettle();

    // The tile's own fallback, not a bare number: a sheet opened from a tile
    // reading `440 Hz` that says `440` has dropped the unit on the way.
    expect(
      find.descendant(
        of: find.byType(FxParamEditor),
        matching: find.text('440 Hz'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a stepped parameter lands on a step', (tester) async {
    const type = PluginParamInfo(
      id: 11,
      name: 'Type',
      unit: '',
      min: 0,
      max: 2,
      def: 0,
      stepCount: 2,
      flags: 0x01 | 0x10,
      valueTexts: ['Lowpass', 'Bandpass', 'Highpass'],
    );
    final scope = _FakeScope([
      const PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'test.filter'),
        params: [type],
      ),
    ]);
    await pump(tester, scope);

    // A named few is a LIST, not a bar and not a dropdown: the grid is one
    // uniform tile per parameter, and the editor under it shows the steps by
    // name. The menu this replaces put a `PopupMenuButton` inside a 78px tile
    // — a control that opened over the face it belonged to.
    await tester.tap(find.byKey(const Key('signal_fx_param_0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fxParamEditor_steps')), findsOneWidget);

    await tester.tap(find.text('Highpass').last);
    await tester.pumpAndSettle();

    expect(scope.pluginWrites, isNotEmpty);
    final (_, _, written) = scope.pluginWrites.last;
    expect(written, 2);
  });

  testWidgets('the move buttons are drawn, not typed', (tester) async {
    final scope = _FakeScope([
      BuiltInEffect(type: TrackEffectType.reverb, slotId: 'a'),
      BuiltInEffect(type: TrackEffectType.drive, slotId: 'b'),
    ]);
    await pump(tester, scope);

    // `◀` and `▶` are emoji-presentation by default, so macOS renders them
    // out of Apple Color Emoji: a fat coloured lozenge off the baseline,
    // beside a `Remove` in Inter. A path is the same on every platform the
    // console runs on — and it points the way the button says it does, which
    // nothing else in the tree would show.
    for (final (key, points) in [
      ('signal_fx_move_up', 'signal_fx_points_left'),
      ('signal_fx_move_down', 'signal_fx_points_right'),
    ]) {
      expect(
        find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byKey(Key(points)),
        ),
        findsOneWidget,
      );
    }
  });

  group('what is a control and what is only a number', () {
    testWidgets("a meter and the plugin's own bypass get no fader", (
      tester,
    ) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'test.filter'),
          name: 'Filter',
          params: [_freq, _meter, _pluginBypass],
          paramValues: {7: 440},
        ),
      ]);
      await pump(tester, scope);

      // Two cells: the control, and the meter beside it.
      expect(find.byKey(const Key('signal_fx_param_0')), findsOneWidget);
      expect(find.byKey(const Key('signal_fx_param_1')), findsOneWidget);

      // The meter IS drawn, and drawn as what it is. `DS / 06` sends a
      // read-only parameter to a borderless, untappable tile and says meters
      // land there — a value the plugin publishes is part of what the plugin
      // is, and a strip missing its gain reduction silently disagrees with
      // the plugin's own window. What it must not do is look tappable.
      final meter = tester.widget<FxParamTile>(
        find.descendant(
          of: find.byKey(const Key('signal_fx_param_1')),
          matching: find.byType(FxParamTile),
        ),
      );
      expect(meter.onTap, isNull);

      // And the plugin's own bypass is not a fader: the footer's pill is THE
      // power control, and a second one beside it is the ambiguity R23 exists
      // to prevent.
      expect(find.text('BYPASS'), findsNothing);
    });

    testWidgets('a plugin with nothing automatable still has controls', (
      tester,
    ) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'test.filter'),
          name: 'Filter',
          params: [_mode],
        ),
      ]);
      await pump(tester, scope);

      // `isAutomatable` is optional per parameter — a plugin whose every
      // parameter is like this rendered nothing at all, and the panel said so
      // in as many words. A setting read at load is still true at load.
      expect(find.byKey(const Key('signal_fx_no_params')), findsNothing);
      expect(find.text('MODE'), findsOneWidget);

      final handle = tester.ensureSemantics();
      final row = find.byKey(const Key('signal_fx_param_0'));
      await tester.drag(row, const Offset(200, 0));
      await tester.pumpAndSettle();
      // Read-only, because the plugin says the host may not set it — and it
      // does not ANNOUNCE itself as adjustable either: a slider a screen
      // reader can reach and cannot move is a worse lie than a number.
      expect(scope.pluginWrites, isEmpty);
      final node = tester.getSemantics(
        find.descendant(of: row, matching: find.byType(Semantics)).first,
      );
      expect(node.getSemanticsData().flagsCollection.isSlider, isFalse);
      handle.dispose();
    });
  });

  group('a hosted plugin is reachable on its own terms', () {
    testWidgets('a loaded plugin can be opened in its own window', (
      tester,
    ) async {
      final scope = _FakeScope([_plugin()]);
      await pump(tester, scope);

      await tester.tap(find.byKey(const Key('signal_fx_open_window')));
      await tester.pump();

      // The console edits parameters generically, but some of a plugin's
      // exist only in its own UI. Deleting the last route to that window
      // would have made them unreachable on this machine.
      expect(scope.opened, [0]);
    });

    testWidgets('a built-in offers no window, because it has none', (
      tester,
    ) async {
      final scope = _FakeScope([
        BuiltInEffect(type: TrackEffectType.reverb, slotId: 'a'),
      ]);
      await pump(tester, scope);

      expect(find.byKey(const Key('signal_fx_open_window')), findsNothing);
    });

    testWidgets('a plugin that did not load offers no window either', (
      tester,
    ) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
          unavailable: true,
        ),
      ]);
      await pump(tester, scope);

      // There is no instance to show — the action would open nothing.
      expect(find.byKey(const Key('signal_fx_open_window')), findsNothing);
    });
  });

  group('a plugin that went missing can be pointed at a new one', () {
    testWidgets('the placeholder offers a relink', (tester) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
          unavailable: true,
        ),
      ]);
      await pump(tester, scope);

      // Without this the entry can only be removed and added again, which
      // throws away the state `PluginEffect.state` exists to keep.
      expect(find.byKey(const Key('signal_fx_relink')), findsOneWidget);
    });

    testWidgets('a plugin this stage cannot host is not missing', (
      tester,
    ) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'x'),
          unavailable: true,
          unsupported: true,
        ),
      ]);
      await pump(tester, scope);

      // Relinking it would point at a plugin this stage still cannot host.
      expect(find.byKey(const Key('signal_fx_relink')), findsNothing);
    });

    testWidgets('one still being looked for is not missing yet', (
      tester,
    ) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'x'),
          loading: true,
        ),
      ]);
      await pump(tester, scope);

      expect(find.byKey(const Key('signal_fx_relink')), findsNothing);
    });
  });

  group('an entry with nothing to show says which nothing', () {
    testWidgets('a plugin that did not load says so', (tester) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'gone'),
          unavailable: true,
        ),
      ]);
      await pump(tester, scope);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignalFxEditor)),
      );

      // The repo's own placeholder wording, shared with the card and the
      // summary chip so the three cannot drift apart.
      expect(find.text(l10n.signalPluginUnavailable), findsOneWidget);
      expect(find.text(l10n.fxNoParameters), findsNothing);
    });

    testWidgets('a plugin still being scanned is not called a failure', (
      tester,
    ) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'scanning'),
          // The posture the repository ACTUALLY produces while a scan is in
          // flight: `loading` true with `unavailable` FALSE. Testing
          // `unavailable` alone would miss it entirely and the entry would
          // fall through to "exposes no controls".
          loading: true,
        ),
      ]);
      await pump(tester, scope);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignalFxEditor)),
      );

      expect(find.text(l10n.signalPluginLoading), findsOneWidget);
      expect(find.text(l10n.signalPluginUnavailable), findsNothing);
    });

    testWidgets('a stage that cannot host it says that, not that it failed', (
      tester,
    ) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'bus'),
          unavailable: true,
          unsupported: true,
        ),
      ]);
      await pump(tester, scope);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignalFxEditor)),
      );

      expect(find.text(l10n.signalPluginUnsupported), findsOneWidget);
      expect(find.text(l10n.signalPluginUnavailable), findsNothing);
    });

    testWidgets('a built-in with no parameters says only that', (tester) async {
      final scope = _FakeScope([
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'empty'),
        ),
      ]);
      await pump(tester, scope);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SignalFxEditor)),
      );

      expect(find.text(l10n.fxNoParameters), findsOneWidget);
    });
  });

  testWidgets('a chain switched off explains the silence', (tester) async {
    final scope = _FakeScope([
      _plugin(values: const {7: 440}),
    ], chainOn: false);
    await pump(tester, scope);

    expect(find.byKey(const Key('signal_fx_chain_off')), findsOneWidget);
  });
}
