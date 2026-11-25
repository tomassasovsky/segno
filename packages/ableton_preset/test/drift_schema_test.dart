// cspell:words Modwheel

import 'package:ableton_preset/ableton_preset.dart';
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

AbletonPreset _drift(Iterable<String> parameters) => AbletonPresetReader.decode(
  gzipped(devicePreset('Drift', parameters)),
  name: 'Test',
);

/// Drift's full fixture with each parameter named in [overrides] replaced.
List<String> _with(Map<String, String> overrides) => [
  for (final parameter in driftParameters())
    overrides[RegExp(r'^<(\w+)').firstMatch(parameter)![1]] ?? parameter,
];

void main() {
  final schema = DriftSchema();

  group('DriftSchema', () {
    final values = schema.read(_drift(driftParameters()));

    test('types every Drift parameter, with nothing left over', () {
      expect(schema.device, 'Drift');
      expect(schema.parameters, hasLength(83));
      expect(values.values.keys, [
        for (final spec in schema.parameters) spec.name,
      ]);
      expect(values.unmapped, isEmpty);
      expect(values.missing, isEmpty);
    });

    test('reads the device switch', () {
      expect(values.values['On'], const SwitchValue(true));
    });

    test('reads oscillator 1', () {
      expect(
        values.values['Oscillator1_Type'],
        const ChoiceValue(2, 'Shark Tooth'),
      );
      expect(values.values['Oscillator1_Shape'], const NumberValue(0.25));
      expect(values.values['Oscillator1_ShapeMod'], const NumberValue(-0.5));
      expect(
        values.values['Oscillator1_ShapeModSource'],
        const ChoiceValue(2, 'LFO'),
      );
      expect(values.values['Oscillator1_Transpose'], const IntegerValue(-1));
    });

    test('reads oscillator 2', () {
      expect(values.values['Oscillator2_Type'], const ChoiceValue(3, 'Saw'));
      expect(values.values['Oscillator2_Detune'], const NumberValue(0.125));
      expect(values.values['Oscillator2_Transpose'], const IntegerValue(1));
    });

    test('reads the mixer', () {
      expect(values.values['Mixer_OscillatorGain1'], const NumberValue(1.5));
      expect(values.values['Mixer_OscillatorOn1'], const SwitchValue(true));
      expect(values.values['Mixer_OscillatorGain2'], const NumberValue(0.5));
      expect(values.values['Mixer_OscillatorOn2'], const SwitchValue(false));
      expect(values.values['Mixer_NoiseLevel'], const NumberValue(0.0625));
      expect(values.values['Mixer_NoiseOn'], const SwitchValue(true));
    });

    test('reads the filters', () {
      expect(values.values['Filter_Type'], const ChoiceValue(1, 'II'));
      expect(values.values['Filter_Frequency'], const NumberValue(440));
      expect(values.values['Filter_Resonance'], const NumberValue(0.75));
      expect(values.values['Filter_HiPassFrequency'], const NumberValue(30));
      expect(values.values['Filter_Tracking'], const NumberValue(0.5));
      expect(values.values['Filter_ModSource1'], const ChoiceValue(0, 'Env 1'));
      expect(values.values['Filter_ModAmount1'], const NumberValue(0.375));
      expect(values.values['Filter_ModSource2'], const ChoiceValue(7, 'Slide'));
      expect(values.values['Filter_ModAmount2'], const NumberValue(-0.25));
      expect(
        values.values['Filter_OscillatorThrough1'],
        const SwitchValue(true),
      );
      expect(
        values.values['Filter_OscillatorThrough2'],
        const SwitchValue(false),
      );
      expect(values.values['Filter_NoiseThrough'], const SwitchValue(true));
    });

    test('reads both envelopes', () {
      expect(values.values['Envelope1_Attack'], const NumberValue(0.01));
      expect(values.values['Envelope1_Decay'], const NumberValue(0.4));
      expect(values.values['Envelope1_Sustain'], const NumberValue(0.6));
      expect(values.values['Envelope1_Release'], const NumberValue(1.25));
      expect(values.values['Envelope2_Attack'], const NumberValue(0.2));
      expect(values.values['Envelope2_Decay'], const NumberValue(3));
      expect(values.values['Envelope2_Sustain'], const NumberValue(0));
      expect(values.values['Envelope2_Release'], const NumberValue(0.5));
    });

    test('reads the cycling envelope', () {
      expect(values.values['CyclingEnvelope_Mode'], const IntegerValue(1));
      expect(values.values['CyclingEnvelope_Rate'], const NumberValue(4));
      expect(values.values['CyclingEnvelope_Ratio'], const NumberValue(0.5));
      expect(values.values['CyclingEnvelope_Time'], const NumberValue(0.75));
      expect(
        values.values['CyclingEnvelope_SyncedRate'],
        const IntegerValue(8),
      );
      expect(values.values['CyclingEnvelope_MidPoint'], const NumberValue(0.3));
      expect(values.values['CyclingEnvelope_Hold'], const NumberValue(0.1));
    });

    test('reads the LFO', () {
      expect(values.values['Lfo_Mode'], const IntegerValue(3));
      expect(values.values['Lfo_Shape'], const IntegerValue(6));
      expect(values.values['Lfo_Rate'], const NumberValue(2.5));
      expect(values.values['Lfo_Ratio'], const NumberValue(2));
      expect(values.values['Lfo_Time'], const NumberValue(1.5));
      expect(values.values['Lfo_SyncedRate'], const IntegerValue(12));
      expect(values.values['Lfo_Amount'], const NumberValue(0.8));
      expect(values.values['Lfo_ModSource'], const ChoiceValue(5, 'Modwheel'));
      expect(values.values['Lfo_ModAmount'], const NumberValue(-0.125));
      expect(values.values['Lfo_Retrigger'], const SwitchValue(true));
    });

    test('reads the pitch modulation slots', () {
      expect(
        values.values['PitchModulation_Source1'],
        const ChoiceValue(1, 'Env 2 / Cyc'),
      );
      expect(values.values['PitchModulation_Amount1'], const NumberValue(0.05));
      expect(
        values.values['PitchModulation_Source2'],
        const ChoiceValue(3, 'Key'),
      );
      expect(values.values['PitchModulation_Amount2'], const NumberValue(-0.1));
    });

    test('reads the modulation matrix', () {
      expect(
        values.values['ModulationMatrix_Source1'],
        const ChoiceValue(4, 'Velocity'),
      );
      expect(
        values.values['ModulationMatrix_Target1'],
        const ChoiceValue(6, 'LP Frequency'),
      );
      expect(values.values['ModulationMatrix_Amount1'], const NumberValue(0.9));
      expect(
        values.values['ModulationMatrix_Source2'],
        const ChoiceValue(6, 'Pressure'),
      );
      expect(
        values.values['ModulationMatrix_Target2'],
        const ChoiceValue(11, 'Main Volume'),
      );
      expect(
        values.values['ModulationMatrix_Amount2'],
        const NumberValue(-0.9),
      );
      expect(
        values.values['ModulationMatrix_Target3'],
        const ChoiceValue(0, 'None'),
      );
    });

    test('reads the global section', () {
      expect(values.values['Global_VoiceMode'], const ChoiceValue(3, 'Unison'));
      expect(values.values['Global_VoiceCount'], const IntegerValue(2));
      expect(values.values['Global_PolyVoiceDepth'], const NumberValue(0.1));
      expect(values.values['Global_StereoVoiceDepth'], const NumberValue(0.2));
      expect(values.values['Global_UnisonVoiceDepth'], const NumberValue(0.3));
      expect(values.values['Global_MonoVoiceDepth'], const NumberValue(0.4));
      expect(values.values['Global_DriftDepth'], const NumberValue(0.05));
      expect(values.values['Global_Glide'], const NumberValue(0.08));
      expect(values.values['Global_Legato'], const SwitchValue(true));
      expect(values.values['Global_PitchBendRange'], const IntegerValue(2));
      expect(values.values['Global_NotePitchBend'], const SwitchValue(false));
      expect(values.values['Global_VolVelMod'], const NumberValue(0.4));
      expect(values.values['Global_Volume'], const NumberValue(0.7));
      expect(values.values['Global_Transpose'], const IntegerValue(-12));
      expect(values.values['Global_Envelope2Mode'], const IntegerValue(1));
      expect(
        values.values['Global_ResetOscillatorPhase'],
        const SwitchValue(false),
      );
      expect(values.values['Global_HiQuality'], const SwitchValue(true));
      expect(
        values.values['Global_SerialNumber'],
        const IntegerValue(-2147483648),
      );
    });

    test('names every enum index in stored order', () {
      String nameOf(String parameter, int index) {
        final preset = _drift(_with({parameter: leaf(parameter, index)}));
        return (schema.read(preset).values[parameter]! as ChoiceValue).name;
      }

      expect([
        for (var i = 0; i < 7; i++) nameOf('Oscillator1_Type', i),
      ], driftOscillator1Types);
      expect(driftOscillator1Types, [
        'Sine',
        'Triangle',
        'Shark Tooth',
        'Saturated',
        'Saw',
        'Pulse',
        'Rectangle',
      ]);
      expect(
        [for (var i = 0; i < 5; i++) nameOf('Oscillator2_Type', i)],
        ['Sine', 'Triangle', 'Saturated', 'Saw', 'Rectangle'],
      );
      expect(
        [for (var i = 0; i < 8; i++) nameOf('ModulationMatrix_Source3', i)],
        [
          'Env 1',
          'Env 2 / Cyc',
          'LFO',
          'Key',
          'Velocity',
          'Modwheel',
          'Pressure',
          'Slide',
        ],
      );
      expect(
        [for (var i = 0; i < 12; i++) nameOf('ModulationMatrix_Target3', i)],
        [
          'None',
          'Osc 1 Gain',
          'Osc 1 Shape',
          'Osc 2 Gain',
          'Osc 2 Detune',
          'Noise Gain',
          'LP Frequency',
          'LP Resonance',
          'HP Frequency',
          'LFO Rate',
          'Cyc Env Rate',
          'Main Volume',
        ],
      );
      expect(
        [for (var i = 0; i < 4; i++) nameOf('Global_VoiceMode', i)],
        ['Poly', 'Mono', 'Stereo', 'Unison'],
      );
      expect(
        [for (var i = 0; i < 2; i++) nameOf('Filter_Type', i)],
        ['I', 'II'],
      );
    });

    test("clamps a number to the preset's narrower stored range", () {
      final preset = _drift(
        _with({
          'Mixer_OscillatorGain1': manual(
            'Mixer_OscillatorGain1',
            1.5,
            min: 0,
            max: 1,
          ),
        }),
      );
      expect(
        schema.read(preset).values['Mixer_OscillatorGain1'],
        const NumberValue(1),
      );
    });

    test("clamps a number to Drift's range when the stored one is wider", () {
      final preset = _drift(
        _with({
          'Filter_Resonance': manual('Filter_Resonance', 5, min: 0, max: 10),
          'Filter_Frequency': manual('Filter_Frequency', 1, min: 50, max: 40),
          'Global_Glide': manual('Global_Glide', -1),
        }),
      );
      final values = schema.read(preset).values;
      expect(values['Filter_Resonance'], const NumberValue(1.01));
      expect(values['Filter_Frequency'], const NumberValue(20));
      expect(values['Global_Glide'], const NumberValue(0));
    });

    test("keeps a value at Live's computed range ends", () {
      final preset = _drift(
        _with({
          'Filter_Frequency': manual(
            'Filter_Frequency',
            19.9999981,
            min: 19.9999981,
            max: 19999.9961,
          ),
        }),
      );
      expect(
        schema.read(preset).values['Filter_Frequency'],
        const NumberValue(19.9999981),
      );
    });

    test('rounds and clamps a stepped value', () {
      final preset = _drift(
        _with({
          'Oscillator1_Transpose': manual('Oscillator1_Transpose', 7),
          'Global_Transpose': manual('Global_Transpose', '-12.4'),
          'Global_VoiceCount': leaf('Global_VoiceCount', -3),
        }),
      );
      final values = schema.read(preset).values;
      expect(values['Oscillator1_Transpose'], const IntegerValue(3));
      expect(values['Global_Transpose'], const IntegerValue(-12));
      expect(values['Global_VoiceCount'], const IntegerValue(0));
    });

    test('lists values it cannot read as unmapped', () {
      final preset = _drift(
        _with({
          'Oscillator1_Type': manual('Oscillator1_Type', 7),
          'Oscillator2_Type': manual('Oscillator2_Type', 1.5),
          'Filter_ModSource1': leaf('Filter_ModSource1', -1),
          'Filter_ModSource2': leaf('Filter_ModSource2', 'x'),
          'Lfo_Rate': manual('Lfo_Rate', 'fast'),
          'Lfo_Time': manual('Lfo_Time', 'NaN'),
          'Lfo_Mode': manual('Lfo_Mode', 'Infinity'),
          'Lfo_Retrigger': manual('Lfo_Retrigger', 1),
          'Global_VoiceMode': leaf('Global_VoiceMode', 'Infinity'),
        }),
      );
      final values = schema.read(preset);
      expect(values.unmapped, [
        'Oscillator1_Type',
        'Oscillator2_Type',
        'Filter_ModSource1',
        'Filter_ModSource2',
        'Lfo_Mode',
        'Lfo_Rate',
        'Lfo_Time',
        'Lfo_Retrigger',
        'Global_VoiceMode',
      ]);
      expect(values.values, hasLength(83 - 9));
      expect(values.missing, isEmpty);
    });

    test('lists parameters Drift does not have as unmapped', () {
      final preset = _drift([...driftParameters(), leaf('Future_Knob', 1)]);
      expect(schema.read(preset).unmapped, ['Future_Knob']);
    });

    test('lists the parameters a preset does not store as missing', () {
      final preset = _drift(
        driftParameters().where((p) => !p.startsWith('<Lfo_')),
      );
      final values = schema.read(preset);
      expect(values.missing, [
        'Lfo_Mode',
        'Lfo_Shape',
        'Lfo_Rate',
        'Lfo_Ratio',
        'Lfo_Time',
        'Lfo_SyncedRate',
        'Lfo_Amount',
        'Lfo_ModSource',
        'Lfo_ModAmount',
        'Lfo_Retrigger',
      ]);
      expect(values.unmapped, isEmpty);
    });

    test('refuses a preset of another device or a rack', () {
      final operator = AbletonPresetReader.decode(
        gzipped(devicePreset('Operator', const [])),
        name: 'Op',
      );
      final rack = AbletonPresetReader.decode(
        gzipped(rackPreset('Drift')),
        name: 'Rack',
      );
      expect(() => schema.read(operator), throwsArgumentError);
      expect(() => schema.read(rack), throwsArgumentError);
    });
  });

  group('ParameterValue', () {
    test('compares by value and prints it', () {
      expect(const NumberValue(1).hashCode, const NumberValue(1).hashCode);
      expect(const NumberValue(1), isNot(const NumberValue(2)));
      expect(const NumberValue(1).toString(), 'NumberValue(1.0)');
      expect(const IntegerValue(1).hashCode, const IntegerValue(1).hashCode);
      expect(const IntegerValue(1), isNot(const IntegerValue(2)));
      expect(const IntegerValue(1).toString(), 'IntegerValue(1)');
      expect(
        const SwitchValue(true).hashCode,
        const SwitchValue(true).hashCode,
      );
      expect(const SwitchValue(true), isNot(const SwitchValue(false)));
      expect(const SwitchValue(true).toString(), 'SwitchValue(true)');
      expect(
        const ChoiceValue(1, 'Mono').hashCode,
        const ChoiceValue(1, 'Mono').hashCode,
      );
      expect(const ChoiceValue(1, 'Mono'), isNot(const ChoiceValue(1, 'Poly')));
      expect(const ChoiceValue(1, 'Mono').toString(), 'ChoiceValue(1, Mono)');
    });
  });
}
