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
    'feedback' => paramFeedback,
    'mix' => paramMix,
    'rate' => paramRate,
    'depth' => paramDepth,
    'shift' => paramShift,
    'tone' => paramTone,
    'size' => paramSize,
    'damping' => paramDamping,
    'mode' => paramMode,
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
    // The EQ's cuts are off at their ends of the range (engine_fx.c).
    if ((p.key == 'low_cut' && setting <= 0) ||
        (p.key == 'high_cut' && setting >= 1)) {
      return fxValueOff;
    }
    final value = p.valueAt(setting);
    final tenths = (value * 10).round() / 10;
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
      FxParamUnit.ratio => fxValueRatio(tenths),
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

  /// The name of position [position] of choice parameter [p]. The octaver's
  /// mode is the only built-in choice; any other reads as its 1-based number.
  String _choiceName(FxParamInfo p, int position) =>
      switch ((p.key, position)) {
        ('mode', 0) => octaverModePhaseVocoder,
        ('mode', 1) => octaverModePsola,
        _ => '${position + 1}',
      };

  String loopbackKindLabel(LoopbackKind kind) => switch (kind) {
    LoopbackKind.backendLoopback => loopbackKindBackend,
    LoopbackKind.monitor => loopbackKindMonitor,
    LoopbackKind.virtualDevice => loopbackKindVirtualDevice,
    LoopbackKind.none => '',
  };

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

  String loopbackNote(LoopbackInfo loopback) {
    final deviceClause = loopback.deviceName.isNotEmpty
        ? ' (${loopback.deviceName})'
        : '';
    if (loopback.isAutoRoutable) {
      return loopbackDetectedNote(deviceClause);
    }
    return loopbackAvailableNote(
      loopbackKindLabel(loopback.kind),
      deviceClause,
    );
  }
}

/// What `TracksCubit` STORES for a track nobody has renamed.
///
/// Storage, not a display string: it is what a fresh rig persists, and what
/// [EngineLocalizations.displayTrackName] recognises in order to hand back the
/// localized default instead. One definition, because three copies of the same
/// literal can silently disagree — the cubit's seed, the resolver's fallback
/// and the recogniser are all this.
String storedDefaultTrackName(int channel) => 'TRACK ${channel + 1}';
