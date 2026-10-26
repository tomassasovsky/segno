import 'package:looper_repository/looper_repository.dart';
import 'package:segno/l10n/gen/app_localizations.dart';

/// Localized labels for engine enums and formatted values.
extension EngineLocalizations on AppLocalizations {
  String trackStateLabel(TrackState state) => switch (state) {
    TrackState.empty => trackStateEmpty,
    TrackState.recording => trackStateRecording,
    TrackState.overdubbing => trackStateOverdubbing,
    TrackState.playing => trackStatePlaying,
    TrackState.stopped => trackStateStopped,
  };

  String effectTypeLabel(TrackEffectType type) => switch (type) {
    TrackEffectType.none => effectNone,
    TrackEffectType.drive => effectDrive,
    TrackEffectType.filter => effectFilter,
    TrackEffectType.delay => effectDelay,
    TrackEffectType.tremolo => effectTremolo,
    TrackEffectType.octaver => effectOctaver,
    TrackEffectType.echo => effectEcho,
    TrackEffectType.reverb => effectReverb,
    TrackEffectType.eq => effectEq,
    TrackEffectType.compressor => effectCompressor,
    TrackEffectType.transient => effectTransient,
    TrackEffectType.hpGate => effectHpGate,
    TrackEffectType.doubler => effectDoubler,
    TrackEffectType.chorus => effectChorus,
    TrackEffectType.wah => effectWah,
    TrackEffectType.overdrive => effectOverdrive,
    TrackEffectType.distortion => effectDistortion,
    TrackEffectType.vinyl => effectVinyl,
    TrackEffectType.degrade => effectDegrade,
    TrackEffectType.lpf => effectLpf,
    TrackEffectType.spring => effectSpring,
    TrackEffectType.dubVerb => effectDubVerb,
    TrackEffectType.ambVerb => effectAmbVerb,
    TrackEffectType.whammy => effectWhammy,
    TrackEffectType.pumper => effectPumper,
    TrackEffectType.slicer => effectSlicer,
    TrackEffectType.modeDelay => effectModeDelay,
    TrackEffectType.dualOctaver => effectDualOctaver,
    TrackEffectType.ampCab => effectAmpCab,
    TrackEffectType.mod => effectMod,
    TrackEffectType.roomVerb => effectRoomVerb,
    TrackEffectType.smartTune => effectSmartTune,
  };

  /// The name of a built-in effect parameter, by its stable key. An unknown
  /// key reads as the key itself rather than as nothing.
  String fxParamName(FxParamInfo p) => fxParamKeyName(p.key);

