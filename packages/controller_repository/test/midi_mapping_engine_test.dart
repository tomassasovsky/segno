import 'package:controller_repository/src/controller_input.dart';
import 'package:controller_repository/src/midi_mapping.dart';
import 'package:controller_repository/src/midi_mapping_engine.dart';
import 'package:controller_repository/src/midi_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MidiSource source({
    ControllerSourceKind kind = ControllerSourceKind.midiNote,
    MidiProtocol protocol = MidiProtocol.standard,
  }) => MidiSource(
    device: 'device-a',
    kind: kind,
    number: 21,
    channel: 2,
    protocol: protocol,
  );

  MidiControlEvent event(MidiSource source, int value, {int? delta}) =>
      MidiControlEvent(
        source: source,
        value: value,
        maximum: 127,
        delta: delta,
      );

  MidiMapping mapping(
    String id,
    MidiSource source,
    MidiBehavior behavior,
    List<MidiControl> controls,
  ) => MidiMapping(
    id: id,
    source: source,
    behavior: behavior,
    controls: controls,
  );

  test('refused press never creates a held action or release', () {
    final note = source();
    final engine = MidiMappingEngine(read: (_) => 0.5, step: (_) => 0.01)
      ..setMappings(
        MidiMappingSet(
          mappings: [
            mapping('m', note, MidiBehavior.momentary, [
              MidiActionControl(key: 'undo'),
            ]),
          ],
        ),
      );
    final press = engine.prepare(event(note, 100)).single;
    expect(press.operations.single, isA<MidiActionRun>());
    engine.settle(press, {});
    expect(engine.prepare(event(note, 0)), isEmpty);
    expect(engine.retryCleanup(), isEmpty);
  });

  test('accepted hold survives refused release and retries by generation', () {
    final note = source();
    final engine = MidiMappingEngine(read: (_) => 0.5, step: (_) => 0.01)
      ..setMappings(
        MidiMappingSet(
          mappings: [
            mapping('m', note, MidiBehavior.momentary, [
              MidiActionControl(key: 'undo'),
              MidiParameterControl(key: 'gain', low: 0.2, high: 0.8),
            ]),
          ],
        ),
      );
    final press = engine.prepare(event(note, 100)).single;
    engine.settle(press, {0, 1});
    final release = engine.prepare(event(note, 0)).single;
    expect(release.operations, [
      isA<MidiActionEnd>(),
      isA<MidiParameterWrite>(),
    ]);
    engine.settle(release, {0});
    final retry = engine.retryCleanup().single;
    expect(retry.operations.single, isA<MidiParameterWrite>());
    final write = retry.operations.single as MidiParameterWrite;
    expect((write.held, write.cleanup, write.value), (false, true, 0.2));
    engine.settle(retry, {1});
    expect(engine.retryCleanup(), isEmpty);
  });

  test(
    'release proposes cleanup even when target read becomes unavailable',
    () {
      final note = source();
      var available = true;
      final engine =
          MidiMappingEngine(
            read: (_) => available ? 0.5 : null,
            step: (_) => 0.01,
          )..setMappings(
            MidiMappingSet(
              mappings: [
                mapping('m', note, MidiBehavior.momentary, [
                  MidiParameterControl(key: 'gain', low: 0.2, high: 0.8),
                ]),
              ],
            ),
          );
      final press = engine.prepare(event(note, 100)).single;
      engine.settle(press, {0});
      available = false;
      final release = engine.prepare(event(note, 0)).single;
      expect((release.operations.single as MidiParameterWrite).held, false);
      engine.settle(release, {});
      expect(engine.retryCleanup(), hasLength(1));
    },
  );

  test(
    'refused repress retains old cleanup, accepted repress supersedes it',
    () {
      final note = source();
      final engine = MidiMappingEngine(read: (_) => 0.5, step: (_) => 0.01)
        ..setMappings(
          MidiMappingSet(
            mappings: [
              mapping('m', note, MidiBehavior.momentary, [
                MidiParameterControl(key: 'gain', low: 0.2, high: 0.8),
              ]),
            ],
          ),
        );
      final first = engine.prepare(event(note, 100)).single;
      engine.settle(first, {0});
      final release = engine.prepare(event(note, 0)).single;
      engine.settle(release, {});
      final refusedRepress = engine.prepare(event(note, 100)).single;
      engine.settle(refusedRepress, {});
      final retry = engine.retryCleanup().single;
      expect((retry.operations.single as MidiParameterWrite).value, 0.2);
      final secondRelease = engine.prepare(event(note, 0)).single;
      engine.settle(secondRelease, {});
      final acceptedRepress = engine.prepare(event(note, 100)).single;
      engine.settle(acceptedRepress, {0});
      expect(engine.retryCleanup(), isEmpty);
    },
  );

  test('same-ID replacement preserves old refused cleanup separately', () {
    final note = source();
    final original = mapping('m', note, MidiBehavior.momentary, [
      MidiParameterControl(key: 'gain', low: 0.2, high: 0.8),
    ]);
    final engine = MidiMappingEngine(read: (_) => 0.5, step: (_) => 0.01)
      ..setMappings(MidiMappingSet(mappings: [original]));
    final press = engine.prepare(event(note, 100)).single;
    engine.settle(press, {0});
    final changed = original.copyWith(
      controls: [
        MidiParameterControl(key: 'gain', low: 0.1, high: 0.9),
      ],
    );
    final retirement = engine
        .setMappings(
          MidiMappingSet(mappings: [changed]),
        )
        .single;
    expect(retirement.operations.single, isA<MidiParameterWrite>());
    engine.settle(retirement, {});
    final newPress = engine.prepare(event(note, 100)).single;
    expect(newPress.generation, isNot(retirement.generation));
    engine.settle(newPress, {0});
    final retry = engine.retryCleanup().single;
    expect(retry.generation, retirement.generation);
    engine.settle(retry, {0});
    expect(engine.retryCleanup(), isEmpty);
    expect(engine.retire(mappingId: 'm'), hasLength(1));
  });

  test('toggle and sibling admission advance independently', () {
    final note = source();
    final engine = MidiMappingEngine(read: (_) => 0.5, step: (_) => 0.01)
      ..setMappings(
        MidiMappingSet(
          mappings: [
            mapping('m', note, MidiBehavior.toggle, [
              MidiParameterControl(key: 'a', low: 0, high: 1),
              MidiParameterControl(key: 'b', low: 0, high: 1),
            ]),
          ],
        ),
      );
    final first = engine.prepare(event(note, 100)).single;
    engine.settle(first, {0});
    expect(engine.prepare(event(note, 0)), isEmpty);
    final second = engine.prepare(event(note, 100)).single;
    expect(
      second.operations.whereType<MidiParameterWrite>().map((op) => op.value),
      [0, 1],
    );
  });

  test('continuous pickup and relative steps commit only after admission', () {
    final cc = source(kind: ControllerSourceKind.midiCc);
    var current = 0.5;
    final engine = MidiMappingEngine(read: (_) => current, step: (_) => 0.1)
      ..setMappings(
        MidiMappingSet(
          mappings: [
            mapping('m', cc, MidiBehavior.continuous, [
              MidiParameterControl(key: 'gain', low: 0, high: 1),
            ]),
          ],
        ),
      );
    expect(engine.prepare(event(cc, 0)), isEmpty);
    final pickup = engine.prepare(event(cc, 64)).single;
    engine.settle(pickup, {});
    current = 0.9;
    expect(engine.prepare(event(cc, 65)), isEmpty);
    final cross = engine.prepare(event(cc, 120)).single;
    engine.settle(cross, {0});
    expect(engine.prepare(event(cc, 119)), hasLength(1));

    final relative = source(
      kind: ControllerSourceKind.midiCc,
      protocol: MidiProtocol.relative,
    );
    engine.setMappings(
      MidiMappingSet(
        mappings: [
          mapping('r', relative, MidiBehavior.continuous, [
            MidiParameterControl(key: 'gain', low: 1, high: 0),
          ]),
        ],
      ),
    );
    final step = engine.prepare(event(relative, 1, delta: 1)).single;
    expect((step.operations.single as MidiParameterWrite).value, 0.8);
  });
}
