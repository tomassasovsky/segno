import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/l10n.dart';

/// The value text of every built-in parameter at setting 0, its default and 1,
/// as `type.key: [at 0, at default, at 1]`.
const _english = <String, List<String>>{
  'drive.drive': ['1.0x', '15.5x', '30.0x'],
  'drive.level': ['0%', '80%', '100%'],
  'filter.cutoff': ['20.0 Hz', '600 Hz', '18.0 kHz'],
  'filter.resonance': ['0%', '20%', '100%'],
  'delay.time': ['0.0 ms', '350 ms', '1000 ms'],
  'delay.feedback': ['0%', '33%', '95%'],
  'delay.mix': ['0%', '35%', '100%'],
  'tremolo.rate': ['0.1 Hz', '3.7 Hz', '12.0 Hz'],
  'tremolo.depth': ['0%', '70%', '100%'],
  'octaver.shift': ['-2 oct', '-1 oct', '+2 oct'],
  'octaver.tone': ['0%', '50%', '100%'],
  'octaver.mix': ['0%', '50%', '100%'],
  'octaver.mode': ['Phase Vocoder', 'Phase Vocoder', 'PSOLA'],
  'echo.time': ['0.0 ms', '450 ms', '1000 ms'],
  'echo.feedback': ['0%', '49%', '97%'],
  'echo.mix': ['0%', '35%', '100%'],
  'reverb.size': ['0%', '50%', '100%'],
  'reverb.damping': ['0%', '50%', '100%'],
  'reverb.mix': ['0%', '35%', '100%'],
  'eq.low_cut': ['Off', '70.4 Hz', '8.0 kHz'],
  'eq.low_gain': ['-18.0 dB', '0.0 dB', '18.0 dB'],
  'eq.low_freq': ['20.0 Hz', '90.0 Hz', '1.0 kHz'],
  'eq.low_q': ['0.40', '0.40', '2.00'],
  'eq.lo_mid_gain': ['-18.0 dB', '0.0 dB', '18.0 dB'],
  'eq.lo_mid_freq': ['20.0 Hz', '216 Hz', '20.0 kHz'],
  'eq.lo_mid_q': ['0.40', '0.70', '10.00'],
  'eq.hi_mid_gain': ['-18.0 dB', '0.0 dB', '18.0 dB'],
  'eq.hi_mid_freq': ['20.0 Hz', '1.8 kHz', '20.0 kHz'],
  'eq.hi_mid_q': ['0.40', '0.66', '10.00'],
  'eq.high_gain': ['-18.0 dB', '0.0 dB', '18.0 dB'],
  'eq.high_freq': ['2.0 kHz', '6.0 kHz', '16.0 kHz'],
  'eq.high_q': ['0.40', '0.40', '2.00'],
  'eq.high_cut': ['120 Hz', 'Off', 'Off'],
  'eq.air_gain': ['-18.0 dB', '0.0 dB', '18.0 dB'],
  'compressor.threshold': ['0.0 dB', '-21.0 dB', '-60.0 dB'],
  'compressor.ratio': ['1.0:1', '4.0:1', '100:1'],
  'compressor.attack': ['0.01 ms', '1.7 ms', '300 ms'],
  'compressor.release': ['5.0 ms', '141 ms', '4000 ms'],
  'compressor.makeup': ['0.0 dB', '1.8 dB', '30.0 dB'],
  'transient.attack': ['0%', '50%', '100%'],
  'transient.attack_length': ['0%', '50%', '100%'],
  'transient.sustain': ['0%', '50%', '100%'],
  'hpGate.highpass': ['1.0 Hz', '1.0 Hz', '1.0 kHz'],
  'hpGate.gate_threshold': ['-120.0 dB', '-120.0 dB', '0.0 dB'],
  'doubler.mix': ['0%', '100%', '100%'],
  'doubler.separation': ['0%', '100%', '100%'],
  'chorus.rate': ['0%', '45%', '100%'],
  'chorus.depth': ['0%', '21%', '100%'],
  'chorus.mix': ['0%', '50%', '100%'],
  'wah.pedal': ['0%', '62%', '100%'],
  'overdrive.drive': ['0%', '9%', '100%'],
  'overdrive.tone': ['0%', '50%', '100%'],
  'distortion.drive': ['0%', '20%', '100%'],
  'distortion.tone': ['0%', '50%', '100%'],
  'vinyl.drive': ['0%', '40%', '100%'],
  'vinyl.frequency': ['50.0 Hz', '251 Hz', '5.0 kHz'],
  'vinyl.noise': ['0%', '30%', '100%'],
  'vinyl.noise_tone': ['0%', '90%', '100%'],
  'degrade.frequency': ['500 Hz', '50.0 kHz', '50.0 kHz'],
  'degrade.filter': ['0%', '100%', '100%'],
  'degrade.mix': ['0%', '100%', '100%'],
  'lpf.cutoff': ['20.0 Hz', 'Off', 'Off'],
  'lpf.resonance': ['0%', '100%', '100%'],
};