  /// The name of the built-in parameter whose stable key is [key]; also how
  /// a rack variant renames one (the single mid band of a parametric EQ).
  String fxParamKeyName(String key) => switch (key) {
    'drive' => paramDrive,
    'level' => paramLevel,
    'cutoff' => paramCutoff,
    'resonance' => paramResonance,
    'time' => paramTime,
    'delay_time' => paramTime,
    'delay_mode' => paramMode,
    'delay_freq' => paramFrequency,
    'damp' => paramDamping,
    'lr_ratio' => paramLrRatio,
    'reso' => paramResonance,
    'res_freq' => paramResFreq,
    'oct_high_mode' => paramHighMode,
    'octave_1_vol' => paramOctave1Level,
    'octave_2_vol' => paramOctave2Level,
    'bass' => paramBass,
    'treble' => paramTreble,
    'modern' => paramModern,
    'cabinet' => paramCabinet,
    'mod_mode' => paramMode,
    'studio_mod_mode' => paramMode,
    'length' => paramLength,
    'room' => paramRoom,
    'room_mode' => paramMode,
    'er_room' => paramEarlyRoom,
    'bright' => paramBright,
    'lo_hi' => paramLoHi,
    'tail_er' => paramTailEr,
    'density' => paramDensity,
    'speed' => paramSpeed,
    'scale_root' => paramScaleRoot,
    'scale_type' => paramScaleType,
    'reference' => paramReference,
    'decay' => paramDecay,
    'volume' => paramVolume,
    'amb_dub_mix' => paramAmbDubMix,
    'feedback' => paramFeedback,
    'mix' => paramMix,
    'rate' => paramRate,
    'depth' => paramDepth,
    'shift' => paramShift,
    'tone' => paramTone,
    'size' => paramSize,
    'damping' => paramDamping,
    'mode' => paramMode,
    'formants' => paramFormants,
    'whammy_range' => paramRange,
    'pumper_rate' => paramRate,
    'slicer_pattern' => paramPattern,
    'slicer_step' => paramStep,
    'lfo_depth' => paramLfoDepth,
    'lfo_rate' => paramLfoRate,
    'low_cut' => paramLowCut,
    'low_gain' => paramLowGain,
    'low_freq' => paramLowFreq,
    'low_q' => paramLowQ,
    'lo_mid_gain' => paramLoMidGain,
    'lo_mid_freq' => paramLoMidFreq,
    'lo_mid_q' => paramLoMidQ,
    'hi_mid_gain' => paramHiMidGain,
    'hi_mid_freq' => paramHiMidFreq,
    'hi_mid_q' => paramHiMidQ,
    'high_gain' => paramHighGain,
    'high_freq' => paramHighFreq,
    'high_q' => paramHighQ,
    'high_cut' => paramHighCut,
    'air_gain' => paramAirGain,
    'layout' => paramEqLayout,
    'mid_gain' => paramMidGain,
    'mid_freq' => paramMidFreq,
    'mid_q' => paramMidQ,
    'threshold' => paramThreshold,
    'ratio' => paramRatio,
    'attack' => paramAttack,
    'release' => paramRelease,
    'makeup' => paramMakeup,
    'attack_length' => paramAttackLength,
    'sustain' => paramSustain,
    'highpass' => paramHighpass,
    'gate_threshold' => paramGateThreshold,
    'separation' => paramSeparation,
    'pedal' => paramPedal,
    'frequency' => paramFrequency,
    'noise' => paramNoise,
    'noise_tone' => paramNoiseTone,
    'filter' => paramFilter,
    _ => key,
  };

  /// The value a built-in parameter's normalized [setting] stands for, with
  /// its unit, as one string: `35%`, `350 ms`, `12.5 ms`, `0.05 ms`,
  /// `440 Hz`, `1.2 kHz`, `15.5x`, `4.0:1`, a pitch interval, or a named
  /// position.
  ///
  /// Times and frequencies drop the decimal from 100 up, where a tenth is
  /// finer than a performer sets or hears; a time under 1 ms keeps two
  /// decimals; a frequency reads in kHz from 1000 Hz.
  String fxParamValueText(FxParamInfo p, double setting) {
    // The low-pass filter and the HP/Gate's high-pass are off at an end of
    // their range (the descriptor's off flag).
    if (p.isOffAt(setting)) {
      return fxValueOff;
    }
    final value = p.valueAt(setting);
    final tenths = (value * 10).round() / 10;
    // Smart Tune's reference reads to a tenth, as the Looper X shows it:
    // its whole range is 40 Hz, and A = 441 or 442 is what it is for.
    if (p.key == 'reference') return fxValueHzFine(tenths);
    return switch (p.unit) {
      FxParamUnit.percent => fxValuePercent(value.round()),
      FxParamUnit.ms =>
        tenths >= 100
            ? fxValueMs(value.round())
            : value > 0 && value < 0.995
            ? fxValueMsFiner((value * 100).round() / 100)
            : fxValueMsFine(tenths),
      FxParamUnit.hz =>
        value.round() >= 1000
            ? fxValueKhz(value / 1000)
            : tenths >= 100
            ? fxValueHz(value.round())
            : fxValueHzFine(tenths),
      FxParamUnit.semitones => _pitchInterval(value),
      FxParamUnit.times => fxValueTimes(value),
      FxParamUnit.choice => _choiceName(p, p.positionOf(setting)),
      FxParamUnit.db => fxValueDb(tenths),
      FxParamUnit.q => fxValueQ(value),
      FxParamUnit.seconds => fxValueSeconds(value),
      FxParamUnit.ratio =>
        tenths >= 100 ? fxValueRatioWhole(value.round()) : fxValueRatio(tenths),
    };
  }

