import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/app/view/encoder_navigation.dart';
import 'package:segno/control/control.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

class _MockControl extends MockCubit<ControlState> implements ControlCubit {}

void main() {
  late FakePedalLink link;
  late PedalRepository pedal;
  late _MockControl control;
  late int stagePresses;

  setUp(() {
    control = _MockControl();
    when(() => control.state).thenReturn(const ControlState());
    stagePresses = 0;
  });

  Future<void> pump(WidgetTester tester) async {
    // Inside the test's zone, so the link's events are delivered by pump.
    link = FakePedalLink();
    pedal = PedalRepository(link);
    link.hello();
    await tester.pump();
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: pedal,
        child: BlocProvider<ControlCubit>.value(
          value: control,
          child: MaterialApp(
            navigatorKey: segnoNavigatorKey,
            theme: AppTheme.neon,
            builder: (context, child) => EncoderNavigation(
              onStagePress: () async => stagePresses++,
              child: child!,
            ),
            home: const Scaffold(body: Text('stage')),
          ),
        ),
      ),
    );
  }

  /// Unmounts and closes the repository inside the test, so its liveness
  /// timer is not left pending.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // The watchdog is cancelled synchronously; the stream closes then drain
    // on the next pump.
    unawaited(pedal.dispose());
    await tester.pump();
  }

  Future<void> openPage(WidgetTester tester, Widget body) async {
    segnoNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => Scaffold(body: body)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> turn(WidgetTester tester, int delta) async {
    link.turn(delta);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester) async {
    link
      ..pressEncoder(down: true)
      ..pressEncoder(down: false);
    await tester.pump();
  }

  /// Whether the primary focus sits inside the control keyed [key].
  bool focused(WidgetTester tester, String key) {
    final target = tester.element(find.byKey(Key(key)));
    final node = FocusManager.instance.primaryFocus?.context;
    if (node is! Element) return false;
    if (node == target) return true;
    var inside = false;
    node.visitAncestorElements((element) {
      inside = element == target;
      return !inside;
    });
    return inside;
  }

  group('on the stage', () {
    testWidgets('a turn is the performance control', (tester) async {
      await pump(tester);
      await turn(tester, 3);
      verify(() => control.encoderTurned(3)).called(1);
      await finish(tester);
    });

    testWidgets('a press opens Settings', (tester) async {
      await pump(tester);
      await press(tester);
      expect(stagePresses, 1);
      verifyNever(() => control.encoderTurned(any()));
      await finish(tester);
    });
  });

  group('over a page', () {
    Widget stops(List<String> activated) => Column(
      children: [
        for (final name in ['a', 'b', 'c'])
          LoopFocusable(
            key: Key(name),
            onActivate: () => activated.add(name),
            child: const SizedBox(width: 40, height: 40),
          ),
      ],
    );

    testWidgets('a turn moves focus, never the volume', (tester) async {
      await pump(tester);
      await openPage(tester, stops([]));
      await turn(tester, 1);
      expect(focused(tester, 'a'), isTrue);
      await turn(tester, 2);
      expect(focused(tester, 'c'), isTrue);
      await turn(tester, -1);
      expect(focused(tester, 'b'), isTrue);
      verifyNever(() => control.encoderTurned(any()));
      await finish(tester);
    });

    testWidgets('a press activates the focused control', (tester) async {
      final activated = <String>[];
      await pump(tester);
      await openPage(tester, stops(activated));
      await turn(tester, 2);
      await press(tester);
      expect(activated, ['b']);
      expect(stagePresses, 0);
      await finish(tester);
    });

    testWidgets('a slider: press drafts, turn adjusts, press commits', (
      tester,
    ) async {
      var value = 0.5;
      double? committed;
      await pump(tester);
      await openPage(
        tester,
        StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              LoopSlider(
                key: const Key('slider'),
                value: value,
                width: 400,
                semanticLabel: 'Level',
                keyboardStep: 0.1,
                onChanged: (next) => setState(() => value = next),
                onChangeEnd: (next) => committed = next,
              ),
              LoopFocusable(
                key: const Key('after'),
                onActivate: () {},
                child: const SizedBox(width: 40, height: 40),
              ),
            ],
          ),
        ),
      );
      await turn(tester, 1);
      expect(focused(tester, 'slider'), isTrue);

      await press(tester);
      await turn(tester, 2);
      expect(value, closeTo(0.7, 1e-9));
      // Still on the slider: the turn adjusted rather than moved focus.
      expect(focused(tester, 'slider'), isTrue);
      expect(committed, isNull);

      await press(tester);
      expect(committed, closeTo(0.7, 1e-9));

      // No draft: the next turn moves on.
      await turn(tester, 1);
      expect(focused(tester, 'after'), isTrue);
      expect(value, closeTo(0.7, 1e-9));
      await finish(tester);
    });
  });
}
