import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart'
    show LE_INST_REMAP_CC, LE_INST_REMAP_NOTE, le_inst_routes;
import 'package:segno_engine/src/native_audio_engine.dart'
    show writeInstrumentRoutes;

void main() {
  group('InstrumentRoute.isValid', () {
    test('accepts the full ranges', () {
      const route = InstrumentRoute(
        midiEnabled: true,
        port: 7,
        channel: 16,
        remaps: [
          InstrumentRemap(
            port: 7,
            channel: 16,
            kind: MidiRemapKind.controller,
            number: 127,
            notes: [0, 127, 1, 2, 3, 4, 5, 6],
          ),
        ],
      );
      expect(route.isValid, isTrue);
      expect(InstrumentRoute.disabled.isValid, isTrue);
    });

    test('refuses every field out of range', () {
      const ok = InstrumentRemap(
        port: 0,
        kind: MidiRemapKind.note,
        number: 36,
        notes: [48],
      );
      for (final route in [
        const InstrumentRoute(midiEnabled: true, port: 8),
        const InstrumentRoute(midiEnabled: true, channel: 17),
        const InstrumentRoute(midiEnabled: true, low: -1),
        const InstrumentRoute(midiEnabled: true, low: 60, high: 59),
        const InstrumentRoute(midiEnabled: true, high: 128),
        InstrumentRoute(
          midiEnabled: true,
          remaps: List.filled(kMaxInstrumentRemaps + 1, ok),
        ),
      ]) {
        expect(route.isValid, isFalse, reason: '$route');
      }
      for (final remap in [
        const InstrumentRemap(
          port: -1,
          kind: MidiRemapKind.note,
          number: 1,
          notes: [1],
        ),
        const InstrumentRemap(
          port: 0,
          kind: MidiRemapKind.note,
          number: 128,
          notes: [1],
        ),
        const InstrumentRemap(
          port: 0,
          kind: MidiRemapKind.note,
          number: 1,
          notes: [],
        ),
        const InstrumentRemap(
          port: 0,
          kind: MidiRemapKind.note,
          number: 1,
          notes: [1, 2, 3, 4, 5, 6, 7, 8, 9],
        ),
        const InstrumentRemap(
          port: 0,
          kind: MidiRemapKind.note,
          number: 1,
          notes: [200],
        ),
      ]) {
        expect(remap.isValid, isFalse);
      }
    });

    test('compares by value', () {
      const a = InstrumentRoute(
        midiEnabled: true,
        channel: 10,
        remaps: [
          InstrumentRemap(
            port: 0,
            kind: MidiRemapKind.note,
            number: 36,
            notes: [48, 52],
          ),
        ],
      );
      const b = InstrumentRoute(
        midiEnabled: true,
        channel: 10,
        remaps: [
          InstrumentRemap(
            port: 0,
            kind: MidiRemapKind.note,
            number: 36,
            notes: [48, 52],
          ),
        ],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(InstrumentRoute.disabled));
    });
  });

  group('writeInstrumentRoutes', () {
    test('writes every slot, the missing ones disabled', () {
      final table = calloc<le_inst_routes>();
      addTearDown(() => calloc.free(table));
      writeInstrumentRoutes(table.ref, const [
        InstrumentRoute(midiEnabled: true, port: 2, channel: 10, low: 36),
        InstrumentRoute(
          midiEnabled: true,
          port: 3,
          high: 72,
          remaps: [
            InstrumentRemap(
              port: 3,
              channel: 2,
              kind: MidiRemapKind.controller,
              number: 64,
              notes: [60, 67],
            ),
          ],
        ),
      ]);
      final r = table.ref;
      expect(r.inst[0].midi_enabled, 1);
      expect(r.inst[0].port, 2);
      expect(r.inst[0].channel, 10);
      expect(r.inst[0].low, 36);
      expect(r.inst[0].high, 127);
      expect(r.inst[0].remap_count, 0);
      expect(r.inst[1].high, 72);
      expect(r.inst[1].remap_count, 1);
      expect(r.inst[1].remaps[0].kind, LE_INST_REMAP_CC);
      expect(r.inst[1].remaps[0].channel, 2);
      expect(r.inst[1].remaps[0].number, 64);
      expect(r.inst[1].remaps[0].count, 2);
      expect(r.inst[1].remaps[0].notes[1], 67);
      for (var k = 2; k < kMaxInstruments; k++) {
        expect(r.inst[k].midi_enabled, 0);
      }
      expect(LE_INST_REMAP_NOTE, isNot(LE_INST_REMAP_CC));
    });

    test('passes an over-long remap list on as a count the engine refuses', () {
      final table = calloc<le_inst_routes>();
      addTearDown(() => calloc.free(table));
      writeInstrumentRoutes(table.ref, [
        InstrumentRoute(
          midiEnabled: true,
          remaps: List.filled(
            kMaxInstrumentRemaps + 1,
            const InstrumentRemap(
              port: 0,
              kind: MidiRemapKind.note,
              number: 1,
              notes: [1, 2, 3, 4, 5, 6, 7, 8, 9],
            ),
          ),
        ),
      ]);
      expect(table.ref.inst[0].remap_count, kMaxInstrumentRemaps + 1);
      expect(table.ref.inst[0].remaps[0].count, 9);
    });
  });

  group('snapshots', () {
    test('start empty', () {
      const s = EngineSnapshot.initial();
      expect(s.instruments, InstrumentsSnapshot.initial);
      expect(s.instruments.patches, everyElement(-1));
      expect(s.instruments.totalVoices, 0);
      expect(s.midiInput, MidiInputSnapshot.initial);
      expect(s.midiInput.isAttached(0), isFalse);
    });

    test('take part in snapshot equality', () {
      const s = EngineSnapshot.initial();
      final voiced = s.copyWith(
        instruments: const InstrumentsSnapshot(
          patches: [6, -1, -1, -1, -1, -1, -1, -1],
          voices: [1, 0, 0, 0, 0, 0, 0, 0],
          peaks: [0, 0, 0, 0, 0, 0, 0, 0],
          monitorPeaks: [0, 0, 0, 0, 0, 0, 0, 0],
          synthEpoch: 1,
        ),
      );
      expect(voiced, isNot(s));
      expect(voiced.instruments.totalVoices, 1);
      final attached = s.copyWith(
        midiInput: const MidiInputSnapshot(attachedMask: 0x5),
      );
      expect(attached, isNot(s));
      expect(attached.midiInput.isAttached(2), isTrue);
      expect(attached.midiInput.isAttached(1), isFalse);
      expect(attached.copyWith(), attached);
      expect(attached.copyWith().hashCode, attached.hashCode);
    });
  });

  test('a capture handle compares by its pointer', () {
    final a = MidiCaptureHandle(Pointer.fromAddress(0x40));
    expect(a, MidiCaptureHandle(Pointer.fromAddress(0x40)));
    expect(a.hashCode, MidiCaptureHandle(Pointer.fromAddress(0x40)).hashCode);
    expect(a, isNot(MidiCaptureHandle(Pointer.fromAddress(0x80))));
  });
}
