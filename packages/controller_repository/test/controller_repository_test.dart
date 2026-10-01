import 'dart:async';

import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source implements ControllerSource {
  final controller = StreamController<ControllerSourceEvent>();
  int disposals = 0;
  @override
  Stream<ControllerSourceEvent> get inputs => controller.stream;
  @override
  Future<void> dispose() async {
    disposals++;
    await controller.close();
  }
}

void main() {
  test(
    'fans in exact full-byte console samples and unavailable identity',
    () async {
      final first = _Source();
      final second = _Source();
      final repository = ControllerRepository(sources: [first, second]);
      final events = <ControllerDispatchEvent>[];
      repository.bindingEvents.listen(events.add);
      const samples = [
        RawControllerInput(
          kind: ControllerSourceKind.consoleExpression,
          id: 0,
          value: 255,
        ),
        RawControllerInput(
          kind: ControllerSourceKind.consoleSwitch,
          id: 1,
          value: 192,
        ),
        ControllerSourceUnavailable(
          MappingTrigger(kind: ControllerSourceKind.consoleSwitch, id: 1),
        ),
      ];
      first.controller.add(samples[0]);
      await Future<void>.delayed(Duration.zero);
      second.controller.add(samples[1]);
      second.controller.add(samples[2]);
      await Future<void>.delayed(Duration.zero);
      expect(events, samples.map(ControllerConsoleEvent.new).toList());
      await repository.dispose();
      await repository.dispose();
      expect(first.disposals, 1);
      expect(second.disposals, 1);
    },
  );

  test(
    'musical MIDI has no implicit transport CC or console dispatch',
    () async {
      final source = _Source();
      final repository = ControllerRepository(sources: [source]);
      final events = <ControllerDispatchEvent>[];
      repository.bindingEvents.listen(events.add);
      for (var id = 80; id <= 86; id++) {
        source.controller.add(
          RawControllerInput(
            kind: ControllerSourceKind.midiCc,
            id: id,
            value: 127,
          ),
        );
      }
      source.controller.add(
        const RawControllerInput(
          kind: ControllerSourceKind.midiNote,
          id: 36,
          value: 127,
        ),
      );
      source.controller.add(
        const RawControllerInput(
          kind: ControllerSourceKind.midiProgram,
          id: 0,
          value: 127,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await repository.dispose();
    },
  );
}