  /// A pitch interval: unison, whole octaves or semitones, or semitones with
  /// one decimal for a setting between semitones (the octaver plays its shift
  /// as set; only its controls snap to semitones).
  String _pitchInterval(double semitones) {
    final whole = semitones.round();
    if ((semitones - whole).abs() >= 0.05) {
      final sign = semitones > 0 ? '+' : '-';
      return pitchSemitonesFine(sign, (semitones.abs() * 10).round() / 10);
    }
    if (whole == 0) return pitchUnison;
    final sign = whole > 0 ? '+' : '-';
    final magnitude = whole.abs();
    if (magnitude % 12 == 0) return pitchOctaves(sign, magnitude ~/ 12);
    return pitchSemitones(sign, magnitude);
  }

  /// The name of position [position] of choice parameter [p]: the octaver's
  /// mode or formants, the EQ's layout, the Whammy's range, the Pumper's
  /// rate, the Slicer's pattern or step, the LPF's LFO rate, the Mode
  /// delay's time or mode, the Dual Octaver's high mode, the Amp's cabinet,
  /// the Mod's mode, the Room reverb's room, or Smart Tune's scale root or
  /// type. Any other reads as its 1-based number.
  String _choiceName(FxParamInfo p, int position) =>
      switch ((p.key, position)) {
        ('mode', 0) => octaverModePhaseVocoder,
        ('mode', 1) => octaverModePsola,
        ('formants', 0) => octaverFormantsHeld,
        ('formants', 1) => octaverFormantsMoved,
        ('whammy_range', 0) => pitchOctaves('-', 1),
        ('whammy_range', 1) => pitchOctaves('+', 1),
        ('pumper_rate', 0) => noteValueBar,
        ('pumper_rate', final i) => _pumperRates[i - 1],
        ('slicer_pattern', final i) => _slicerPatterns[i],
        ('slicer_step', final i) => _slicerSteps[i],
        ('lfo_rate', final i) => _lfoRates[i],
        ('delay_time', final i) => _delayTimes[i],
        ('delay_mode', final i) => _delayModes[i],
        ('cabinet', final i) => _cabinets[i],
        ('mod_mode', final i) => _modModes[i],
        ('room' || 'room_mode', final i) => _rooms[i],
        ('er_room', final i) => _rooms[4 + i],
        ('scale_root', final i) => _notes[i],
        ('scale_type', final i) => _scaleTypes[i],
        ('studio_mod_mode', 0) => 'Chorus',
        ('studio_mod_mode', _) => 'Tremolo',
        ('oct_high_mode', 0) => toggleOff,
        ('oct_high_mode', _) => toggleOn,
        ('layout', 0) => eqLayoutShelves,
        ('layout', 1) => eqLayoutBellsCuts,
        ('layout', 2) => eqLayoutBells,
        _ => '${position + 1}',
      };

  /// The Pumper's note values after Bar, in its rate's order.
  static const List<String> _pumperRates = [
    '1/2',
    '1/2T',
    '1/4',
    '1/4T',
    '1/8',
    '1/8T',
    '1/16',
    '1/16T',
    '1/32',
    '1/32T',
  ];

  /// The Slicer's patterns, as the Looper X writes them: a capital letter a
  /// step, a lower-case one half a step, `_` a rest, `<` the step before
  /// backwards.
  static const List<String> _slicerPatterns = [
    'AABB',
    'ABCC',
    'AACD',
    'ABC_',
    'A_C_',
    'A_CC',
    'A___C___',
    'ABcccc',
    'AAccdd',
    'AB__dd',
    'AA__dd',
    'ABC<',
    'AB_<',
    'AA_<',
    'A_B_C<',
    'AB<<',
    '<<<<',
  ];

