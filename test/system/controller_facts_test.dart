import 'package:console_facts_client/console_facts_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/pedal/pedal.dart';
import 'package:segno/system/controller_facts.dart';

void main() {
  const record = ConsoleBoardFlash(firmware: '1.3', protocol: 7);

  group('ControllerFacts.read', () {
    test('a talking board is its own answer, over any record', () {
      final facts = ControllerFacts.read(
        pedal: const PedalState(
          status: PedalLinkStatus.connected,
          firmwareVersion: '1.4',
          protocolVersion: 8,
        ),
        lastFlashed: record,
      );
      expect(
        facts,
        const ControllerFacts(
          source: ControllerFactsSource.reported,
          firmware: '1.4',
          protocol: 8,
        ),
      );
      expect(facts.updateSupported, isFalse);
    });

    test('an incompatible board still reports what it runs', () {
      final facts = ControllerFacts.read(
        pedal: const PedalState(
          status: PedalLinkStatus.incompatible,
          firmwareVersion: '2.0',
          protocolVersion: 9,
        ),
        lastFlashed: record,
      );
      expect(facts.source, ControllerFactsSource.reported);
      expect(facts.firmware, '2.0');
      expect(facts.protocol, 9);
    });

    test('a silent board falls back to the flash record', () {
      final facts = ControllerFacts.read(
        pedal: const PedalState(),
        lastFlashed: record,
      );
      expect(
        facts,
        const ControllerFacts(
          source: ControllerFactsSource.lastFlashed,
          firmware: '1.3',
          protocol: 7,
        ),
      );
    });

    test('neither reports nothing', () {
      final facts = ControllerFacts.read(
        pedal: const PedalState(),
        lastFlashed: null,
      );
      expect(
        facts,
        const ControllerFacts(source: ControllerFactsSource.notReported),
      );
      expect(facts.firmware, isNull);
      expect(facts.protocol, isNull);
      expect(facts.updateSupported, isFalse);
    });
  });
}
