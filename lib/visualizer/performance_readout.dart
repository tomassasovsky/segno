import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart'
    show RecordTiming, TempoFollowState;
import 'package:segno/appliance/power_off/power_step.dart';
import 'package:segno/notices/model/notice.dart';

/// The selected track as the 7" display shows it (the accepted design): its
/// number, name, crown, state and the facts under the name.
class ReadoutTrack extends Equatable {
  /// Creates a [ReadoutTrack].
  const new({
    required this.channel,
    required this.name,
    required this.state,
    this.muted = false,
    this.primary = false,
    this.defaultName = false,
    this.bars = 0,
  });

  /// Rebuilds a track from [map] as pushed across the window channel.
  factory fromMap(Map<Object?, Object?> map) => ReadoutTrack(
    channel: map['channel'] as int? ?? 0,
    name: map['name'] as String? ?? '',
    state: map['state'] as String? ?? 'empty',
    muted: map['muted'] as bool? ?? false,
    primary: map['primary'] as bool? ?? false,
    defaultName: map['defaultName'] as bool? ?? false,
    bars: map['bars'] as int? ?? 0,
  );

  /// The track's channel, `0`-based; the display shows `channel + 1`.
  final int channel;

  /// Display name — the STORED name, with [defaultName] saying whether it is
  /// the track's default identity so the readout can localize that itself.
  final String name;

  /// `TrackState.name` — carried as a token rather than the enum because the
  /// readout is a separate engine and the payload crosses the screen link.
  final String state;

  /// Muted right now.
  final bool muted;

  /// Wears the primary crown — the first completed recording.
  final bool primary;

  /// [name] is the track's default identity, nobody having renamed it.
  final bool defaultName;

  /// Whole bars across the track, `0` when nothing counts them.
  final int bars;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'channel': channel,
    'name': name,
    'state': state,
    'muted': muted,
    'primary': primary,
    'defaultName': defaultName,
    'bars': bars,
  };

  @override
  List<Object?> get props => [
    channel,
    name,
    state,
    muted,
    primary,
    defaultName,
    bars,
  ];
}

/// The message the 7" shows in a band across its top margin (#1562): the
/// one the main screen's top bar says, already in words, since the readout
/// is a separate engine.
class ReadoutNotice extends Equatable {
  /// Creates a [ReadoutNotice].
  const new({
    required this.title,
    required this.tone,
    this.body,
    this.track,
  });

  /// Rebuilds a notice from [map] as pushed across the window channel, or
  /// null when [map] is not one.
  static ReadoutNotice? fromMap(Object? map) {
    if (map is! Map<Object?, Object?>) return null;
    final title = map['title'];
    if (title is! String) return null;
    final body = map['body'];
    final track = map['track'];
    return ReadoutNotice(
      title: title,
      body: body is String ? body : null,
      track: track is String ? track : null,
      tone: NoticeTone.values.asNameMap()[map['tone']] ?? NoticeTone.neutral,
    );
  }

  /// The message.
  final String title;

  /// Its second part.
  final String? body;

  /// How much it matters.
  final NoticeTone tone;

  /// The name of the track that caused it, said before it.
  final String? track;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'title': title,
    'body': body,
    'tone': tone.name,
    'track': track,
  };

  @override
  List<Object?> get props => [title, body, tone, track];
}

/// The length and record timing the next take uses, as the readout's Loop
/// panel shows and edits them (#1654): the defaults for all tracks, and the
/// selected track's own values when it has them, which stay main-screen
/// edits.
class ReadoutLoopSettings extends Equatable {
  /// Creates a [ReadoutLoopSettings].
  const new({
    this.lengthBars = 0,
    this.trackLengthBars,
    this.timing = RecordTiming.immediately,
    this.trackTiming,
    this.captureLocked = false,
    this.ready = false,
  });

