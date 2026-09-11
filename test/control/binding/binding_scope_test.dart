import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/binding_scope.dart';

void main() {
  group('BindingScope.fromName', () {
    test('reads back every scope', () {
      for (final scope in BindingScope.values) {
        expect(BindingScope.fromName(scope.name), scope);
      }
    });

    test('an unknown scope stays FIXED, never following', () {
      // A binding whose scope no longer exists must keep acting on the track
      // it names. Defaulting the other way would quietly repoint every stale
      // binding at whatever the foot last selected.
      expect(BindingScope.fromName('whatever'), BindingScope.fixed);
      expect(BindingScope.fromName(null), BindingScope.fixed);
    });
  });

  group('resolveBindingAddress', () {
    test('a fixed scope is the identity, on every stage', () {
      for (final stage in FxStage.values) {
        final address = FxAddress(stage: stage, index: 5);
        expect(
          resolveBindingAddress(address, BindingScope.fixed, 2),
          address,
          reason: stage.name,
        );
      }
    });

    test('a selected scope repoints the two stages whose index IS a track', () {
      for (final stage in [FxStage.loop, FxStage.track]) {
        expect(
          resolveBindingAddress(
            FxAddress(stage: stage, index: 5, lane: 1),
            BindingScope.selected,
            2,
          ),
          FxAddress(stage: stage, index: 2, lane: 1),
          reason: stage.name,
        );
      }
    });

    test('an input, an output and All tracks are left alone', () {
      // None of the three has a relationship to the selected track, so a
      // scope on one is honoured as written rather than pointed somewhere
      // arbitrary.
      for (final stage in [FxStage.input, FxStage.output, FxStage.allTracks]) {
        final address = FxAddress(stage: stage, index: 5);
        expect(
          resolveBindingAddress(address, BindingScope.selected, 2),
          address,
          reason: stage.name,
        );
      }
    });

    test('the lane survives the repoint', () {
      // A lane binding follows the cursor onto the SAME lane of another
      // track; dropping the lane would widen it to the whole track.
      expect(
        resolveBindingAddress(
          const FxAddress(stage: FxStage.loop, lane: 3),
          BindingScope.selected,
          6,
        ).lane,
        3,
      );
    });
  });
}
