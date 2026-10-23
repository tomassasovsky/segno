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
