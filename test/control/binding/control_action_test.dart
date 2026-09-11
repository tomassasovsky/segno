import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/binding/control_action.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// The shared vocabulary three assignment surfaces draw from: its keys are
/// identity, so every one of them has to survive a round trip unchanged, and
/// a key this build cannot honour has to decode to nothing rather than to
/// something nearby.
void main() {
  group('ControlAction keys', () {
    test('every catalogue entry round-trips through its own key', () {
      for (final action in controlActionCatalogue()) {
        expect(
          ControlAction.tryParse(action.key),
          action,
          reason: action.key,
        );
      }
    });

    test('the catalogue has no two entries under one key', () {
      final keys = [for (final a in controlActionCatalogue()) a.key];
      expect(keys.toSet(), hasLength(keys.length));
    });

    test('the accepted spellings are the ones stored', () {
      expect(const ModeAction(InteractionMode.record).key, 'mode:tracks');
      expect(const ModeAction(InteractionMode.mute).key, 'mode:mute');
      expect(
        const CommandAction(ControlCommand.recordPlay).key,
        'command:record-play',
      );
      // The bank is NOT under `command:` — the accepted catalogue spells it
      // this way, and a shared vocabulary has to match it exactly.
      expect(const CommandAction(ControlCommand.nextBank).key, 'bank:next');
      expect(const TrackPedalAction(2).key, 'track:2');
      expect(const SelectTrackAction(2).key, 'select-track:2');
      expect(
        const TrackOperationAction(
          operation: TrackOperation.mute,
          scope: SelectedTrackScope(),
        ).key,
        'direct:mute:selected',
      );
      expect(
        const TrackOperationAction(
          operation: TrackOperation.clear,
          scope: FixedTrackScope(5),
        ).key,
        'direct:clear:5',
      );
    });

    test('a key this build cannot honour decodes to nothing', () {
      for (final key in [
        '',
        'mode',
        'mode:transpose',
        'mode:mute:extra',
        'track:8',
        'track:-1',
        'track:x',
        'select-track:99',
        'direct:mute',
        'direct:reverse:selected',
        'direct:mute:9',
        'command:teleport',
        'bank:previous',
      ]) {
        expect(ControlAction.tryParse(key), isNull, reason: key);
      }
    });

    test('clear-all is refused as a per-track operation — Clear All is ONE '
        'grouped edit, and eight clears behind one stomp would leave eight '
        'undo steps', () {
      expect(ControlAction.tryParse('direct:clear:all'), isNull);
      expect(
        controlActionCatalogue().where(
          (a) =>
              a is TrackOperationAction &&
              a.operation == TrackOperation.clear &&
              a.scope is AllTracksScope,
        ),
        isEmpty,
      );
    });
  });

  group('the catalogue', () {
    test('lists a fixed-track entry per channel and per operation', () {
      final fixed = controlActionsIn(ControlActionGroup.fixed);
      expect(fixed, hasLength(8 * TrackOperation.values.length));
    });

    test('groups every entry, and offers only the groups that have one', () {
      final groups = controlActionGroups();
      for (final action in controlActionCatalogue()) {
        expect(groups, contains(action.group), reason: action.key);
      }
      // The headings a later part fills are declared but not offered yet — a
      // picker tab with nothing under it is a promise the rig cannot keep.
      expect(groups, isNot(contains(ControlActionGroup.loopModes)));
      expect(groups, isNot(contains(ControlActionGroup.fx)));
      expect(groups, isNot(contains(ControlActionGroup.backing)));
      expect(groups, isNot(contains(ControlActionGroup.sessions)));
    });

    test('every group listing is a subset of the catalogue, in its order', () {
      final catalogue = controlActionCatalogue();
      for (final group in controlActionGroups()) {
        final listed = controlActionsIn(group);
        expect(listed, isNotEmpty);
        expect(
          listed,
          catalogue.where((a) => a.group == group).toList(),
        );
      }
    });
  });

  group('ActionScope', () {
    test('round-trips its tokens', () {
      for (final scope in [
        const SelectedTrackScope(),
        const AllTracksScope(),
        const FixedTrackScope(0),
        const FixedTrackScope(7),
      ]) {
        expect(ActionScope.tryParse(scope.token), scope);
      }
    });

    test('refuses a channel the rig does not have', () {
      expect(ActionScope.tryParse('8'), isNull);
      expect(ActionScope.tryParse('-1'), isNull);
      expect(ActionScope.tryParse('everything'), isNull);
    });
  });
}
