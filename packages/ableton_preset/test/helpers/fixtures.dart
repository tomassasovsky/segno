// cspell:words Timeable
// Preset fixtures written by the tests themselves: small XML documents in
// the shape of a Live preset, with invented values, gzipped here. No Ableton
// preset or data is copied into them (SEG-109's boundary).
//
// Markup is split across adjacent strings where no whitespace belongs.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:io';

/// A parameter stored with `<Manual>`, and a range when [min] and [max] are
/// given, as Live writes continuous parameters, switches and steps.
String manual(String name, Object value, {num? min, num? max}) {
  final range = min == null || max == null
      ? ''
      : '<MidiControllerRange><Min Value="$min" /><Max Value="$max" />'
            '</MidiControllerRange>';
  return '<$name><LomId Value="0" /><Manual Value="$value" />$range'
      '<AutomationTarget Id="0"><LockEnvelope Value="0" /></AutomationTarget>'
      '</$name>';
}

/// A parameter stored as a bare `Value` attribute, as Live writes the enum
/// selectors.
String leaf(String name, Object value) => '<$name Value="$value" />';

/// The bookkeeping Live writes before a device's parameters.
const bookkeeping =
    '<LomId Value="0" /><LomIdView Value="0" /><IsExpanded Value="true" />'
    '<BreakoutIsExpanded Value="false" />'
    '<ModulationSourceCount Value="0" /><ParametersListWrapper LomId="0" />'
    '<Pointee Id="0" /><LastSelectedTimeableIndex Value="0" />'
    '<LastSelectedClipEnvelopeIndex Value="0" />'
    '<LastPresetRef><Value /></LastPresetRef><LockedScripts />'
    '<IsFolded Value="false" /><ShouldShowPresetName Value="true" />'
    '<UserName Value="Test" /><Annotation Value="" />'
    '<SourceContext><Value /></SourceContext>'
    '<MpePitchBendUsesTuning Value="true" />'
    '<OverwriteProtectionNumber Value="1" />';

/// A whole document holding [body] under the root.
String document(String body, {String major = '5'}) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Ableton MajorVersion="$major" MinorVersion="12.0_00000" '
    'Creator="Segno test">$body</Ableton>';

/// A device preset document: [device] holding [parameters].
String devicePreset(
  String device,
  Iterable<String> parameters, {
  String major = '5',
}) => document(
  '<$device>$bookkeeping${parameters.join()}</$device>',
  major: major,
);

/// A rack preset document holding a rack device of [rack].
String rackPreset(String rack) => document(
  '<GroupDevicePreset><OverwriteProtectionNumber Value="1" />'
  '<Device><$rack>$bookkeeping</$rack></Device>'
  '<PresetRef /><BranchPresets /><ReturnBranchPresets />'
  '</GroupDevicePreset>',
);

/// [xml] gzipped, as a preset file is.
List<int> gzipped(String xml) => gzip.encode(utf8.encode(xml));

