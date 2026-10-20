import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/control/binding/control_value_target.dart';
import 'package:segno/control/binding/midi_mapping_draft.dart';

MidiSource _source({
  ControllerSourceKind kind = ControllerSourceKind.midiCc,
  int number = 21,
  int? channel = 0,
  MidiProtocol protocol = MidiProtocol.standard,
}) => MidiSource(
  device: 'usb',
  kind: kind,
  number: number,
  channel: channel,
  protocol: protocol,
);

void main() {
  test('draft detaches control list and preserves unavailable stable keys', () {
    final controls = <MidiControl>[
      MidiParameterControl(key: 'unavailable:target', low: 0.2, high: 0.8),
    ];
    final draft = MidiMappingDraft(device: 'usb', controls: controls);
    controls.clear();
    expect(draft.controls, hasLength(1));
    expect(draft.controls.clear, throwsUnsupportedError);
    expect(draft.learned(_source()).canSaveIn(MidiMappingSet.empty), isTrue);
  });

  test('incomplete and incompatible drafts cannot construct Save mapping', () {
    final blank = MidiMappingDraft(device: 'usb');
    expect(blank.canSaveIn(MidiMappingSet.empty), isFalse);
    expect(blank.learned(_source()).toMapping('draft'), isNull);
    final relative = MidiSource(
      device: 'usb',
      kind: ControllerSourceKind.midiCc,
      number: 21,
      protocol: MidiProtocol.relative,
    );
    final incompatible = blank
        .learned(relative)
        .withControl(
          MidiActionControl(key: 'command:undo'),
        );
    expect(incompatible.canSaveIn(MidiMappingSet.empty), isFalse);
    expect(incompatible.toMapping('draft'), isNull);
  });

  test('Program stays trigger when an action is added after Learn', () {
    final program = _source(kind: ControllerSourceKind.midiProgram);
    final draft = MidiMappingDraft(device: 'usb')
        .learned(program)
        .withControl(
          MidiActionControl(key: 'command:undo', trigger: MidiEdge.release),
        );
    expect(draft.behavior, MidiBehavior.trigger);
    expect(
      (draft.controls.single as MidiActionControl).trigger,
      MidiEdge.press,
    );
    expect(draft.canSaveIn(MidiMappingSet.empty), isTrue);
  });

  test(
    'repointing unavailable parameter and action retains position/values',
    () {
      final draft = MidiMappingDraft(
        device: 'usb',
        controls: [
          MidiActionControl(key: 'old:action', trigger: MidiEdge.release),
          MidiParameterControl(key: 'old:param', low: 0.7, high: 0.1),
        ],
      );
      final repaired = draft
          .repointingAction('old:action', 'command:undo')
          .repointing('old:param', 'trackVolume:0');
      expect(
        (repaired.controls.first as MidiActionControl).trigger,
        MidiEdge.release,
      );
      final parameter = repaired.controls.last as MidiParameterControl;
      expect(
        (parameter.key, parameter.low, parameter.high),
        ('trackVolume:0', 0.7, 0.1),
      );
      expect(
        repaired.repointingAction('command:undo', 'trackVolume:0'),
        repaired,
      );
    },
  );

  test('disabled saved source still blocks overlap until channel changes', () {
    final existing = MidiMapping(
      id: 'm1',
      source: _source(),
      behavior: MidiBehavior.continuous,
      controls: [MidiParameterControl(key: 'gain', low: 0, high: 1)],
      enabled: false,
    );
    final set = MidiMappingSet(mappings: [existing]);
    final draft = MidiMappingDraft(device: 'usb')
        .learned(_source())
        .withControl(MidiParameterControl(key: 'other', low: 0, high: 1));
    expect(draft.conflictIn(set), existing);
    expect(draft.canSaveIn(set), isFalse);
    expect(draft.withChannel(1).canSaveIn(set), isTrue);
    expect(MidiMappingDraft.of(existing).canSaveIn(set), isTrue);
  });

  test('a literal 1.0 on a level fader is unity at authoring, repointing '
      'and reload', () {
    const volume = TrackVolumeTarget(0);
    const lane = LaneVolumeTarget(0, 1);
    final unity = volume.mappingTop;
    var draft = MidiMappingDraft(device: 'usb').withControl(
      MidiParameterControl(key: volume.canonicalString(), low: 0, high: .5),
    );
    draft = draft.withRange(volume.canonicalString(), high: 1);
    final authored = draft.controls.single as MidiParameterControl;
    expect(authored.high, unity);
    expect(volume.toDomain(authored.high), closeTo(1.0, 1e-9));
    // A full-travel mapping repointed onto a level fader tops at unity.
    final param = const FxParamTarget(
      address: FxAddress(stage: FxStage.track),
      slotId: 'drive',
      param: 0,
    ).canonicalString();
    final repointed = MidiMappingDraft(device: 'usb')
        .withControl(MidiParameterControl(key: param, low: 0, high: 1))
        .repointing(param, lane.canonicalString());
    expect(
      (repointed.controls.single as MidiParameterControl).high,
      lane.mappingTop,
    );
    expect(lane.mappingTop, unity);
  });
}
