import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/fx_editor/fx_scope.dart';
import 'package:segno/looper/view/signal/signal_fx_editor.dart';
import 'package:segno/theme/theme.dart';

class _FakeScope extends Fake implements FxScope {
  _FakeScope(this.chain, {this.chainOn = true, this.formatted});

  List<TrackEffect> chain;
  bool chainOn;
  String? formatted;

  final List<(int, int, double)> pluginWrites = [];
  final List<(int, int, double)> builtInWrites = [];

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
  String? formatPluginValue(int index, int paramId, double value) => formatted;
}

/// A filter frequency: the shape that made the unit bug destructive — a plain
/// range far outside the `0..1` a [ConsoleValueBar] speaks.
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

void main() {
  Future<void> pump(WidgetTester tester, _FakeScope scope) async {
    tester.view
      ..physicalSize = const Size(1920, 400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(extensions: const [SurfaceTheme.dark]),
        home: Scaffold(
          body: SignalFxEditor(
            scope: scope,
            index: 0,
            onClose: () {},
            onMoved: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('a hosted plugin speaks plain units, the bar speaks 0..1', () {
    testWidgets('a plain value is normalized onto the bar', (tester) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 10010}),
      ]);
      await pump(tester, scope);

      // Halfway up a 20..20000 range. Fed straight in, anything above 1 pins
      // the bar to full and every plugin reads 100%.
      final bar = tester.widget<ConsoleValueBar>(
        find.byKey(const Key('signal_fx_param_0')),
      );
      expect(bar.value, closeTo(0.5, 0.001));
    });

    testWidgets("a drag writes back in the plugin's own units", (
      tester,
    ) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 10010}),
      ]);
      await pump(tester, scope);

      final bar = find.byKey(const Key('signal_fx_param_0'));
      final left = tester.getTopLeft(bar);
      final width = tester.getSize(bar).width;
      // A quarter along the bar, measured — so the assertion below pins the
      // MAPPING and not merely that the write landed somewhere in range. An
      // inverted map (drag right = lower) passes a range check and fails this.
      await tester.tapAt(left + Offset(width * 0.25, 25));
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
      final bar = tester.widget<ConsoleValueBar>(
        find.byKey(const Key('signal_fx_param_0')),
      );
      expect(bar.value, closeTo((440 - 20) / (20000 - 20), 0.001));
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

    final bar = find.byKey(const Key('signal_fx_param_0'));
    await tester.tapAt(
      tester.getTopLeft(bar) + Offset(tester.getSize(bar).width * 0.45, 25),
    );
    await tester.pumpAndSettle();

    // The readout names a step, so the value has to BE one — a plugin parked
    // between two while the label claims one of them is the mismatch.
    expect(scope.pluginWrites, isNotEmpty);
    final (_, _, written) = scope.pluginWrites.last;
    expect(written, closeTo(written.roundToDouble(), 0.0001));
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

      // One fader, for the one parameter that is a control. A read-only meter
      // with a working bar over it now WRITES, and a second bypass beside the
      // footer's pill is the ambiguity R23 exists to prevent.
      expect(find.byKey(const Key('signal_fx_param_0')), findsOneWidget);
      expect(find.byKey(const Key('signal_fx_param_1')), findsNothing);
      expect(find.text('GAIN REDUCTION'), findsNothing);
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
