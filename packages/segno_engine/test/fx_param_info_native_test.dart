@Tags(['fuzz'])
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/ffi_strings.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';

/// The `LE_FX_PARAM_TAPER_UNVERIFIED` bit of `le_fx_param_desc.flags`.
const int _taperUnverified = 1 << 0;

/// The `LE_FX_PARAM_OFF_AT_MIN` and `LE_FX_PARAM_OFF_AT_MAX` bits.
const int _offAtMin = 1 << 1;
const int _offAtMax = 1 << 2;

/// The value a Dart double holds once stored in a C `float`, so the Dart copy
/// of the table compares exactly against the native one.
double _asFloat(double value) => Float32List.fromList([value])[0];

/// The Dart copy of the built-in parameter table ([TrackEffectType.params])
/// against the engine's own `le_fx_param_info`. Self-skips when
/// `SEGNO_ENGINE_LIB` is unset; build it first:
///   export SEGNO_ENGINE_LIB="$(bash tool/build_test_lib.sh)"
void main() {
  final lib = Platform.environment['SEGNO_ENGINE_LIB'];
  final skip = lib == null || lib.isEmpty
      ? 'SEGNO_ENGINE_LIB not set — run tool/build_test_lib.sh'
      : null;

  test(
    'every built-in parameter matches le_fx_param_info field by field',
    () {
      final bindings = SegnoEngineBindings(DynamicLibrary.open(lib!));
      final desc = calloc<le_fx_param_desc>();
      addTearDown(() => calloc.free(desc));
      for (final type in TrackEffectType.values) {
        final params = type.params;
        expect(
          bindings.le_fx_param_count(type.code),
          params.length,
          reason: type.name,
        );
        for (var i = 0; i < params.length; i++) {
          final p = params[i];
          final reason = '${type.name}[$i]';
          expect(bindings.le_fx_param_info(type.code, i, desc), 0);
          final native = desc.ref;
          expect(
            readNativeString(native.key, capacity: LE_FX_PARAM_KEY_CHARS),
            p.key,
            reason: reason,
          );
          expect(native.unit, p.unit.code, reason: reason);
          expect(native.steps, p.steps, reason: reason);
          expect(native.at_min, _asFloat(p.atMin), reason: reason);
          expect(native.at_max, _asFloat(p.atMax), reason: reason);
          expect(native.curve, p.curve.code, reason: reason);
          expect(native.def, _asFloat(p.defaultValue), reason: reason);
          expect(
            native.flags & _taperUnverified != 0,
            p.taperUnverified,
            reason: reason,
          );
          expect(
            native.flags & (_offAtMin | _offAtMax),
            switch (p.off) {
              FxParamOff.none => 0,
              FxParamOff.atMin => _offAtMin,
              FxParamOff.atMax => _offAtMax,
            },
            reason: reason,
          );
          expect(
            native.flags & ~(_taperUnverified | _offAtMin | _offAtMax),
            0,
            reason: reason,
          );
        }
        // One past the last parameter is refused.
        expect(
          bindings.le_fx_param_info(type.code, params.length, desc),
          isNot(0),
          reason: type.name,
        );
      }
      // A hosted plugin has no fixed parameters; an unknown type is refused.
      expect(bindings.le_fx_param_count(kPluginFxCode), 0);
      final last = TrackEffectType.values.map((t) => t.code).reduce(math.max);
      expect(bindings.le_fx_param_count(last + 1), lessThan(0));
    },
    skip: skip,
  );
}
