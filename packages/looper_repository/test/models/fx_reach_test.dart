import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';

const _input = FxAddress(stage: FxStage.input);
const _a = FxSwitchKey.rack(_input, 'a');
const _b = FxSwitchKey.rack(_input, 'b');
const _c = FxSwitchKey.slot(_input, 'c');

void main() {
  group('FxReach', () {
    test(
      'a control with one side alternates nothing: its switches are free',
      () {
        final reach = FxReach([
          FxControlReach(whenOn: {_a}),
        ]);
        expect(reach.free, {_a});
        expect(reach.alternations, isEmpty);
        expect(reach.states((_) => false), [<FxSwitchKey>{}]);
      },
    );

    test('one control with both sides alternates them', () {
      final reach = FxReach([
        FxControlReach(whenOn: {_a}, whenOff: {_b}),
      ]);
      expect(reach.free, isEmpty);
      expect(reach.alternates(_a), isTrue);
      expect(reach.alternatedChains, {_input});
      // A on now, B off: the two sides, the state now being one of them.
      expect(reach.states((key) => key == _a), [
        {_a},
        {_b},
      ]);
      // Both on from the screen: that state is weighed too.
      expect(reach.states((_) => true), [
        {_a},
        {_b},
        {_a, _b},
      ]);
    });

    test('a switch another control reaches is free, and so is the rest of a '
        'pair it leaves one-sided', () {
      final reach = FxReach([
        FxControlReach(whenOn: {_a}, whenOff: {_b}),
        FxControlReach(whenOn: {_b}),
      ]);
      expect(reach.free, {_a, _b});
      expect(reach.alternations, isEmpty);
      final shared = FxReach([
        FxControlReach(whenOn: {_a, _c}, whenOff: {_b}),
        FxControlReach(whenOn: {_c}),
      ]);
      expect(shared.free, {_c});
      expect(shared.alternations, [
        FxControlReach(whenOn: {_a}, whenOff: {_b}),
      ]);
    });

    test('two alternations weigh every pair of their sides', () {
      const d = FxSwitchKey.rack(_input, 'd');
      final reach = FxReach([
        FxControlReach(whenOn: {_a}, whenOff: {_b}),
        FxControlReach(whenOn: {_c}, whenOff: {d}),
      ]);
      expect(reach.states((_) => false), [
        {_a, _c},
        {_a, d},
        {_b, _c},
        {_b, d},
      ]);
    });

    test('past the most alternations the rest are free', () {
      final reach = FxReach([
        for (var i = 0; i <= FxReach.maxAlternations; i++)
          FxControlReach(
            whenOn: {FxSwitchKey.rack(_input, 'on$i')},
            whenOff: {FxSwitchKey.rack(_input, 'off$i')},
          ),
      ]);
      expect(reach.alternations, hasLength(FxReach.maxAlternations));
      expect(reach.free, {
        const FxSwitchKey.rack(_input, 'on${FxReach.maxAlternations}'),
        const FxSwitchKey.rack(_input, 'off${FxReach.maxAlternations}'),
      });
    });
  });

  group('fxReachShrinks', () {
    final pair = FxControlReach(whenOn: {_a}, whenOff: {_b});
    final console = FxControlReach(whenOn: {_c});

    test('dropping or narrowing a control only takes reach away', () {
      expect(fxReachShrinks([console, pair], [pair]), isTrue);
      expect(
        fxReachShrinks(
          [pair],
          [
            FxControlReach(whenOn: {_a}),
          ],
        ),
        isTrue,
      );
      expect(fxReachShrinks([pair], [pair]), isTrue);
      expect(fxReachShrinks([pair], const []), isTrue);
      // A switch set up with nothing on it takes no reach.
      expect(fxReachShrinks([pair], [const FxControlReach(), pair]), isTrue);
    });

    test('a new control, or one more on a side, adds reach', () {
      expect(fxReachShrinks([pair], [console, pair]), isFalse);
      // Rack A bound to a console switch too: two controls where one was.
      expect(
        fxReachShrinks(
          [pair],
          [
            FxControlReach(whenOn: {_a}),
            pair,
          ],
        ),
        isFalse,
      );
      expect(
        fxReachShrinks(
          [pair],
          [
            FxControlReach(whenOn: {_a, _c}, whenOff: {_b}),
          ],
        ),
        isFalse,
      );
    });
  });
}