  /// The Slicer's step note values, in its step's order.
  static const List<String> _slicerSteps = [
    '1/4',
    '1/4T',
    '1/8',
    '1/8T',
    '1/16',
    '1/16T',
    '1/32',
    '1/32T',
    '1/64',
  ];

  /// The Mode delay's times, shortest first, in its time's order.
  static const List<String> _delayTimes = [
    '1/32',
    '1/16T',
    '1/32D',
    '1/16',
    '1/8T',
    '1/16D',
    '1/8',
    '1/4T',
    '1/8D',
    '1/4',
    '2/4T',
    '1/4D',
    '2/4',
    '5/8',
    '3/4',
    '7/8',
    '4/4',
    '5/4',
    '6/4',
    '8/4',
  ];

  /// The Amp's cabinets, as the Looper X names them.
  static const List<String> _cabinets = [
    'D.I.',
    'BRIT',
    '1x8"',
    '1x12"',
    '2x10"',
    '2x12"',
    '4x10"',
    '4x12"',
    '1x15"',
    'BASS',
    '4x10"',
    'RADIO',
  ];

  /// The notes from C, as the Looper X names Smart Tune's scale root.
  static const List<String> _notes = [
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];

  /// Smart Tune's scale types, as the Looper X names them.
  static const List<String> _scaleTypes = [
    'Major',
    'Minor',
    'Harm Min',
    'Melo Min',
    'Dorian',
    'Phrygian',
    'Lydian',
    'Mixo',
    'Locrian',
    'Chromatic',
    'Penta',
    'Maj Triad',
    'Min Triad',
    'Root',
  ];

  /// The Room reverb's rooms, as the Looper X names them: the four modes,
  /// then the Drum Rack's ER rooms.
  static const List<String> _rooms = [
    'HALL',
    'STADIUM',
    'ROOM',
    'BOX',
    'BOOTH',
    'CLUB',
    'ROOM',
    'SMALL CHAMBER',
    'Med CHAMBER',
    'LARGE CHAMBER',
    'SMALL STUDIO',
    'LARGE STUDIO',
    'SCORING STAGE',
    'PHILHARMONIC',
    'CONCERT HALL',
    'CHURCH',
  ];

  /// The Mod's modes, as the Looper X names them: the Guitar Rack's three,
  /// then the Studio Rack's tremolo.
  static const List<String> _modModes = [
    'CHORUS',
    'PHASER',
    'FLANGER',
    'Tremolo',
  ];

  /// The Mode delay's modes, as the Looper X names them.
  static const List<String> _delayModes = [
    'DIGI',
    'DIGI L/R',
    'DIGI GRV',
    'DAMPED',
    'DAMPED L/R',
    'DAMPED GRV',
    'RESO LO',
    'RES LO L/R',
    'RES LO GRV',
    'RESO HI',
    'RES HI L/R',
    'RES HI GRV',
    'DRUM',
    'DUB',
  ];

  /// The Rhythmic LPF's LFO periods, longest first, in its rate's order:
  /// whole numbers of quarters, then note values.
  static const List<String> _lfoRates = [
    '8/4',
    '6/4',
    '5/4',
    '4/4',
    '3/4',
    '1/1T',
    '1/2',
    '1/4D',
    '1/2T',
    '1/4',
    '1/8D',
    '1/4T',
    '1/8',
    '1/16D',
    '1/8T',
    '1/16',
  ];

  String latencyStateLabel(EngineStatus status) =>
      switch (status.latencyState) {
        LatencyState.done => latencyMs(
          status.measuredLatencyMs.toStringAsFixed(2),
        ),
        LatencyState.measuring => measuringLowercase,
        LatencyState.timeout => noLoopback,
        LatencyState.idle => notMeasured,
      };