  /// Rebuilds the settings from [map] as pushed across the window channel;
  /// anything missing or garbled reads as the defaults, not ready.
  factory fromMap(Object? map) {
    if (map is! Map<Object?, Object?>) return const ReadoutLoopSettings();
    final timings = RecordTiming.values.asNameMap();
    final lengthBars = map['lengthBars'];
    final trackLengthBars = map['trackLengthBars'];
    final timing = timings[map['timing']];
    final captureLocked = map['captureLocked'];
    final ready = map['ready'];
    return ReadoutLoopSettings(
      lengthBars: lengthBars is int ? lengthBars : 0,
      trackLengthBars: trackLengthBars is int ? trackLengthBars : null,
      timing: timing ?? RecordTiming.immediately,
      trackTiming: timings[map['trackTiming']],
      captureLocked: captureLocked is bool && captureLocked,
      // A garbled timing is not a confirmed one.
      ready: ready is bool && ready && timing != null,
    );
  }

  /// The default length of the next take in bars, `0` for Auto.
  final int lengthBars;

  /// The selected track's own length, when it has one that applies.
  final int? trackLengthBars;

  /// The default record timing.
  final RecordTiming timing;

  /// The selected track's own record timing, when it has one.
  final RecordTiming? trackTiming;

  /// A take is recording or overdubbing, which holds both until it ends.
  final bool captureLocked;

  /// Both settings have loaded and can take an edit.
  final bool ready;

  /// Whether the length and record timing can be changed now.
  bool get editable => ready && !captureLocked;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'lengthBars': lengthBars,
    'trackLengthBars': trackLengthBars,
    'timing': timing.name,
    'trackTiming': trackTiming?.name,
    'captureLocked': captureLocked,
    'ready': ready,
  };

  @override
  List<Object?> get props => [
    lengthBars,
    trackLengthBars,
    timing,
    trackTiming,
    captureLocked,
    ready,
  ];
}

/// Which power face the 7" shows over its readout (pen 32).
enum ReadoutGoodbye {
  /// The live readout, no face.
  none,

  /// A slow save before a restart or shutdown, with its current step.
  saving,

  /// The console is off: the check ring and "Safe to switch off".
  safeToSwitchOff,

  /// The console is restarting into an update: the restart icon and
  /// "Restarting".
  restarting,

  /// A plain restart: the bare Plymouth field, on its way to the boot splash.
  blank,
}

/// Everything the 7" screen shows besides the waveform.
///
/// A value type on purpose: the main window pushes this only when it *changes*
/// (see `WaveformWindowService.pushReadout`), rather than riding the waveform's
/// per-frame timer, so `==` is what keeps the channel quiet while a loop plays
/// unchanged.
///
/// Both windows use the same build and payload schema. Missing fields receive
/// neutral defaults; unknown fields are ignored. This does not translate older
/// readout schemas or promise compatibility between different app versions.
class PerformanceReadout extends Equatable {
  /// Creates a [PerformanceReadout].
  const new({
    this.selected,
    this.tempoBpm = 0,
    this.hasTempo = false,
    this.tsNum = 4,
    this.tsDen = 4,
    this.mode = 'record',
    this.activeBank = 0,
    this.notice,
    this.goodbye = ReadoutGoodbye.none,
    this.savingStep,
    this.savingProgress = 0,
    this.brightness = 1,
    this.tempoFollow = TempoFollowState.free,
    this.clockOwnsTempo = false,
    this.loop = const ReadoutLoopSettings(),
    this.dimmed = false,
  });

