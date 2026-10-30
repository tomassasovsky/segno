import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/library/cubit/new_loop_cubit.dart';
import 'package:segno/session/session.dart';

const _template = NewLoopTemplate(trackChains: {}, names: {0: 'Guitar'});

void main() {
  group(NewLoopCubit, () {
    late int loads;
    late bool fits;
    late Completer<NewLoopTemplate?>? pending;

    setUp(() {
      loads = 0;
      fits = true;
      pending = null;
    });

    NewLoopCubit build({NewLoopTemplate? loaded = _template}) => NewLoopCubit(
      loadEdsSetup: () {
        loads++;
        return pending?.future ?? Future.value(loaded);
      },
      fits: (_) => fits,
    );

    test('starts on Empty tracks, which can start with no template', () {
      final cubit = build();
      addTearDown(cubit.close);

      expect(cubit.state, const NewLoopState());
      expect(cubit.state.canStart, isTrue);
      expect(cubit.state.chosenTemplate, isNull);
    });

    blocTest<NewLoopCubit, NewLoopState>(
      "Ed's setup loads its sounds, then is ready when they fit",
      build: build,
      act: (cubit) => cubit.choose(NewLoopStart.edsSetup),
      expect: () => const [
        NewLoopState(start: NewLoopStart.edsSetup),
        NewLoopState(
          start: NewLoopStart.edsSetup,
          eds: EdsSetupStatus.loading,
        ),
        NewLoopState(
          start: NewLoopStart.edsSetup,
          eds: EdsSetupStatus.ready,
          template: _template,
        ),
      ],
      verify: (cubit) {
        expect(cubit.state.canStart, isTrue);
        expect(cubit.state.chosenTemplate, _template);
      },
    );

    blocTest<NewLoopCubit, NewLoopState>(
      'cannot start while loading',
      build: () {
        pending = Completer();
        return build();
      },
      act: (cubit) => unawaited(cubit.choose(NewLoopStart.edsSetup)),
      verify: (cubit) {
        expect(cubit.state.eds, EdsSetupStatus.loading);
        expect(cubit.state.canStart, isFalse);
        pending!.complete(_template);
      },
    );

    blocTest<NewLoopCubit, NewLoopState>(
      'a missing sound leaves it refused',
      build: () => build(loaded: null),
      act: (cubit) => cubit.choose(NewLoopStart.edsSetup),
      verify: (cubit) {
        expect(cubit.state.eds, EdsSetupStatus.missing);
        expect(cubit.state.canStart, isFalse);
        expect(cubit.state.chosenTemplate, isNull);
      },
    );

    blocTest<NewLoopCubit, NewLoopState>(
      'sounds over the budget leave it refused',
      build: () {
        fits = false;
        return build();
      },
      act: (cubit) => cubit.choose(NewLoopStart.edsSetup),
      verify: (cubit) {
        expect(cubit.state.eds, EdsSetupStatus.overBudget);
        expect(cubit.state.canStart, isFalse);
        expect(cubit.state.chosenTemplate, isNull);
      },
    );

    blocTest<NewLoopCubit, NewLoopState>(
      'going back to Empty tracks can start again, without the template',
      build: () {
        fits = false;
        return build();
      },
      act: (cubit) async {
        await cubit.choose(NewLoopStart.edsSetup);
        await cubit.choose(NewLoopStart.emptyTracks);
      },
      verify: (cubit) {
        expect(cubit.state.canStart, isTrue);
        expect(cubit.state.chosenTemplate, isNull);
      },
    );

    blocTest<NewLoopCubit, NewLoopState>(
      'choosing it again reads the sounds once and checks the budget again',
      build: build,
      act: (cubit) async {
        await cubit.choose(NewLoopStart.edsSetup);
        await cubit.choose(NewLoopStart.emptyTracks);
        fits = false;
        await cubit.choose(NewLoopStart.edsSetup);
      },
      verify: (cubit) {
        expect(loads, 1);
        expect(cubit.state.eds, EdsSetupStatus.overBudget);
      },
    );
  });
}