  String displayTrackName(String name, int channel) =>
      name == storedDefaultTrackName(channel)
      ? defaultTrackName(channel + 1)
      : name;

  /// What to CALL track [channel], given the rig's [names] — the one resolver
  /// every surface that names a track goes through (#526).
  ///
  /// [displayTrackName] answers the same question but only once the caller has
  /// already found the name, which is why half the app was still printing an
  /// ordinal: the pedal target list, the MIDI-learn labels, the FX bus title
  /// and the rename dialog all had a channel and no list, so they said "Track
  /// 3" while the stage beside them said RHYTHM. This takes the channel and
  /// the list, so having one is enough.
  ///
  /// Out-of-range channels fall back rather than throw: a stale binding names
  /// a track the rig no longer has, and a row that still has to say what it
  /// used to drive is better than a crash.
  String trackName(List<String> names, int channel) => displayTrackName(
    channel >= 0 && channel < names.length
        ? names[channel]
        : storedDefaultTrackName(channel),
    channel,
  );

  /// What to CALL hardware input [input], given the rig's [names] — the
  /// input-side twin of [trackName], and for the same reason: two surfaces
  /// disagreeing about what an input is called is exactly the bug track names
  /// already had (#526).
  ///
  /// An unnamed socket falls back to its full ordinal (`Input 2`). A session
  /// saved on an eight-in rig still names Input 6 when reopened on a two-in
  /// one, where that source is unavailable.
  String inputName(Map<int, String> names, int input) {
    final given = names[input] ?? '';
    return given.isNotEmpty ? given : routingInputOrdinal(input + 1);
  }

  /// The jacks destination [bus] drives on a device with [channels] outputs.
  ///
  /// A destination is the stereo pair `2*bus` and `2*bus + 1`. An odd-channel
  /// device leaves the last destination holding a single jack, and it is
  /// labelled as one rather than promising a socket the interface has not got.
  String outputBusLabel(int bus, {required int channels}) =>
      2 * bus + 1 < channels
      ? outputPairLabel(2 * bus + 1, 2 * bus + 2)
      : outputSingleLabel(2 * bus + 1);

  /// What to CALL destination [bus], given the rig's [names] — the output-side
  /// twin of [inputName], and for the same reason.
  ///
  /// An unnamed destination falls back to its full jack label (`Outputs 1–2`
  /// or `Output 5` for an odd final jack).
  String outputName(
    Map<int, String> names,
    int bus, {
    required int channels,
  }) {
    final given = names[bus] ?? '';
    if (given.isNotEmpty) return given;
    return outputBusLabel(bus, channels: channels);
  }

  String sampleRateKhzLabel(int rate) {
    final khz = rate / 1000;
    final text = khz == khz.roundToDouble()
        ? khz.toStringAsFixed(0)
        : khz.toStringAsFixed(1);
    return sampleRateKhz(text);
  }

  String bufferHint(int frames) => switch (frames) {
    <= 64 => bufferHint64,
    128 => bufferHint128,
    256 => bufferHint256,
    _ => bufferHint512,
  };

  String sampleRateNote(int rate) => switch (rate) {
    44100 => sampleRateNoteCd,
    48000 => sampleRateNoteStudio,
    96000 => sampleRateNoteHiRes,
    _ => '',
  };

  String setupBlurb(int step) => switch (step) {
    0 => setupBlurbEngine,
    1 => setupBlurbInput,
    _ => setupBlurbReady,
  };
}

/// What `TracksCubit` STORES for a track nobody has renamed.
///
/// Storage, not a display string: it is what a fresh rig persists, and what
/// [EngineLocalizations.displayTrackName] recognises in order to hand back the
/// localized default instead. One definition, because three copies of the same
/// literal can silently disagree — the cubit's seed, the resolver's fallback
/// and the recogniser are all this.
String storedDefaultTrackName(int channel) => 'TRACK ${channel + 1}';
