import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/control/binding/midi_mapping_draft.dart';

const _device = 'usb';
const _mix = 'param:mix';
const _mute = 'mode:mute';

MidiSource _source({
  ControllerSourceKind kind = ControllerSourceKind.midiCc,
  int number = 21,
  int? channel = 0,
  MidiProtocol protocol = MidiProtocol.standard,
  int? bank,
}) => MidiSource(
  device: _device,
  kind: kind,
  number: number,
  channel: channel,
  protocol: protocol,
  bank: bank,
);

/// The editor's rules, one edit at a time.
void main() {
  const blank = MidiMappingDraft(device: _device);

  group('learning', () {
    test('a CC is a knob, a Note a button, a Program a trigger', () {
      expect(blank.learned(_source()).behavior, MidiBehavior.continuous);
      expect(
        blank.learned(_source(kind: ControllerSourceKind.midiNote)).behavior,
        MidiBehavior.momentary,
      );
      expect(
        blank.learned(_source(kind: ControllerSourceKind.midiProgram)).behavior,
        MidiBehavior.trigger,
      );
    });

    test('a CC that drives actions is a button', () {
      final draft = blank
          .withControl(const MidiActionControl(key: _mute))
          .learned(_source());
      expect(draft.behavior, MidiBehavior.momentary);
    });

    test('a Program runs every action on the press', () {
      final draft = blank
          .withControl(
            const MidiActionControl(key: _mute, trigger: MidiEdge.release),
          )
          .learned(_source(kind: ControllerSourceKind.midiProgram));
      expect(
        (draft.controls.single as MidiActionControl).trigger,
        MidiEdge.press,
      );
      expect(draft.canSaveIn(const MidiMappingSet()), isTrue);
    });

    test('learning again starts the behavior over', () {
      final draft = blank
          .learned(_source(kind: ControllerSourceKind.midiNote))
          .withBehavior(MidiBehavior.toggle)
          .learned(_source());
      expect(draft.behavior, MidiBehavior.continuous);
    });
  });

  group('controls', () {
    test('a key is driven once', () {
      final draft = blank
          .withControl(const MidiParameterControl(key: _mix, low: 0, high: 1))
          .withControl(
            const MidiParameterControl(key: _mix, low: 0.5, high: 0.6),
          );
      expect(draft.controls, hasLength(1));
      expect((draft.controls.single as MidiParameterControl).high, 1);
    });

    test('an action makes a knob a button, and leaves a toggle alone', () {
      final knob = blank.learned(_source());
      expect(
        knob.withControl(const MidiActionControl(key: _mute)).behavior,
        MidiBehavior.momentary,
      );
      expect(
        knob
            .withBehavior(MidiBehavior.toggle)
            .withControl(const MidiActionControl(key: _mute))
            .behavior,
        MidiBehavior.toggle,
      );
    });

    test('an action added to a Program runs on the press', () {
      final draft = blank
          .learned(_source(kind: ControllerSourceKind.midiProgram))
          .withControl(
            const MidiActionControl(key: _mute, trigger: MidiEdge.release),
          );
      expect(
        (draft.controls.single as MidiActionControl).trigger,
        MidiEdge.press,
      );
    });

    test('repointing keeps the place and the range', () {
      final draft = blank
          .withControl(
            const MidiParameterControl(key: _mix, low: 0.2, high: 0.8),
          )
          .withControl(const MidiActionControl(key: _mute))
          .repointing(_mix, 'param:time');
      expect(draft.controls.first, isA<MidiParameterControl>());
      final moved = draft.controls.first as MidiParameterControl;
      expect((moved.key, moved.low, moved.high), ('param:time', 0.2, 0.8));
      expect(
        draft.repointing('param:time', _mute).controls,
        draft.controls,
        reason: 'not onto a key it already drives',
      );
    });

    test('ranges, triggers and removal edit the one control', () {
      final draft = blank
          .withControl(const MidiParameterControl(key: _mix, low: 0, high: 1))
          .withControl(const MidiActionControl(key: _mute))
          .withRange(_mix, high: 0.4)
          .withTrigger(_mute, MidiEdge.release);
      expect((draft.controls.first as MidiParameterControl).high, 0.4);
      expect((draft.controls.first as MidiParameterControl).low, 0);
      expect(
        (draft.controls.last as MidiActionControl).trigger,
        MidiEdge.release,
      );
      expect(draft.without(_mute).controls, hasLength(1));
    });
  });

  group('what the editor offers', () {
    test('Knob or Button only for a plain CC', () {
      expect(blank.offersKnobOrButton, isFalse);
      expect(blank.learned(_source()).offersKnobOrButton, isTrue);
      expect(
        blank
            .learned(_source(kind: ControllerSourceKind.midiNote))
            .offersKnobOrButton,
        isFalse,
      );
      expect(
        blank.learned(_source(protocol: MidiProtocol.cc14)).offersKnobOrButton,
        isFalse,
      );
    });

    test('Momentary or Toggle for a button that is not a Program', () {
      expect(blank.offersButtonBehavior, isFalse);
      expect(blank.learned(_source()).offersButtonBehavior, isFalse);
      expect(
        blank
            .learned(_source(kind: ControllerSourceKind.midiNote))
            .offersButtonBehavior,
        isTrue,
      );
      expect(
        blank
            .learned(_source(kind: ControllerSourceKind.midiProgram))
            .offersButtonBehavior,
        isFalse,
      );
    });

    test('only a press-carrying format takes actions', () {
      expect(MidiMappingDraft.carriesActions(MidiProtocol.standard), isTrue);
      expect(MidiMappingDraft.carriesActions(MidiProtocol.bankProgram), isTrue);
      expect(MidiMappingDraft.carriesActions(MidiProtocol.cc14), isFalse);
      expect(MidiMappingDraft.carriesActions(MidiProtocol.nrpn), isFalse);
      expect(MidiMappingDraft.carriesActions(MidiProtocol.relative), isFalse);
    });
  });

  group('saving', () {
    final saved = const MidiMappingSet().withMapping(
      MidiMapping(
        id: 'm1',
        source: _source(),
        behavior: MidiBehavior.continuous,
        controls: const [MidiParameterControl(key: _mix, low: 0, high: 1)],
      ),
    );

    test('needs a control learned and something driven', () {
      expect(blank.canSaveIn(const MidiMappingSet()), isFalse);
      expect(
        blank.learned(_source()).canSaveIn(const MidiMappingSet()),
        isFalse,
      );
      expect(
        blank
            .learned(_source())
            .withControl(const MidiParameterControl(key: _mix, low: 0, high: 1))
            .canSaveIn(const MidiMappingSet()),
        isTrue,
      );
    });

    test('an overlap is refused until the channel moves away', () {
      final draft = blank
          .learned(_source(protocol: MidiProtocol.cc14))
          .withControl(const MidiParameterControl(key: _mix, low: 0, high: 1));
      expect(draft.conflictIn(saved)?.id, 'm1');
      expect(draft.canSaveIn(saved), isFalse);
      expect(draft.withChannel(null).conflictIn(saved)?.id, 'm1');
      final moved = draft.withChannel(3);
      expect(moved.conflictIn(saved), isNull);
      expect(moved.canSaveIn(saved), isTrue);
    });

    test('the mapping it edits is not a conflict, and keeps its id', () {
      final draft = MidiMappingDraft.of(saved.mappings.single);
      expect(draft.conflictIn(saved), isNull);
      expect(draft.canSaveIn(saved), isTrue);
      expect(draft.toMapping(saved.nextId)?.id, 'm1');
      expect(
        blank.learned(_source(number: 30)).toMapping(saved.nextId)?.id,
        'm2',
      );
    });

    test('a mapping that cannot drive what it carries is refused', () {
      final draft = blank
          .learned(_source(protocol: MidiProtocol.relative))
          .withControl(const MidiActionControl(key: _mute));
      expect(draft.canSaveIn(const MidiMappingSet()), isFalse);
    });
  });
}