/// A full Drift preset with invented values: every parameter Drift stores,
/// each in the shape Live writes it.
List<String> driftParameters() => [
  manual('On', true),
  manual('Oscillator1_Type', 2, min: 0, max: 6),
  manual('Oscillator1_Shape', 0.25, min: 0, max: 1),
  manual('Oscillator1_ShapeMod', -0.5, min: -1, max: 1),
  leaf('Oscillator1_ShapeModSource', 2),
  manual('Oscillator1_Transpose', -1, min: -2, max: 3),
  manual('Oscillator2_Type', 3, min: 0, max: 4),
  manual('Oscillator2_Detune', 0.125, min: -7, max: 7),
  manual('Oscillator2_Transpose', 1, min: -3, max: 2),
  manual('Mixer_OscillatorGain1', 1.5, min: 0, max: 1.99526799),
  manual('Mixer_OscillatorOn1', true),
  manual('Mixer_OscillatorGain2', 0.5, min: 0, max: 1.99526799),
  manual('Mixer_OscillatorOn2', false),
  manual('Mixer_NoiseLevel', 0.0625, min: 0, max: 1.99526799),
  manual('Mixer_NoiseOn', true),
  manual('Filter_Frequency', 440, min: 19.9999981, max: 19999.9961),
  manual('Filter_Resonance', 0.75, min: 0, max: 1.00999999),
  manual('Filter_Type', 1, min: 0, max: 1),
  manual('Filter_HiPassFrequency', 30, min: 9.99999905, max: 20479.998),
  manual('Filter_Tracking', 0.5, min: 0, max: 1),
  manual('Filter_ModAmount1', 0.375, min: -1, max: 1),
  manual('Filter_ModAmount2', -0.25, min: -1, max: 1),
  leaf('Filter_ModSource1', 0),
  leaf('Filter_ModSource2', 7),
  manual('Filter_OscillatorThrough1', true),
  manual('Filter_OscillatorThrough2', false),
  manual('Filter_NoiseThrough', true),
  manual('Lfo_Mode', 3, min: 0, max: 3),
  manual('Lfo_Rate', 2.5, min: 0.17, max: 1700),
  manual('Lfo_Ratio', 2, min: 0.25, max: 16),
  manual('Lfo_Time', 1.5, min: 0.1, max: 60),
  manual('Lfo_SyncedRate', 12, min: 0, max: 21),
  manual('Lfo_Amount', 0.8, min: 0, max: 1),
  manual('Lfo_Shape', 6, min: 0, max: 8),
  leaf('Lfo_ModSource', 5),
  manual('Lfo_ModAmount', -0.125, min: -1, max: 1),
  manual('Lfo_Retrigger', true),
  leaf('PitchModulation_Source1', 1),
  leaf('PitchModulation_Source2', 3),
  manual('PitchModulation_Amount1', 0.05, min: -1, max: 1),
  manual('PitchModulation_Amount2', -0.1, min: -1, max: 1),
  manual('Envelope1_Attack', 0.01, min: 0, max: 60),
  manual('Envelope1_Decay', 0.4, min: 0.005, max: 60),
  manual('Envelope1_Release', 1.25, min: 0.01, max: 60),
  manual('Envelope1_Sustain', 0.6, min: 0, max: 1),
  manual('Envelope2_Attack', 0.2, min: 0, max: 60),
  manual('Envelope2_Decay', 3, min: 0.005, max: 60),
  manual('Envelope2_Release', 0.5, min: 0.01, max: 60),
  manual('Envelope2_Sustain', 0, min: 0, max: 1),
  manual('CyclingEnvelope_Mode', 1, min: 0, max: 3),
  manual('CyclingEnvelope_Rate', 4, min: 0.17, max: 1700),
  manual('CyclingEnvelope_Ratio', 0.5, min: 0.25, max: 16),
  manual('CyclingEnvelope_Time', 0.75, min: 0.1, max: 60),
  manual('CyclingEnvelope_SyncedRate', 8, min: 0, max: 21),
  manual('CyclingEnvelope_MidPoint', 0.3, min: 0, max: 1),
  manual('CyclingEnvelope_Hold', 0.1, min: 0, max: 1),
  leaf('ModulationMatrix_Source1', 4),
  leaf('ModulationMatrix_Source2', 6),
  leaf('ModulationMatrix_Source3', 1),
  manual('ModulationMatrix_Amount1', 0.9, min: -1, max: 1),
  manual('ModulationMatrix_Amount2', -0.9, min: -1, max: 1),
  manual('ModulationMatrix_Amount3', 0.2, min: -1, max: 1),
  leaf('ModulationMatrix_Target1', 6),
  leaf('ModulationMatrix_Target2', 11),
  leaf('ModulationMatrix_Target3', 0),
  manual('Global_VolVelMod', 0.4, min: 0, max: 1),
  manual('Global_ResetOscillatorPhase', false),
  manual('Global_Envelope2Mode', 1, min: 0, max: 1),
  leaf('Global_VoiceMode', 3),
  manual('Global_PolyVoiceDepth', 0.1, min: 0, max: 1),
  manual('Global_StereoVoiceDepth', 0.2, min: 0, max: 1),
  manual('Global_UnisonVoiceDepth', 0.3, min: 0, max: 1),
  manual('Global_MonoVoiceDepth', 0.4, min: 0, max: 1),
  leaf('Global_PitchBendRange', 2),
  leaf('Global_SerialNumber', -2147483648),
  manual('Global_DriftDepth', 0.05, min: 0, max: 1),
  leaf('Global_VoiceCount', 2),
  manual('Global_Legato', true),
  manual('Global_NotePitchBend', false),
  manual('Global_Glide', 0.08, min: 0, max: 2),
  manual('Global_Volume', 0.7, min: 0, max: 1),
  manual('Global_Transpose', -12, min: -48, max: 48),
  leaf('Global_HiQuality', true),
];
