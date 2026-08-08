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
  flags: 0,
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

      await tester.tapAt(
        tester.getTopLeft(find.byKey(const Key('signal_fx_param_0'))) +
            const Offset(1200, 25),
      );
      await tester.pumpAndSettle();

      // Sending the bar's fraction straight through would set a 20 kHz filter
      // to 0.06 Hz. The write has to land inside the plugin's own range.
      expect(scope.pluginWrites, isNotEmpty);
      final (_, id, written) = scope.pluginWrites.last;
      expect(id, 7);
      expect(written, greaterThan(_freq.min));
      expect(written, lessThanOrEqualTo(_freq.max));
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
      ], formatted: '440 Hz');
      await pump(tester, scope);

      expect(find.text('440 Hz'), findsOneWidget);
    });

    testWidgets('and falls back to plain units when it cannot', (tester) async {
      final scope = _FakeScope([
        _plugin(values: const {7: 440}),
      ]);
      await pump(tester, scope);

      // The two bus stages hold no live instance to ask; a percentage of a
      // plain value would say nothing.
      expect(find.text('440 Hz'), findsOneWidget);
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

      expect(find.text(l10n.fxPluginUnavailable), findsOneWidget);
      expect(find.text(l10n.fxNoParameters), findsNothing);
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
