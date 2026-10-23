import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno_engine/segno_engine.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart'
    show LE_FX_LEVEL_MAX;

/// [head] padded with 0 to the [kTrackEffectParams] cells an entry holds.
List<double> cells(List<double> head) => [
  ...head,
  for (var i = head.length; i < kTrackEffectParams; i++) 0.0,
];

void main() {
  group('BuiltInEffect', () {
    test('defaults params to the type musical defaults', () {
      final fx = BuiltInEffect(type: TrackEffectType.delay);
      expect(fx.params, TrackEffectType.delay.defaultParams);
      expect(fx.params.length, greaterThan(0));
    });

    test('params is unmodifiable', () {
      final fx = BuiltInEffect(type: TrackEffectType.drive);
      expect(() => fx.params[0] = 1, throwsUnsupportedError);
    });

    test('toJson carries only type and params (no stage)', () {
      final json = BuiltInEffect(
        type: TrackEffectType.filter,
        params: const [0.1, 0.2, 0.3],
      ).toJson();
      expect(json.keys, containsAll(<String>['type', 'params']));
      expect(json.containsKey('stage'), isFalse);
      expect(json['type'], TrackEffectType.filter.code);
      // Only the two cells the filter reads: the third is past its
      // parameters, so it is 0 in the entry and absent from the wire.
      expect(json['params'], [0.1, 0.2]);
    });

    test('holds 0 past the type parameters, whatever it was given', () {
      final fx = BuiltInEffect(
        type: TrackEffectType.drive,
        params: [for (var i = 0; i < kTrackEffectParams; i++) 0.5],
      );
      expect(fx.params, cells(const [0.5, 0.5]));
    });

    test('typeCode is the native fx code', () {
      expect(BuiltInEffect(type: TrackEffectType.reverb).typeCode, 7);
    });

    test('fromJson ignores a legacy stage key', () {
      // Older persisted chains stored a `stage` integer from a different,
      // removed pre/post model. It is NOT this model's `placement` key and
      // must decode cleanly as the placement default. The length-3 params
      // from that era are padded to the current width with the type's
      // default.
      final fx = BuiltInEffect.fromJson(const {
        'type': 4,
        'stage': 1,
        'params': [0.4, 0.5, 0.6],
      });
      expect(fx.type, TrackEffectType.tremolo);
      // The tremolo reads two: the third saved cell is dropped.
      expect(fx.params, cells(const [0.4, 0.5]));
      expect(fx.placement, FxPlacement.post);
    });

    test(
      'fromJson falls back to none + defaults for unknown/missing fields',
      () {
        final fx = BuiltInEffect.fromJson(const {});
        expect(fx.type, TrackEffectType.none);
        expect(fx.params, TrackEffectType.none.defaultParams);
      },
    );

    test('copyWith replaces type and params independently', () {
      final base = BuiltInEffect(
        type: TrackEffectType.drive,
        params: const [0.1, 0.2, 0.3],
      );
      expect(
        base.copyWith(type: TrackEffectType.filter).type,
        TrackEffectType.filter,
      );
      // Another type starts at its own defaults; the same type keeps them.
      expect(
        base.copyWith(type: TrackEffectType.filter).params,
        TrackEffectType.filter.defaultParams,
      );
      expect(base.copyWith(type: TrackEffectType.drive).params, base.params);
      expect(
        base.copyWith(params: const [0.9, 0, 0]).params,
        cells(const [0.9, 0]),
      );
    });

    test('copyWith preserves the unmodifiable params contract', () {
      final copy = BuiltInEffect(type: TrackEffectType.drive).copyWith(
        params: [0.9, 0, 0],
      );
      expect(() => copy.params[0] = 0, throwsUnsupportedError);
    });

    test('fromJson pads a pre-rewrite 3-param chain to the current width', () {
      // A chain saved by the 3-param build: the octaver gains its new `mode`
      // slot, which must default to 0.0 (phase vocoder), not leave the list
      // short or read garbage.
      final fx = BuiltInEffect.fromJson({
        'type': TrackEffectType.octaver.code,
        'params': const [0.25, 0.5, 0.5],
      });
      expect(fx.type, TrackEffectType.octaver);
      expect(fx.params, cells(const [0.25, 0.5, 0.5, 0]));
      expect(fx.params, hasLength(kTrackEffectParams));
      expect(fx.params[3], 0.0); // mode == phase vocoder
    });

    test('fromJson pads with the type default, not a blanket zero', () {
      // delay's p2 default is 0.35; a 2-param save pads p2 from the default and
      // p3 from the (zero) default, proving the per-type pad (not a blanket 0).
      final fx = BuiltInEffect.fromJson({
        'type': TrackEffectType.delay.code,
        'params': const [0.1, 0.2],
      });
      expect(fx.params, cells(const [0.1, 0.2, 0.35]));
    });

    test('fromJson truncates an over-long params list', () {
      final fx = BuiltInEffect.fromJson({
        'type': TrackEffectType.drive.code,
        'params': const [0.1, 0.2, 0.3, 0.4, 0.5],
      });
      expect(fx.params, cells(const [0.1, 0.2]));
      expect(fx.params, hasLength(kTrackEffectParams));
    });

    test('fromJson falls back to defaults when params is not a list', () {
      final fx = BuiltInEffect.fromJson(const {
        'type': 1,
        'params': 'nonsense',
      });
      expect(fx.type, TrackEffectType.drive);
      expect(fx.params, TrackEffectType.drive.defaultParams);
    });

    test('value equality ignores instance identity', () {
      final a = BuiltInEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3],
      );
      final b = BuiltInEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3],
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('a differing type or param breaks equality', () {
      final a = BuiltInEffect(
        type: TrackEffectType.delay,
        params: const [0.1, 0.2, 0.3],
      );
      expect(a, isNot(equals(a.copyWith(type: TrackEffectType.drive))));
      expect(a, isNot(equals(a.copyWith(params: const [0.9, 0.2, 0.3]))));
    });

    test('the preset id and source values round-trip and count in '
        'equality', () {
      final fx = BuiltInEffect(
        type: TrackEffectType.none,
        module: 'Smart tune',
        presetId: 'preset-id',
        source: const {'Smart Tune': 0, 'Mode': 1, 'Key': 3 / 11},
      );

      final decoded = BuiltInEffect.fromJson(
        jsonDecode(jsonEncode(fx.toJson())) as Map<String, dynamic>,
      );

      expect(decoded, fx);
      expect(decoded.hashCode, fx.hashCode);
      expect(decoded.presetId, 'preset-id');
      expect(decoded.source, {'Smart Tune': 0, 'Mode': 1, 'Key': 3 / 11});
      expect(fx, isNot(equals(fx.copyWith(presetId: 'other'))));
      expect(fx, isNot(equals(fx.copyWith(source: const {'Mode': 0}))));
    });

    test('an entry with no preset writes neither key and decodes to none', () {
      final json = BuiltInEffect(type: TrackEffectType.drive).toJson();

      expect(json.containsKey('presetId'), isFalse);
      expect(json.containsKey('source'), isFalse);
      final decoded = BuiltInEffect.fromJson(json);
      expect(decoded.presetId, isNull);
      expect(decoded.source, isEmpty);
    });

    test('a wrong-typed preset id or source value decodes to the default', () {
      final decoded = BuiltInEffect.fromJson(const {
        'type': 0,
        'presetId': 7,
        'source': {'Mode': 'one', 'Key': 0.5},
      });

      expect(decoded.presetId, isNull);
      expect(decoded.source, {'Key': 0.5});
    });
  });

  group('PluginEffect', () {
    const ref = PluginRef(
      format: PluginFormat.vst3,
      id: 'ABCDEF0123456789',
      version: 0x00010200,
    );

    test('typeCode is the plugin fx code', () {
      expect(const PluginEffect(ref: ref).typeCode, kPluginFxCode);
      expect(kPluginFxCode, 8);
    });

    test('toJson carries the plugin ref under a plugin key', () {
      final json = const PluginEffect(ref: ref).toJson();
      expect(json['type'], kPluginFxCode);
      expect(json['plugin'], {
        'format': PluginFormat.vst3.code,
        'id': 'ABCDEF0123456789',
        'version': 0x00010200,
      });
    });

    test('round-trips through fromJson', () {
      final decoded = TrackEffect.fromJson(
        const PluginEffect(ref: ref).toJson(),
      );
      expect(decoded, isA<PluginEffect>());
      expect((decoded as PluginEffect).ref, ref);
    });

    test('copyWith and value equality', () {
      const a = PluginEffect(ref: ref);
      expect(a, const PluginEffect(ref: ref));
      const other = PluginRef(format: PluginFormat.clap, id: 'x');
      expect(a.copyWith(ref: other).ref, other);
      expect(a, isNot(const PluginEffect(ref: other)));
    });

    test('PluginRef round-trips and defaults version to 0', () {
      final json = const PluginRef(
        format: PluginFormat.clap,
        id: 'com.x',
      ).toJson();
      expect(json['version'], 0);
      expect(
        PluginRef.fromJson(json),
        const PluginRef(format: PluginFormat.clap, id: 'com.x'),
      );
    });

    test('paramValues round-trip through fromJson with string keys', () {
      const fx = PluginEffect(ref: ref, paramValues: {100: 0.25, 300: 0.9});
      final json = fx.toJson();
      // Persisted as JSON object keys (strings), values plain.
      expect(json['paramValues'], {'100': 0.25, '300': 0.9});
      final decoded = TrackEffect.fromJson(json) as PluginEffect;
      expect(decoded.paramValues, {100: 0.25, 300: 0.9});
      expect(decoded, fx);
    });

    test('omits paramValues when empty (part-4 byte-for-byte back-compat)', () {
      final json = const PluginEffect(ref: ref).toJson();
      expect(json.containsKey('paramValues'), isFalse);
    });

    test('a part-4 entry without paramValues decodes to an empty map', () {
      final decoded =
          TrackEffect.fromJson({'type': kPluginFxCode, 'plugin': ref.toJson()})
              as PluginEffect;
      expect(decoded.paramValues, isEmpty);
    });

    test('paramValues participates in equality', () {
      const a = PluginEffect(ref: ref, paramValues: {100: 0.5});
      expect(a, const PluginEffect(ref: ref, paramValues: {100: 0.5}));
      expect(a, isNot(const PluginEffect(ref: ref, paramValues: {100: 0.6})));
      expect(a, isNot(const PluginEffect(ref: ref)));
    });

    test('opaque state round-trips through JSON and counts in equality', () {
      const fx = PluginEffect(ref: ref, state: 'YmxvYg=='); // base64 "blob"
      final json = fx.toJson();
      expect(json['state'], 'YmxvYg==');
      final decoded = TrackEffect.fromJson(json) as PluginEffect;
      expect(decoded.state, 'YmxvYg==');
      expect(decoded, fx);
      expect(fx, isNot(const PluginEffect(ref: ref)));
    });

    test('omits state when empty (part-4/5 byte-for-byte back-compat)', () {
      expect(const PluginEffect(ref: ref).toJson().containsKey('state'), false);
    });

    test('a pre-state entry decodes to an empty state', () {
      final decoded =
          TrackEffect.fromJson({'type': kPluginFxCode, 'plugin': ref.toJson()})
              as PluginEffect;
      expect(decoded.state, isEmpty);
    });

    test('display name round-trips through JSON and counts in equality', () {
      const fx = PluginEffect(ref: ref, name: 'Big Reverb');
      final json = fx.toJson();
      expect(json['name'], 'Big Reverb');
      final decoded = TrackEffect.fromJson(json) as PluginEffect;
      expect(decoded.name, 'Big Reverb');
      expect(decoded, fx);
      expect(fx, isNot(const PluginEffect(ref: ref)));
    });

    test('omits name when empty (back-compat)', () {
      expect(const PluginEffect(ref: ref).toJson().containsKey('name'), false);
    });

    test('params metadata is transient — excluded from toJson + equality', () {
      const params = [
        PluginParamInfo(
          id: 100,
          name: 'Gain',
          unit: 'dB',
          min: 0,
          max: 1,
          def: 0.5,
          stepCount: 0,
          flags: 0x01,
        ),
      ];
      const withMeta = PluginEffect(ref: ref, params: params);
      expect(withMeta.toJson().containsKey('params'), isFalse);
      expect(withMeta, const PluginEffect(ref: ref));
    });
  });

  group('TrackEffectType', () {
    test('kFxLevelMax mirrors the native LE_FX_LEVEL_MAX', () {
      expect(kFxLevelMax, LE_FX_LEVEL_MAX);
    });

    test('kTrackEffectParams mirrors the native LE_FX_PARAMS width', () {
      // Pins the Dart side of the cross-language contract (the native test
      // asserts LE_FX_PARAMS == 32 in turn).
      expect(kTrackEffectParams, 32);
    });

    test('fromCode maps known codes and falls back to none', () {
      for (final type in TrackEffectType.values) {
        expect(TrackEffectType.fromCode(type.code), type);
      }
      expect(TrackEffectType.fromCode(999), TrackEffectType.none);
    });

    test('params never exceed the param cap', () {
      for (final type in TrackEffectType.values) {
        expect(type.params.length, lessThanOrEqualTo(kTrackEffectParams));
        expect(type.defaultParams.length, kTrackEffectParams);
      }
    });

    test('codes match the native le_fx_type contract', () {
      // These integers are the wire contract with the engine and persisted
      // chains; they must never drift.
      expect(TrackEffectType.octaver.code, 5);
      expect(TrackEffectType.echo.code, 6);
      expect(TrackEffectType.reverb.code, 7);
    });

    test('reverb exposes size, damping and mix', () {
      expect(TrackEffectType.reverb.params.map((p) => p.key), [
        'size',
        'damping',
        'mix',
      ]);
      // The cells past its three parameters are inert and stay 0.
      expect(
        TrackEffectType.reverb.defaultParams,
        cells(const [0.5, 0.5, 0.35]),
      );
    });

    test('codes are unique', () {
      final codes = TrackEffectType.values.map((t) => t.code).toList();
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('keys are unique within a type', () {
      for (final type in TrackEffectType.values) {
        final keys = type.params.map((p) => p.key).toList();
        expect(keys.toSet(), hasLength(keys.length), reason: type.name);
      }
    });

    test('defaultParams are the descriptor defaults, padded with 0', () {
      // The settings a freshly engaged effect starts at. Saved chains and the
      // wet-cache fingerprint depend on these, so they are pinned here.
      const expected = {
        TrackEffectType.none: [0.0, 0.0, 0.0, 0.0],
        TrackEffectType.drive: [0.5, 0.8, 0.0, 0.0],
        TrackEffectType.filter: [0.5, 0.2, 0.0, 0.0],
        TrackEffectType.delay: [0.35, 0.35, 0.35, 0.0],
        TrackEffectType.tremolo: [0.3, 0.7, 0.0, 0.0],
        TrackEffectType.octaver: [0.25, 0.5, 0.5, 0.0],
        TrackEffectType.echo: [0.45, 0.5, 0.35, 0.0],
        TrackEffectType.reverb: [0.5, 0.5, 0.35, 0.0],
        // Ed's 4-band EQ as it applies (#891): the mids at 101.5 and 3040 Hz
        // on the kind's 20..20000 Hz range, four bells and both cuts.
        TrackEffectType.eq: [
          0.21, 0.5, 0.384476, 0.0, 0.5, 0.235138, 0.174, 0.5, 0.727302, //
          0.15557, 0.5, 0.5278, 0.0, 1.0, 0.5,
        ],
        // Ed's compressor (its 1.8 dB make-up applies 3.25 dB); the transient
        // shaper neutral; the Vocal Rack's HP/Gate (high-pass off, -120 dB).
        TrackEffectType.compressor: [0.35, 0.76, 0.5, 0.5, 0.10833334],
        TrackEffectType.transient: [0.5, 0.5, 0.5],
        TrackEffectType.hpGate: [0.0, 0.0],
        // The Dub Rack's doubler, Ed's chorus and wah.
        TrackEffectType.doubler: [1.0, 1.0],
        TrackEffectType.chorus: [0.45, 0.21, 0.5],
        TrackEffectType.wah: [0.619],
        // Ed's overdrive; the Lo-Fi Rack's distortion.
        TrackEffectType.overdrive: [0.09, 0.5],
        TrackEffectType.distortion: [0.2, 0.5],
        // The Lo-Fi Rack's vinyl, degrade and low-pass filter.
        TrackEffectType.vinyl: [0.4, 0.35, 0.3, 0.9],
        TrackEffectType.degrade: [1.0, 1.0, 1.0],
        TrackEffectType.lpf: [1.0, 1.0],
        // The Guitar Rack's spring: 2.00 s, 50 %.
        TrackEffectType.spring: [0.30103, 0.5],
      };
      for (final type in TrackEffectType.values) {
        expect(type.defaultParams, cells(expected[type]!), reason: type.name);
        for (var i = 0; i < type.params.length; i++) {
          expect(type.defaultParams[i], type.params[i].defaultValue);
        }
      }
    });

    test('the octaver shift snaps to whole semitones across +-2 octaves', () {
      final shift = TrackEffectType.octaver.params.first;
      expect(shift.key, 'shift');
      expect(shift.unit, FxParamUnit.semitones);
      expect(shift.steps, 49);
      expect((shift.atMin, shift.atMax), (-24.0, 24.0));
    });

    test('the octaver mode is a two-position choice', () {
      final mode = TrackEffectType.octaver.params[3];
      expect(mode.key, 'mode');
      expect(mode.unit, FxParamUnit.choice);
      expect(mode.steps, 2);
    });

    test('the octaver formants are a two-position choice, held by default', () {
      final formants = TrackEffectType.octaver.params.last;
      expect(formants.key, 'formants');
      expect(formants.unit, FxParamUnit.choice);
      expect(formants.steps, 2);
      expect(formants.defaultValue, 0);
    });

    test('only the chosen mappings carry the taper-unverified flag', () {
      // The seven built-ins are segno's own; the Looper X kinds' ranges are
      // the Looper X's, and the EQ and dynamics kinds are measured (#891).
      // The controls whose effect is chosen or inferred from one capture
      // carry it: the doubler, the chorus, the wah, the overdrive's tone
      // (captured at 50 % only) and the distortion (fit to the Studio
      // Rack's, used for Lo-Fi's too), the vinyl, the degrade and the
      // low-pass filter's resonance (no capture).
      for (final type in TrackEffectType.values) {
        for (final p in type.params) {
          expect(
            p.taperUnverified,
            type == TrackEffectType.doubler ||
                type == TrackEffectType.chorus ||
                type == TrackEffectType.wah ||
                type == TrackEffectType.distortion ||
                type == TrackEffectType.vinyl ||
                type == TrackEffectType.degrade ||
                (type == TrackEffectType.lpf && p.key == 'resonance') ||
                (type == TrackEffectType.overdrive && p.key == 'tone'),
            reason: '${type.name}.${p.key}',
          );
        }
      }
    });

    test("the compressor's ratio is the Looper X's reciprocal taper", () {
      // 1 / (1 - v / 1.0101): 1 at 0, 100 at 1, and every Ed's preset's
      // 0.758 is 4:1.
      final ratio = TrackEffectType.compressor.params[1];
      expect(ratio.unit, FxParamUnit.ratio);
      for (var v = 0.0; v <= 1.0; v += 0.1) {
        // The two agree to 1e-4 of the value (100 against 100.01 at 1).
        final want = 1 / (1 - v / 1.0101);
        expect(ratio.valueAt(v), closeTo(want, want * 1e-4));
        expect(ratio.settingFor(ratio.valueAt(v)), closeTo(v, 1e-9));
      }
      expect(ratio.valueAt(0.758), closeTo(4.0, 0.01));
    });
  });

  group('FxParamUnit and FxParamCurve', () {
    test('codes match the native enums', () {
      expect(
        [for (final u in FxParamUnit.values) u.code],
        [
          0,
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
        ],
      );
      expect(FxParamUnit.choice.code, 5);
      expect(FxParamCurve.linear.code, 0);
      expect(FxParamCurve.exponential.code, 1);
      expect(FxParamCurve.reciprocal.code, 2);
    });
  });

  group('FxParamInfo', () {
    const linear = FxParamInfo(
      key: 'time',
      unit: FxParamUnit.ms,
      atMin: 0,
      atMax: 1000,
      defaultValue: 0.35,
    );
    const exponential = FxParamInfo(
      key: 'cutoff',
      unit: FxParamUnit.hz,
      atMin: 20,
      atMax: 18000,
      curve: FxParamCurve.exponential,
      defaultValue: 0.5,
    );
    const stepped = FxParamInfo(
      key: 'shift',
      unit: FxParamUnit.semitones,
      steps: 49,
      atMin: -24,
      atMax: 24,
      defaultValue: 0.25,
    );
    const choice = FxParamInfo(
      key: 'mode',
      unit: FxParamUnit.choice,
      steps: 2,
      atMin: 0,
      atMax: 1,
      defaultValue: 0,
    );

    test('valueAt maps a linear parameter', () {
      expect(linear.valueAt(0), 0);
      expect(linear.valueAt(0.35), closeTo(350, 1e-9));
      expect(linear.valueAt(1), 1000);
    });

    test('valueAt maps an exponential parameter', () {
      expect(exponential.valueAt(0), closeTo(20, 1e-9));
      // 20 * 900^0.5 = 600.
      expect(exponential.valueAt(0.5), closeTo(600, 1e-9));
      expect(exponential.valueAt(1), closeTo(18000, 1e-6));
    });

    test('valueAt reads a stepped parameter as set, a choice at its '
        'nearest position', () {
      expect(stepped.valueAt(0.25), closeTo(-12, 1e-9));
      expect(stepped.valueAt(0.5), closeTo(0, 1e-9));
      // The kernel plays a setting between positions as set: 0.26 is
      // (0.26 - 0.5) x 48 = -11.52 semitones.
      expect(stepped.valueAt(0.26), closeTo(-11.52, 1e-9));
      expect(choice.valueAt(0.49), 0);
      expect(choice.valueAt(0.5), 1);
    });

    test('valueAt clamps the setting and reads NaN as 0', () {
      expect(linear.valueAt(-1), 0);
      expect(linear.valueAt(2), 1000);
      expect(linear.valueAt(double.nan), 0);
      expect(stepped.valueAt(1.5), closeTo(24, 1e-9));
    });

    test('positionOf returns the snapped position of a stepped parameter', () {
      expect(stepped.positionOf(0), 0);
      expect(stepped.positionOf(0.5), 24);
      expect(stepped.positionOf(1), 48);
      expect(stepped.positionOf(-0.5), 0);
      expect(choice.positionOf(0.49), 0);
      // The octaver kernel reads mode >= 0.5 as PSOLA, position 1.
      expect(choice.positionOf(0.5), 1);
    });

    test('positionOf throws for a continuous parameter', () {
      expect(linear.isStepped, isFalse);
      expect(() => linear.positionOf(0.5), throwsStateError);
    });

    test('value equality covers every field', () {
      const same = FxParamInfo(
        key: 'time',
        unit: FxParamUnit.ms,
        atMin: 0,
        atMax: 1000,
        defaultValue: 0.35,
      );
      expect(linear, same);
      expect(linear.hashCode, same.hashCode);
      const flagged = FxParamInfo(
        key: 'time',
        unit: FxParamUnit.ms,
        atMin: 0,
        atMax: 1000,
        defaultValue: 0.35,
        taperUnverified: true,
      );
      expect(linear, isNot(flagged));
      expect(linear, isNot(exponential));
    });
  });

  group('encode/decode chain', () {
    test('round-trips a built-in chain', () {
      // Params are at the current width, so decode (which normalizes) round-
      // trips them exactly.
      final chain = [
        BuiltInEffect(type: TrackEffectType.drive),
        BuiltInEffect(
          type: TrackEffectType.delay,
          params: const [0.5, 0.4, 0.3, 0],
        ),
      ];
      final decoded = decodeTrackEffects(encodeTrackEffects(chain));
      expect(decoded, chain);
    });

    test('round-trips a mixed built-in + plugin chain (dual-decode)', () {
      final chain = <TrackEffect>[
        BuiltInEffect(type: TrackEffectType.drive),
        const PluginEffect(
          ref: PluginRef(
            format: PluginFormat.clap,
            id: 'com.acme.reverb',
            version: 0x00000300,
          ),
        ),
        BuiltInEffect(type: TrackEffectType.reverb),
      ];
      final decoded = decodeTrackEffects(encodeTrackEffects(chain));
      expect(decoded, chain);
      expect(decoded[1], isA<PluginEffect>());
    });

    test('a plugin entry is never silently dropped to none', () {
      // The exact bug the fromCode fix guards: code 8 + a plugin key must
      // decode to a PluginEffect, not fall through to a built-in `none`.
      final encoded = jsonEncode([
        {
          'type': kPluginFxCode,
          'plugin': {'format': 1, 'id': 'keep.me', 'version': 0},
        },
      ]);
      final decoded = decodeTrackEffects(encoded);
      expect(decoded, hasLength(1));
      expect(decoded.first, isA<PluginEffect>());
      expect((decoded.first as PluginEffect).ref.id, 'keep.me');
    });

    test(
      'the exact pre-plugin bare-array string still decodes',
      () {
        // Back-compat: a v1 chain is a bare array of {type, params} with no
        // envelope and no plugin entries; it must decode unchanged.
        const v1 =
            '[{"type":1,"params":[0.5,0.8,0.0,0.0]},'
            '{"type":3,"params":[0.35,0.35,0.35,0.0]}]';
        final decoded = decodeTrackEffects(v1);
        expect(decoded, [
          BuiltInEffect(type: TrackEffectType.drive),
          BuiltInEffect(type: TrackEffectType.delay),
        ]);
        for (final e in decoded) {
          expect(e, isA<BuiltInEffect>());
        }
        // Re-encoding yields a bare array — no envelope, no plugin keys —
        // carrying only the cells each type reads, which decodes back to the
        // same entries.
        expect(
          encodeTrackEffects(decoded),
          '[{"type":1,"params":[0.5,0.8]},'
          '{"type":3,"params":[0.35,0.35,0.35]}]',
        );
        expect(decodeTrackEffects(encodeTrackEffects(decoded)), decoded);
      },
    );

    test('decodes a legacy chain that still carries stage keys', () {
      final legacy = jsonEncode([
        {
          'type': TrackEffectType.filter.code,
          'stage': 1,
          'params': [0.2, 0.3, 0],
        },
      ]);
      final decoded = decodeTrackEffects(legacy);
      expect(decoded, hasLength(1));
      final first = decoded.first as BuiltInEffect;
      expect(first.type, TrackEffectType.filter);
      // The legacy params are brought to the current width.
      expect(first.params, cells(const [0.2, 0.3]));
    });

    test('empty or malformed input yields an empty chain', () {
      expect(decodeTrackEffects(null), isEmpty);
      expect(decodeTrackEffects(''), isEmpty);
      expect(decodeTrackEffects('not json'), isEmpty);
      expect(decodeTrackEffects('{"type":1}'), isEmpty);
    });
  });

  group('enabled + slotId (FX v3, R16/A9)', () {
    test('both fields round-trip through the codec on both subtypes', () {
      final chain = [
        BuiltInEffect(
          type: TrackEffectType.delay,
          enabled: false,
          slotId: 'b-1',
        ),
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.clap, id: 'p'),
          enabled: false,
          slotId: 'p-1',
        ),
      ];

      final decoded = decodeTrackEffects(encodeTrackEffects(chain));

      expect(decoded, hasLength(2));
      final builtIn = decoded[0] as BuiltInEffect;
      expect(builtIn.enabled, isFalse);
      expect(builtIn.slotId, 'b-1');
      final plugin = decoded[1] as PluginEffect;
      expect(plugin.enabled, isFalse);
      expect(plugin.slotId, 'p-1');
    });

    test('wrong-TYPED enabled/slotId decode to defaults, never throw', () {
      final decoded = decodeTrackEffects(
        '[{"type":1,"params":[0.5,0.8,0,0],"enabled":"yes","slotId":7},'
        '{"type":8,"plugin":{"format":1,"id":"p","version":0},'
        '"enabled":1,"slotId":{}}]',
      );
      expect(decoded, hasLength(2));
      expect((decoded[0] as BuiltInEffect).enabled, isTrue);
      expect((decoded[0] as BuiltInEffect).slotId, isNull);
      expect((decoded[1] as PluginEffect).enabled, isTrue);
      expect((decoded[1] as PluginEffect).slotId, isNull);
    });

    test('missing keys decode enabled=true / slotId=null (legacy)', () {
      final decoded = decodeTrackEffects(
        '[{"type":1,"params":[0.5,0.8,0,0]},'
        '{"type":8,"plugin":{"format":1,"id":"p","version":0}}]',
      );
      expect((decoded[0] as BuiltInEffect).enabled, isTrue);
      expect((decoded[0] as BuiltInEffect).slotId, isNull);
      expect((decoded[1] as PluginEffect).enabled, isTrue);
      expect((decoded[1] as PluginEffect).slotId, isNull);
    });

    test('default values are omitted so a pre-FX-v3 chain encodes '
        'byte-unchanged', () {
      final encoded = encodeTrackEffects([
        BuiltInEffect(type: TrackEffectType.drive),
      ]);
      expect(encoded, isNot(contains('enabled')));
      expect(encoded, isNot(contains('slotId')));
    });

    test('equality and copyWith cover both fields on both subtypes', () {
      final a = BuiltInEffect(type: TrackEffectType.drive, slotId: 'x');
      expect(a, isNot(BuiltInEffect(type: TrackEffectType.drive)));
      expect(a.copyWith(enabled: false).enabled, isFalse);
      expect(a.copyWith(enabled: false).slotId, 'x');

      const ref = PluginRef(format: PluginFormat.vst3, id: 't');
      const p = PluginEffect(ref: ref, enabled: false);
      expect(p, isNot(const PluginEffect(ref: ref)));
      expect(p.copyWith(slotId: 'y').slotId, 'y');
      expect(p.copyWith(slotId: 'y').enabled, isFalse);
    });
  });

  group('FxPlacement', () {
    test('an entry defaults to post and omits the key from the wire', () {
      final builtIn = BuiltInEffect(type: TrackEffectType.drive);
      const plugin = PluginEffect(
        ref: PluginRef(format: PluginFormat.vst3, id: 'a', version: 1),
      );
      expect(builtIn.placement, FxPlacement.post);
      expect(plugin.placement, FxPlacement.post);
      expect(builtIn.toJson().containsKey('placement'), isFalse);
      expect(plugin.toJson().containsKey('placement'), isFalse);
    });

    test('a pre entry carries the key and round-trips, in both arms', () {
      final builtIn = BuiltInEffect(
        type: TrackEffectType.reverb,
        placement: FxPlacement.pre,
      );
      const plugin = PluginEffect(
        ref: PluginRef(format: PluginFormat.clap, id: 'b', version: 2),
        placement: FxPlacement.pre,
      );
      expect(builtIn.toJson()['placement'], 'pre');
      expect(plugin.toJson()['placement'], 'pre');
      final decoded = decodeTrackEffects(
        encodeTrackEffects([builtIn, plugin]),
      );
      expect(decoded.map((e) => e.placement), [
        FxPlacement.pre,
        FxPlacement.pre,
      ]);
    });

    test('invalid explicit placement rejects both entry types', () {
      for (final invalid in ['sideways', 7, null]) {
        expect(
          () => BuiltInEffect.fromJson({'type': 1, 'placement': invalid}),
          throwsFormatException,
        );
        expect(
          () => PluginEffect.fromJson({
            'type': 8,
            'plugin': const {'format': 1, 'id': 'p', 'version': 0},
            'placement': invalid,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => decodeTrackEffects('[{"type":1,"placement":"sideways"}]'),
        throwsFormatException,
      );
    });

    test('placement separates two otherwise identical entries', () {
      final pre = BuiltInEffect(
        type: TrackEffectType.echo,
        placement: FxPlacement.pre,
      );
      final post = BuiltInEffect(type: TrackEffectType.echo);
      expect(pre, isNot(post));
      expect(pre.copyWith(placement: FxPlacement.post), post);
    });

    test('fxPreCount counts the leading pre run only', () {
      BuiltInEffect at(FxPlacement placement) =>
          BuiltInEffect(type: TrackEffectType.drive, placement: placement);
      expect(fxPreCount(const []), 0);
      expect(fxPreCount([at(FxPlacement.post), at(FxPlacement.post)]), 0);
      expect(fxPreCount([at(FxPlacement.pre), at(FxPlacement.post)]), 1);
      expect(fxPreCount([at(FxPlacement.pre), at(FxPlacement.pre)]), 2);
      // An unpartitioned chain counts what the engine would see, not the
      // total number of pre entries.
      expect(
        fxPreCount([
          at(FxPlacement.pre),
          at(FxPlacement.post),
          at(FxPlacement.pre),
        ]),
        1,
      );
    });
  });

  group('FxChannels', () {
    test(
      'an entry defaults to stereo/stereo/centre/unity and omits the key',
      () {
        final fx = BuiltInEffect(type: TrackEffectType.drive);
        expect(fx.channels, FxChannels.defaults);
        expect(fx.channels.isDefault, isTrue);
        expect(fx.toJson().containsKey('channels'), isFalse);
      },
    );

    test('round-trips through the wire in both arms', () {
      const channels = FxChannels(
        input: FxChannelInput.monoSum,
        output: FxChannelOutput.mono,
        placement: -0.5,
        level: 0.25,
      );
      final chain = <TrackEffect>[
        BuiltInEffect(type: TrackEffectType.reverb, channels: channels),
        const PluginEffect(
          ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
          channels: channels,
        ),
      ];
      final decoded = decodeTrackEffects(encodeTrackEffects(chain));
      expect(decoded, chain);
      expect(decoded.map((e) => e.channels), [channels, channels]);
    });

    test('malformed explicit channels reject the whole chain', () {
      for (final invalid in [
        'sideways',
        null,
        {'input': 'nope'},
        {'output': 'nope'},
        {'placement': 1.1},
        {'placement': 'left'},
        {'level': -0.1},
        {'level': 4.1},
        {'level': 'loud'},
      ]) {
        expect(
          () => BuiltInEffect.fromJson({'type': 1, 'channels': invalid}),
          throwsFormatException,
        );
      }
      expect(
        () => decodeTrackEffects('[{"type":1,"channels":{"level":5}}]'),
        throwsFormatException,
      );
      // A rack level up to +12 dB is a valid saved level.
      expect(
        BuiltInEffect.fromJson(const {
          'type': 1,
          'channels': {'level': 3.98},
        }).channels.level,
        3.98,
      );
      expect(FxChannels.fromJson(const {}), FxChannels.defaults);
    });

    test('channel handling separates two otherwise identical entries', () {
      final a = BuiltInEffect(type: TrackEffectType.echo);
      final b = BuiltInEffect(
        type: TrackEffectType.echo,
        channels: const FxChannels(level: 0.5),
      );
      expect(a, isNot(b));
      expect(b.copyWith(channels: FxChannels.defaults), a);
    });
  });
}
