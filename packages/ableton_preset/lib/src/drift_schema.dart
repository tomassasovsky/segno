// cspell:words Modwheel

import 'package:ableton_preset/src/device_schema.dart';

/// Drift's oscillator 1 types, in stored order (the UI's; the DSP orders
/// them differently, so engines map by name).
const driftOscillator1Types = [
  'Sine',
  'Triangle',
  'Shark Tooth',
  'Saturated',
  'Saw',
  'Pulse',
  'Rectangle',
];

/// Drift's oscillator 2 types, in stored order.
const driftOscillator2Types = [
  'Sine',
  'Triangle',
  'Saturated',
  'Saw',
  'Rectangle',
];

/// Drift's modulation sources 0..7, shared by the filter, LFO, shape and
/// pitch modulation inputs and the matrix.
const driftModSources = [
  'Env 1',
  'Env 2 / Cyc',
  'LFO',
  'Key',
  'Velocity',
  'Modwheel',
  'Pressure',
  'Slide',
];

/// Drift's modulation matrix targets 0..11.
const driftMatrixTargets = [
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
];

/// Drift's voice modes 0..3.
const driftVoiceModes = ['Poly', 'Mono', 'Stereo', 'Unison'];

/// Drift's low-pass filter types 0..1.
const driftFilterTypes = ['I', 'II'];

/// +6 dB as linear gain, 10^(6/20): the mixer levels' maximum.
const _plus6dB = 1.9952623149688795;

/// Every parameter Drift stores, typed (SEG-109's brainstorm, "Drift's
/// parameters"). Names whose meaning is still an open item there (the LFO
/// and cycling envelope modes, the LFO shapes, the voice count table) are
/// stepped integers until Segno's Drift settles them.
final class DriftSchema extends DeviceSchema {
  /// Drift's schema.
  new() : super(device: 'Drift', parameters: _parameters);

  static final List<ParameterSpec> _parameters = [
    const SwitchSpec('On'),
    // Oscillator 1.
    const ChoiceSpec('Oscillator1_Type', driftOscillator1Types),
    const NumberSpec('Oscillator1_Shape', 0, 1),
    const NumberSpec('Oscillator1_ShapeMod', -1, 1),
    const ChoiceSpec('Oscillator1_ShapeModSource', driftModSources),
    const IntegerSpec('Oscillator1_Transpose', -2, 3),
    // Oscillator 2.
    const ChoiceSpec('Oscillator2_Type', driftOscillator2Types),
    const NumberSpec('Oscillator2_Detune', -7, 7),
    const IntegerSpec('Oscillator2_Transpose', -3, 2),
    // Mixer: linear gains up to +6 dB.
    const NumberSpec('Mixer_OscillatorGain1', 0, _plus6dB),
    const SwitchSpec('Mixer_OscillatorOn1'),
    const NumberSpec('Mixer_OscillatorGain2', 0, _plus6dB),
    const SwitchSpec('Mixer_OscillatorOn2'),
    const NumberSpec('Mixer_NoiseLevel', 0, _plus6dB),
    const SwitchSpec('Mixer_NoiseOn'),
    // Filter.
    const ChoiceSpec('Filter_Type', driftFilterTypes),
    const NumberSpec('Filter_Frequency', 20, 20000),
    const NumberSpec('Filter_Resonance', 0, 1.01),
    const NumberSpec('Filter_HiPassFrequency', 10, 20480),
    const NumberSpec('Filter_Tracking', 0, 1),
    const ChoiceSpec('Filter_ModSource1', driftModSources),
    const NumberSpec('Filter_ModAmount1', -1, 1),
    const ChoiceSpec('Filter_ModSource2', driftModSources),
    const NumberSpec('Filter_ModAmount2', -1, 1),
    const SwitchSpec('Filter_OscillatorThrough1'),
    const SwitchSpec('Filter_OscillatorThrough2'),
    const SwitchSpec('Filter_NoiseThrough'),
    // Envelopes: seconds, sustain 0..1.
    for (final envelope in ['Envelope1', 'Envelope2']) ...[
      NumberSpec('${envelope}_Attack', 0, 60),
      NumberSpec('${envelope}_Decay', 0.005, 60),
      NumberSpec('${envelope}_Sustain', 0, 1),
      NumberSpec('${envelope}_Release', 0.01, 60),
    ],
    // Cycling envelope.
    const IntegerSpec('CyclingEnvelope_Mode', 0, 3),
    const NumberSpec('CyclingEnvelope_Rate', 0.17, 1700),
    const NumberSpec('CyclingEnvelope_Ratio', 0.25, 16),
    const NumberSpec('CyclingEnvelope_Time', 0.1, 60),
    const IntegerSpec('CyclingEnvelope_SyncedRate', 0, 21),
    const NumberSpec('CyclingEnvelope_MidPoint', 0, 1),
    const NumberSpec('CyclingEnvelope_Hold', 0, 1),
    // LFO.
    const IntegerSpec('Lfo_Mode', 0, 3),
    const IntegerSpec('Lfo_Shape', 0, 8),
    const NumberSpec('Lfo_Rate', 0.17, 1700),
    const NumberSpec('Lfo_Ratio', 0.25, 16),
    const NumberSpec('Lfo_Time', 0.1, 60),
    const IntegerSpec('Lfo_SyncedRate', 0, 21),
    const NumberSpec('Lfo_Amount', 0, 1),
    const ChoiceSpec('Lfo_ModSource', driftModSources),
    const NumberSpec('Lfo_ModAmount', -1, 1),
    const SwitchSpec('Lfo_Retrigger'),
    // Pitch modulation: two fixed slots.
    for (final slot in [1, 2]) ...[
      ChoiceSpec('PitchModulation_Source$slot', driftModSources),
      NumberSpec('PitchModulation_Amount$slot', -1, 1),
    ],
    // Modulation matrix: three slots.
    for (final slot in [1, 2, 3]) ...[
      ChoiceSpec('ModulationMatrix_Source$slot', driftModSources),
      ChoiceSpec('ModulationMatrix_Target$slot', driftMatrixTargets),
      NumberSpec('ModulationMatrix_Amount$slot', -1, 1),
    ],
    // Global.
    const ChoiceSpec('Global_VoiceMode', driftVoiceModes),
    const IntegerSpec('Global_VoiceCount', 0, 4),
    const NumberSpec('Global_PolyVoiceDepth', 0, 1),
    const NumberSpec('Global_MonoVoiceDepth', 0, 1),
    const NumberSpec('Global_StereoVoiceDepth', 0, 1),
    const NumberSpec('Global_UnisonVoiceDepth', 0, 1),
    const NumberSpec('Global_DriftDepth', 0, 1),
    const NumberSpec('Global_Glide', 0, 2),
    const SwitchSpec('Global_Legato'),
    // Stored without a range; presets use up to 12 semitones.
    const IntegerSpec('Global_PitchBendRange', 0, 48),
    const SwitchSpec('Global_NotePitchBend'),
    const NumberSpec('Global_VolVelMod', 0, 1),
    const NumberSpec('Global_Volume', 0, 1),
    const IntegerSpec('Global_Transpose', -48, 48),
    const IntegerSpec('Global_Envelope2Mode', 0, 1),
    const SwitchSpec('Global_ResetOscillatorPhase'),
    const SwitchSpec('Global_HiQuality'),
    // A random number per instance, saved with the preset.
    const IntegerSpec('Global_SerialNumber', -0x80000000, 0x7fffffff),
  ];
}
