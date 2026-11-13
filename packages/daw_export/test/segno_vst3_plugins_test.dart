import 'dart:io';

import 'package:daw_export/src/effect_text.dart';
import 'package:daw_export/src/segno_vst3_plugins.dart';
import 'package:test/test.dart';

void main() {
  group('segnoPlugins', () {
    test('is the class table Segno.vst3 is built from', () {
      final header = File('../segno_engine/vst3/segno_fx_kinds.h')
          .readAsStringSync();
      final rows = RegExp(r'\{(\d+), "([^"]+)", "[^"]+", \{([^}]+)\}')
          .allMatches(header)
          .toList();
      expect(rows, hasLength(segnoPlugins.length));
      for (final row in rows) {
        final plugin = segnoPlugins[int.parse(row[1]!)]!;
        expect(plugin.name, row[2]);
        expect(plugin.processorId, [
          for (final w in row[3]!.split(','))
            int.parse(w.trim().substring(2), radix: 16),
        ]);
      }
    });

    test('names every kind as the console does', () {
      for (final MapEntry(:key, :value) in segnoPlugins.entries) {
        expect(value.name, 'Segno ${effectTypeNames[key]}');
      }
    });

    test('gives Live each class id word as a signed integer', () {
      expect(segnoPlugins[1]!.liveUidFields, [
        0x3B6057BF,
        0xB0624797 - 0x100000000,
        0xABA2EBB8 - 0x100000000,
        0x599AAE91,
      ]);
    });
  });

  group('SegnoPluginState', () {
    test('encodes the bytes segno_fx_state.h encodes', () {
      // encodeState of the same state, from the plugin's own header.
      const golden =
          '53474658010000001B0000000300000080000000005ED0B20000000000A04240'
          '0300000001000000000080BE0000C03F0000000003000000508DD73E0000003F'
          'CDCC4C3E';
      const state = SegnoPluginState(
        type: 27,
        params: [0.421, 0.5, 0.2],
        slot: 3,
        hopSeed: 128,
        clockOffset: 3000000000,
        beatOffset: 37.25,
        input: 3,
        output: 1,
        placement: -0.25,
        level: 1.5,
        enabled: false,
      );
      expect(
        state
            .encode()
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join()
            .toUpperCase(),
        golden,
      );
    });
  });
}