  /// Rebuilds a readout from [map] as pushed across the window channel.
  factory fromMap(Map<Object?, Object?> map) {
    final selected = map['selected'];
    final tempoBpm = (map['tempoBpm'] as num? ?? 0).toDouble();
    return PerformanceReadout(
      selected: selected is Map<Object?, Object?>
          ? ReadoutTrack.fromMap(selected)
          : null,
      tempoBpm: tempoBpm,
      // An older main window never sends `hasTempo`; its own readout treated
      // "tempo > 0" as having one, so the fallback preserves that reading.
      hasTempo: map['hasTempo'] as bool? ?? tempoBpm > 0,
      tsNum: map['tsNum'] as int? ?? 4,
      tsDen: map['tsDen'] as int? ?? 4,
      mode: map['mode'] as String? ?? 'record',
      activeBank: map['activeBank'] as int? ?? 0,
      notice: ReadoutNotice.fromMap(map['notice']),
      goodbye: _goodbyeOf(map['goodbye']),
      savingStep: _stepOf(map['savingStep']),
      savingProgress: (map['savingProgress'] as num? ?? 0).toDouble(),
      brightness: (map['brightness'] as num? ?? 1).toDouble(),
      // An unknown token reads as busy, locked, as the engine's own
      // projection does: never claim a change is free when it may not be.
      tempoFollow: switch (map['tempoFollow']) {
        null => TempoFollowState.free,
        final Object token =>
          TempoFollowState.values.asNameMap()[token] ?? TempoFollowState.busy,
      },
      clockOwnsTempo: map['clockOwnsTempo'] == true,
      loop: ReadoutLoopSettings.fromMap(map['loop']),
      dimmed: map['dimmed'] == true,
    );
  }

  /// The cursor's track — what the small display follows. `null` only when
  /// the rig reports no tracks (a stopped engine).
  final ReadoutTrack? selected;

  /// Live tempo.
  final double tempoBpm;

  /// Whether a tempo grid exists at all (`TempoSource != none`). The readout
  /// shows `—` for the bpm figure on the tempo-free path rather than stating
  /// `0` over a grid that does not exist.
  final bool hasTempo;

  /// Time-signature numerator.
  final int tsNum;

  /// Time-signature denominator.
  final int tsDen;

  /// `InteractionMode.token` — what a track press means right now, shown as
  /// the current function in the footer.
  final String mode;

  /// `ControlState.activeBank` — which A/B pedal bank the footswitches
  /// address, shown beside the function.
  final int activeBank;

  /// The main screen's message, shown in a band over the readout's top
  /// margin; null when the top bar says nothing.
  final ReadoutNotice? notice;

  /// The power face. A missing key reads as none.
  final ReadoutGoodbye goodbye;

  /// The save's current step under [ReadoutGoodbye.saving]; null otherwise.
  final PowerStep? savingStep;

  /// The share of the save's steps finished, `0..1`, under
  /// [ReadoutGoodbye.saving].
  final double savingProgress;

  /// The software dim over the Track display window, `0..1` (`1` = none):
  /// its panel's brightness and idle dim when the panel cannot dim itself.
  final double brightness;

  /// What a tempo change does now (`LooperState.tempoFollow`): whether the
  /// readout's tempo and signature controls are free, retime the loops, or
  /// are locked and why.
  final TempoFollowState tempoFollow;

  /// An external MIDI clock sets the tempo, so the readout cannot.
  final bool clockOwnsTempo;

  /// The length and record timing of the next take.
  final ReadoutLoopSettings loop;

  /// The console is idle-dimmed: the touch that wakes it must press
  /// nothing on the readout.
  final bool dimmed;

  /// Channel-encodable form.
  Map<String, Object?> toMap() => {
    'selected': selected?.toMap(),
    'tempoBpm': tempoBpm,
    'hasTempo': hasTempo,
    'tsNum': tsNum,
    'tsDen': tsDen,
    'mode': mode,
    'activeBank': activeBank,
    'notice': notice?.toMap(),
    'goodbye': goodbye.name,
    'savingStep': savingStep?.name,
    'savingProgress': savingProgress,
    'brightness': brightness,
    'tempoFollow': tempoFollow.name,
    'clockOwnsTempo': clockOwnsTempo,
    'loop': loop.toMap(),
    'dimmed': dimmed,
  };

  @override
  List<Object?> get props => [
    selected,
    tempoBpm,
    hasTempo,
    tsNum,
    tsDen,
    mode,
    activeBank,
    notice,
    goodbye,
    savingStep,
    savingProgress,
    brightness,
    tempoFollow,
    clockOwnsTempo,
    loop,
    dimmed,
  ];
}

ReadoutGoodbye _goodbyeOf(Object? raw) =>
    ReadoutGoodbye.values.asNameMap()[raw] ?? ReadoutGoodbye.none;

PowerStep? _stepOf(Object? raw) => PowerStep.values.asNameMap()[raw];
