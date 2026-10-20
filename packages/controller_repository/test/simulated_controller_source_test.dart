import 'package:controller_repository/controller_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'forwards exact console samples and ignores pushes after close',
    () async {
      final source = SimulatedControllerSource();
      final inputs = <RawControllerInput>[];
      source.inputs.listen(inputs.add);
      const input = RawControllerInput(
        kind: ControllerSourceKind.consoleExpression,
        id: 1,
        value: 231,
      );
      source.push(input);
      await Future<void>.delayed(Duration.zero);
      expect(inputs, [input]);
      await source.dispose();
      source.push(input);
      expect(inputs, [input]);
    },
  );
}
