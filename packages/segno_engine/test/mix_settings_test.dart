import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart'
    show LE_MAX_INPUT_TRIM, le_mix_settings;

void main() {
  test('trim endpoints survive validation and the native Float32 payload', () {
    final minimum = inputTrimGainOfDb(-24);
    final maximum = inputTrimGainOfDb(12);
    final settings = EngineMixSettings(
      revision: 1,
      trims: {0: minimum, 1: maximum},
    );
    expect(minimum, closeTo(0.06309573444801933, 1e-16));
    expect(maximum, closeTo(3.9810717055349722, 1e-15));
    expect(settings.isValid, isTrue);

    final payload = calloc<le_mix_settings>();
    addTearDown(() => calloc.free(payload));
    payload.ref.input_trim[0] = minimum;
    payload.ref.input_trim[1] = maximum;
    expect(payload.ref.input_trim[0], Float32List.fromList([minimum]).single);
    expect(payload.ref.input_trim[1], LE_MAX_INPUT_TRIM);
  });

  test('the next Float32 above the native trim maximum is rejected', () {
    final bits = ByteData(4)..setFloat32(0, LE_MAX_INPUT_TRIM);
    bits.setUint32(0, bits.getUint32(0) + 1);
    final above = bits.getFloat32(0);
    expect(above, greaterThan(LE_MAX_INPUT_TRIM));
    expect(EngineMixSettings(revision: 1, trims: {0: above}).isValid, isFalse);
  });

  test('a record image takes heard lanes inside the lane range (#1713)', () {
    RecordImage image(Set<int> heard) => RecordImage(
      revision: 1,
      lanes: const {0: (gain: 1, pan: 0)},
      heardLanes: heard,
    );
    expect(image(const {0, 7}).isValid, isTrue);
    expect(image(const {8}).isValid, isFalse);
    expect(image(const {-1}).isValid, isFalse);
    expect(image(const {0}).heardLanes, const {0});
  });
}