/// The same in Spanish: a decimal comma, and the Spanish mode name.
const _spanish = <String, List<String>>{
  'drive.drive': ['1,0x', '15,5x', '30,0x'],
  'drive.level': ['0%', '80%', '100%'],
  'filter.cutoff': ['20,0 Hz', '600 Hz', '18,0 kHz'],
  'filter.resonance': ['0%', '20%', '100%'],
  'delay.time': ['0,0 ms', '350 ms', '1000 ms'],
  'delay.feedback': ['0%', '33%', '95%'],
  'delay.mix': ['0%', '35%', '100%'],
  'tremolo.rate': ['0,1 Hz', '3,7 Hz', '12,0 Hz'],
  'tremolo.depth': ['0%', '70%', '100%'],
  'octaver.shift': ['-2 oct', '-1 oct', '+2 oct'],
  'octaver.tone': ['0%', '50%', '100%'],
  'octaver.mix': ['0%', '50%', '100%'],
  'octaver.mode': ['Vocoder de fase', 'Vocoder de fase', 'PSOLA'],
  'echo.time': ['0,0 ms', '450 ms', '1000 ms'],
  'echo.feedback': ['0%', '49%', '97%'],
  'echo.mix': ['0%', '35%', '100%'],
  'reverb.size': ['0%', '50%', '100%'],
  'reverb.damping': ['0%', '50%', '100%'],
  'reverb.mix': ['0%', '35%', '100%'],
  'eq.low_cut': ['Apagado', '70,4 Hz', '8,0 kHz'],
  'eq.low_gain': ['-18,0 dB', '0,0 dB', '18,0 dB'],
  'eq.low_freq': ['20,0 Hz', '90,0 Hz', '1,0 kHz'],
  'eq.low_q': ['0,40', '0,40', '2,00'],
  'eq.lo_mid_gain': ['-18,0 dB', '0,0 dB', '18,0 dB'],
  'eq.lo_mid_freq': ['20,0 Hz', '216 Hz', '20,0 kHz'],
  'eq.lo_mid_q': ['0,40', '0,70', '10,00'],
  'eq.hi_mid_gain': ['-18,0 dB', '0,0 dB', '18,0 dB'],
  'eq.hi_mid_freq': ['20,0 Hz', '1,8 kHz', '20,0 kHz'],
  'eq.hi_mid_q': ['0,40', '0,66', '10,00'],
  'eq.high_gain': ['-18,0 dB', '0,0 dB', '18,0 dB'],
  'eq.high_freq': ['2,0 kHz', '6,0 kHz', '16,0 kHz'],
  'eq.high_q': ['0,40', '0,40', '2,00'],
  'eq.high_cut': ['120 Hz', 'Apagado', 'Apagado'],
  'eq.air_gain': ['-18,0 dB', '0,0 dB', '18,0 dB'],
  'compressor.threshold': ['0,0 dB', '-21,0 dB', '-60,0 dB'],
  'compressor.ratio': ['1,0:1', '4,0:1', '100:1'],
  'compressor.attack': ['0,01 ms', '1,7 ms', '300 ms'],
  'compressor.release': ['5,0 ms', '141 ms', '4000 ms'],
  'compressor.makeup': ['0,0 dB', '1,8 dB', '30,0 dB'],
  'transient.attack': ['0%', '50%', '100%'],
  'transient.attack_length': ['0%', '50%', '100%'],
  'transient.sustain': ['0%', '50%', '100%'],
  'hpGate.highpass': ['1,0 Hz', '1,0 Hz', '1,0 kHz'],
  'hpGate.gate_threshold': ['-120,0 dB', '-120,0 dB', '0,0 dB'],
  'doubler.mix': ['0%', '100%', '100%'],
  'doubler.separation': ['0%', '100%', '100%'],
  'chorus.rate': ['0%', '45%', '100%'],
  'chorus.depth': ['0%', '21%', '100%'],
  'chorus.mix': ['0%', '50%', '100%'],
  'wah.pedal': ['0%', '62%', '100%'],
  'overdrive.drive': ['0%', '9%', '100%'],
  'overdrive.tone': ['0%', '50%', '100%'],
  'distortion.drive': ['0%', '20%', '100%'],
  'distortion.tone': ['0%', '50%', '100%'],
  'vinyl.drive': ['0%', '40%', '100%'],
  'vinyl.frequency': ['50,0 Hz', '251 Hz', '5,0 kHz'],
  'vinyl.noise': ['0%', '30%', '100%'],
  'vinyl.noise_tone': ['0%', '90%', '100%'],
  'degrade.frequency': ['500 Hz', '50,0 kHz', '50,0 kHz'],
  'degrade.filter': ['0%', '100%', '100%'],
  'degrade.mix': ['0%', '100%', '100%'],
  'lpf.cutoff': ['20,0 Hz', 'Apagado', 'Apagado'],
  'lpf.resonance': ['0%', '100%', '100%'],
};

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));

  Map<String, List<String>> render(AppLocalizations l10n) => {
    for (final type in TrackEffectType.values)
      for (final p in type.params)
        '${type.name}.${p.key}': [
          for (final setting in [0.0, p.defaultValue, 1.0])
            l10n.fxParamValueText(p, setting),
        ],
  };

  group('fxParamValueText', () {
    test('reads every built-in parameter in English', () {
      expect(render(en), _english);
    });

    test('reads every built-in parameter in Spanish', () {
      expect(render(es), _spanish);
    });

    const ms = FxParamInfo(
      key: 'time',
      unit: FxParamUnit.ms,
      atMin: 0,
      atMax: 1000,
      defaultValue: 0,
    );
    const hz = FxParamInfo(
      key: 'rate',
      unit: FxParamUnit.hz,
      atMin: 0,
      atMax: 2000,
      defaultValue: 0,
    );

    test('keeps one decimal below 100 ms and none from 100 ms', () {
      expect(en.fxParamValueText(ms, 0.0125), '12.5 ms');
      // 99.96 ms rounds to 100.0, so it reads as a whole 100.
      expect(en.fxParamValueText(ms, 0.09996), '100 ms');
      expect(en.fxParamValueText(ms, 0.35), '350 ms');
    });

    test('keeps two decimals below 1 ms', () {
      final attack = TrackEffectType.compressor.params[2];
      expect(en.fxParamValueText(attack, 0), '0.01 ms');
      // 0.01 * 30000^0.3 = 0.22 ms.
      expect(en.fxParamValueText(attack, 0.3), '0.22 ms');
      expect(es.fxParamValueText(attack, 0.3), '0,22 ms');
      // 0.999 ms rounds to 1.00, so it reads with one decimal.
      expect(
        en.fxParamValueText(attack, attack.settingFor(0.999)),
        '1.0 ms',
      );
    });

    test('reads a ratio with one decimal against 1', () {
      final ratio = TrackEffectType.compressor.params[1];
      expect(en.fxParamValueText(ratio, 0.758), '4.0:1');
      expect(es.fxParamValueText(ratio, 0.5), '2,0:1');
    });

    test('reads whole hertz from 100 Hz and kilohertz from 1000 Hz', () {
      expect(en.fxParamValueText(hz, 0.0125), '25.0 Hz');
      expect(en.fxParamValueText(hz, 0.22), '440 Hz');
      expect(en.fxParamValueText(hz, 0.6), '1.2 kHz');
      expect(es.fxParamValueText(hz, 0.6), '1,2 kHz');
    });

    test('reads a pitch interval as unison, semitones or octaves', () {
      final shift = TrackEffectType.octaver.params.first;
      expect(en.fxParamValueText(shift, 0.5), en.pitchUnison);
      // 0.27 plays -11.04 semitones, within a twentieth of -11.
      expect(en.fxParamValueText(shift, 0.27), '-11 st');
      expect(en.fxParamValueText(shift, 0.75), '+1 oct');
    });

    test('reads a shift between semitones with one decimal', () {
      final shift = TrackEffectType.octaver.params.first;
      // 0.26 plays -11.52 semitones.
      expect(en.fxParamValueText(shift, 0.26), '-11.5 st');
      expect(es.fxParamValueText(shift, 0.26), '-11,5 st');
    });

    test('reads an unknown choice as its 1-based position', () {
      const other = FxParamInfo(
        key: 'other',
        unit: FxParamUnit.choice,
        steps: 3,
        atMin: 0,
        atMax: 2,
        defaultValue: 0,
      );
      expect(en.fxParamValueText(other, 1), '3');
    });
  });

  group('fxParamName', () {
    test('names every built-in parameter in both languages', () {
      for (final l10n in [en, es]) {
        for (final type in TrackEffectType.values) {
          for (final p in type.params) {
            final name = l10n.fxParamName(p);
            expect(name, isNot(p.key), reason: '${type.name}.${p.key}');
            expect(name, isNotEmpty);
          }
        }
      }
      expect(en.fxParamName(TrackEffectType.filter.params.first), 'Cutoff');
      expect(es.fxParamName(TrackEffectType.octaver.params.last), 'Modo');
    });

    test('reads an unknown key as the key itself', () {
      const unknown = FxParamInfo(
        key: 'wobble',
        unit: FxParamUnit.percent,
        atMin: 0,
        atMax: 100,
        defaultValue: 0,
      );
      expect(en.fxParamName(unknown), 'wobble');
    });
  });
}
