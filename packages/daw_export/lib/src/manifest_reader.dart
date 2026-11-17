import 'dart:convert';
import 'dart:io';

import 'package:daw_export/src/automation_thinning.dart';
import 'package:daw_export/src/daw_project.dart';
import 'package:daw_export/src/effect_text.dart';
import 'package:daw_export/src/event_log_reader.dart';
import 'package:daw_export/src/manifest_json.dart';
import 'package:daw_export/src/wav_info.dart';

/// Reads a finalized performance-recording capture directory's
/// `performance.json` (docs/formats/performance-manifest-format.md) and
/// `events.log` (docs/formats/performance-event-log-format.md) directly — no
/// import of `performance_repository`/`segno_engine`, matching this
/// package's own-input-model rule — into a [DawProject] whose clips
/// reference the capture's already-rendered lane stems (`stems/dry/` and
/// `stems/wet/`, listed in `stems/stems.json`, #1824) and per-lane loop
/// exports (`loops/`), and whose tracks carry automation lanes reconstructed
/// from the raw logged volume/mute gestures (part 10) only where the clip is
/// the unity-gain dry stem: the wet render already applies those gestures,
/// so automating them again would apply them twice.
abstract final class DawManifestReader {
  /// Reads `<captureDir>/performance.json` and returns the [DawProject] it
  /// describes, or `null` if the manifest is missing/unreadable/corrupt (a
  /// capture that never finalized, or was deleted out from under the
  /// caller) — mirrors this codebase's established "graceful no-op on a
  /// missing/corrupt sidecar" convention (`performance_repository`'s
  /// `recoverCapture`) rather than throwing.
  ///
  /// The capture's own persisted tempo wins (#281): the manifest's
  /// `disarmSnapshot.tempoBpm` — the value D6's tempo lock had actually
  /// settled on by the end of the take — falling back to
  /// `armSnapshot.tempoBpm` for a crash-salvaged capture that never got a
  /// disarm pass. Only when the manifest carries neither (a bundle written
  /// before the field existed, or a capture with no tempo set at all) does
  /// [tempoBpm] apply: the caller's best guess at a real tempo, or
  /// `0`/omitted for "unset". Every beat-time conversion this reader does
  /// (this method's own automation-lane calls below, and the returned
  /// [DawProject]) uses [kFallbackTempoBpm] as the last resort whenever the
  /// resolved tempo is non-positive, so an unset/legacy capture still
  /// exports a valid, non-degenerate `.als` at this feature's original
  /// fixed tempo — never at literal `0`.
  static DawProject? read(
    String captureDir, {
    double tempoBpm = kFallbackTempoBpm,
  }) {
    final manifestFile = File('$captureDir/performance.json');
    if (!manifestFile.existsSync()) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(manifestFile.readAsStringSync());
    } on FormatException {
      return null;
    }
    // Well-formed JSON that is not an object is just as unreadable as a
    // parse failure — an `as Map` cast here would throw a TypeError that
    // escapes callers guarding only for I/O errors (#640's stuck-Rendering
    // shape), instead of this method's documented graceful null.
    if (decoded is! Map<String, dynamic>) return null;
    final manifest = decoded;

    // The tempo the capture itself recorded beats the caller's [tempoBpm] —
    // by re-export time the live transport may have long moved on from the
    // tempo this take was actually played at (#281). Disarm's value is
    // authoritative (D6's lock only engages once grid content exists, so
    // only the disarm-time read is guaranteed to have seen it engage); the
    // arm-time copy covers crash salvage, which never gets a disarm pass.
    final capturedTempoBpm =
        _snapshotTempoBpm(manifest['disarmSnapshot']) ??
        _snapshotTempoBpm(manifest['armSnapshot']);
    final callerTempoBpm = tempoBpm > 0 ? tempoBpm : kFallbackTempoBpm;
    final effectiveTempoBpm = capturedTempoBpm ?? callerTempoBpm;

    final sampleRate = (manifest['sample_rate'] as num?)?.toInt() ?? 0;
    final captureFrames = (manifest['capture_frames'] as num?)?.toInt() ?? 0;
    if (sampleRate <= 0 || captureFrames <= 0) return null;

    final armTracks = tracksOf(manifest['armSnapshot']);
    final disarmTracks = tracksOf(manifest['disarmSnapshot']);

    // channel -> lane -> its loops: the clean take (pcmRef) and the loop as
    // it played (#1713: its heard image unless the lane played clean or the
    // image is missing, else the clean take). Arm first, then disarm
    // overwrites: disarm is the later pass (a track recorded fresh during
    // the session has no arm-time loop, and a lane settled at arm keeps its
    // arm-time loop unless disarm captured something newer).
    final loopsByChannel = <int, Map<int, _LaneLoops>>{};
    for (final t in [...armTracks, ...disarmTracks]) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final laneIndex = (laneJson['lane'] as num?)?.toInt();
        final clean = laneJson['pcmRef'] as String?;
        if (laneIndex == null || clean == null) continue;
        final heardRef = laneJson['heardPcmRef'] as String?;
        final heard =
            heardRef != null &&
                laneJson['source'] != 'clean' &&
                File('$captureDir/$heardRef').existsSync()
            ? heardRef
            : clean;
        final lenFrames = (laneJson['lenFrames'] as num?)?.toInt();
        loopsByChannel.putIfAbsent(channel, () => {})[laneIndex] = (
          clean: clean,
          heard: heard,
          frames: lenFrames != null && lenFrames > 0 ? lenFrames : null,
        );
      }
    }

    // Arm-time gains, mute and solo per lane: the state the logged gestures
    // start from (events.log is relative to arm). Solo is tracked across
    // channels, since a solo on one track silences the others. A lane's
    // mute is its own flag, and lane 0's falls back to the track's, as the
    // renderer reads them (perf_render.c).
    final soloedAtArm = <int>{};
    final trackGainAtArm = <int, double>{};
    final laneVolumeAtArm = <(int, int), double>{};
    final mutedAtArm = <(int, int)>{};
    for (final t in armTracks) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      if (t['solo'] as bool? ?? false) soloedAtArm.add(channel);
      final gain = (t['volume'] as num?)?.toDouble();
      if (gain != null) trackGainAtArm[channel] = gain;
      final trackMuted = t['muted'] as bool? ?? false;
      var laneZeroListed = false;
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final index = (laneJson['lane'] as num?)?.toInt();
        if (index == null) continue;
        final volume = (laneJson['volume'] as num?)?.toDouble();
        if (volume != null) laneVolumeAtArm[(channel, index)] = volume;
        final muted = laneJson['muted'] as bool?;
        if (index == 0) laneZeroListed = true;
        if (muted ?? (index == 0 && trackMuted)) {
          mutedAtArm.add((channel, index));
        }
      }
      if (!laneZeroListed && trackMuted) mutedAtArm.add((channel, 0));
    }

    final logEntries = EventLogReader.readAll(captureDir);
    final stems = _laneStems(captureDir);

    // Each looper track is a Group of its lanes (#1824): per lane its dry
    // stem with its clean loop, which plays, and its wet stem with its loop
    // as heard, a reference, off. A lane with no dry stem plays its wet one.
    final tracks = <DawTrack>[];
    final channels = {...loopsByChannel.keys, ...stems.keys}.toList()..sort();
    for (final channel in channels) {
      final name = trackNameOf(manifest, channel);
      final group = DawGroup(
        name: name,
        info: _info(EffectText.trackStage(manifest, channel)),
      );
      final loops = loopsByChannel[channel] ?? const {};
      final rendered = stems[channel] ?? const {};
      final lanes = {...loops.keys, ...rendered.keys}.toList()..sort();
      for (final lane in lanes) {
        DawClip? stem(String? file) {
          if (file == null) return null;
          final audio = _audioFile(
            captureDir,
            file,
            sampleRate: sampleRate,
            fallbackFrames: captureFrames,
          );
          return audio == null ? null : DawClip(audio: audio, startSeconds: 0);
        }

        DawAudioFile? loop(String? file) => file == null
            ? null
            : _audioFile(
                captureDir,
                file,
                sampleRate: sampleRate,
                fallbackFrames: loops[lane]?.frames,
              );

        final dry = stem(rendered[lane]?.dry);
        final wet = stem(rendered[lane]?.wet);
        final clean = loop(loops[lane]?.clean);
        final heard = loop(loops[lane]?.heard);
        if (dry == null && wet == null && clean == null) continue;
        final label = '$name L${lane + 1}';
        final info = _info(EffectText.lane(manifest, channel, lane));
        if (dry != null || wet == null) {
          // The dry stem plays at unity, so its track carries the logged
          // volume and mute as volume automation: off while not audible.
          // The wet render already applies them, so the wet track carries
          // none.
          final volume = dry == null || logEntries == null
              ? null
              : _dryVolume(
                  EventLogReader.readChannelAutomation(
                    logEntries,
                    channel,
                    sampleRate,
                    effectiveTempoBpm,
                    lane: lane,
                    initialTrackGain: trackGainAtArm[channel] ?? 1,
                    initialLaneVolume: laneVolumeAtArm[(channel, lane)] ?? 1,
                    initiallyMuted: mutedAtArm.contains((channel, lane)),
                    initiallySoloed: soloedAtArm,
                  ),
                  effectiveTempoBpm,
                );
          tracks.add(
            DawTrack(
              name: label,
              group: group,
              arrangementClips: [?dry],
              loop: clean,
              volume: volume,
              info: info,
            ),
          );
        }
        if (wet != null) {
          tracks.add(
            DawTrack(
              name: '$label (as heard)',
              kind: DawTrackKind.laneHeard,
              group: group,
              active: dry == null,
              arrangementClips: [wet],
              loop: heard,
              info: info,
            ),
          );
        }
      }
    }

    // Each input, beside the loops. Since #1805 the engine records every
    // input raw (its clean sample, before its monitor chain, gate, volume
    // and pan), which plays, and each monitored one also as heard (after
    // them, silent while its monitor is off), a reference, off. A take from
    // before it has only the inputs as heard, which play. Then the captured
    // output, which holds both loops and inputs: a reference, off.
    final parts = _partsByStream(captureDir, manifest, sampleRate);
    final recordedRaw = rawInputsOf(manifest).toSet();
    final inputs = {...capturedInputsOf(manifest), ...recordedRaw}.toList()
      ..sort();
    for (final input in inputs) {
      final name = inputNameOf(manifest, input);
      final effects = _info(EffectText.input(manifest, input));
      final heard = parts[1 + input];
      final raw = recordedRaw.contains(input)
          ? parts[kRawStreamBase + input]
          : null;
      if (raw != null) {
        tracks.add(
          DawTrack(
            name: '$name raw',
            kind: DawTrackKind.input,
            arrangementClips: raw,
            info:
                'The input as played: before its effects, volume and pan.\n'
                '$effects',
          ),
        );
      }
      if (heard == null) continue;
      tracks.add(
        DawTrack(
          name: raw == null ? name : '$name (as heard)',
          kind: raw == null ? DawTrackKind.input : DawTrackKind.inputHeard,
          active: raw == null,
          arrangementClips: heard,
          info:
              'The input as heard: after its effects, volume and pan.\n'
              '$effects',
        ),
      );
    }
    final master = parts[0];
    if (master != null) {
      tracks.add(
        DawTrack(
          name: kMasterTrackName,
          kind: DawTrackKind.master,
          active: false,
          arrangementClips: master,
          info: _info(EffectText.output(manifest)),
        ),
      );
    }

    return DawProject(tracks: tracks, tempoBpm: effectiveTempoBpm);
  }

  /// The `tempoBpm` a snapshot map carries, or `null` when [snapshot] is
  /// absent or not a map, the key is absent (a bundle written before #281),
  /// or the value is non-positive — the engine's own 0-as-unset sentinel,
  /// stored verbatim by `performance_repository` (session-manifest parity).
  /// All the `null` cases mean the same thing to [read]: no tempo evidence
  /// here, keep falling through.
  static double? _snapshotTempoBpm(Object? snapshot) {
    if (snapshot is! Map<String, dynamic>) return null;
    final bpm = (snapshot['tempoBpm'] as num?)?.toDouble();
    return bpm != null && bpm > 0 ? bpm : null;
  }

  /// The lane stems `stems/stems.json` lists (#1824), by channel and lane;
  /// empty when the render wrote none or the index does not read.
  static Map<int, Map<int, ({String? dry, String? wet})>> _laneStems(
    String captureDir,
  ) {
    final file = File('$captureDir/stems/stems.json');
    if (!file.existsSync()) return const {};
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      return const {};
    }
    final lanes = decoded is Map<String, dynamic> ? decoded['lanes'] : null;
    final stems = <int, Map<int, ({String? dry, String? wet})>>{};
    for (final entry in lanes is List ? lanes : const []) {
      if (entry case {'channel': final int channel, 'lane': final int lane}) {
        final dry = entry['dry'];
        final wet = entry['wet'];
        stems.putIfAbsent(channel, () => {})[lane] = (
          dry: dry is String ? dry : null,
          wet: wet is String ? wet : null,
        );
      }
    }
    return stems;
  }

  /// The info text for a track whose effects are [effects].
  static String _info(String? effects) => effects == null
      ? 'No effects were recorded when the take started.'
      : 'Effects when the take started:\n$effects';

  /// The dry track's volume: [raw]'s gain times its audibility, so a mute
  /// is a step to silence and back. Two breakpoints at a toggle's beat make
  /// the step. `null` when it stays at unity throughout.
  static AutomationLane? _dryVolume(
    ({
      double initialVolume,
      List<AutomationBreakpoint> volume,
      double initialAudible,
      List<AutomationBreakpoint> mute,
    })
    raw,
    double tempoBpm,
  ) {
    final initial = raw.initialVolume * raw.initialAudible;
    if (raw.volume.isEmpty && raw.mute.isEmpty) {
      return initial == 1
          ? null
          : AutomationLane(
              initialValue: initial,
              breakpoints: [AutomationBreakpoint(beat: 0, value: initial)],
            );
    }
    final ride = raw.volume.isEmpty
        ? const <AutomationBreakpoint>[]
        : thinVolumeAutomation(raw: raw.volume, tempoBpm: tempoBpm);
    final breakpoints = <AutomationBreakpoint>[];
    var audible = raw.initialAudible;
    var ri = 0;
    var mi = 0;
    while (ri < ride.length || mi < raw.mute.length) {
      if (mi == raw.mute.length ||
          (ri < ride.length && ride[ri].beat < raw.mute[mi].beat)) {
        final point = ride[ri++];
        breakpoints.add(
          AutomationBreakpoint(beat: point.beat, value: point.value * audible),
        );
        continue;
      }
      // The ride's value at the toggle, as Live interpolates it: between
      // the ride point before it (or the value at arm) and the next one.
      final toggle = raw.mute[mi++];
      final (fromBeat, from) = ri == 0
          ? (0.0, raw.initialVolume)
          : (ride[ri - 1].beat, ride[ri - 1].value);
      final gain = ri == ride.length || ride[ri].beat == fromBeat
          ? (ri == ride.length ? from : ride[ri].value)
          : from +
                (ride[ri].value - from) *
                    (toggle.beat - fromBeat) /
                    (ride[ri].beat - fromBeat);
      breakpoints.add(
        AutomationBreakpoint(beat: toggle.beat, value: gain * audible),
      );
      audible = toggle.value;
      breakpoints.add(
        AutomationBreakpoint(beat: toggle.beat, value: gain * audible),
      );
    }
    return AutomationLane(initialValue: initial, breakpoints: breakpoints);
  }

  /// Each captured stream's audio as Arrangement clips, one per part file
  /// placed where the previous ones end: stream 0 is the master, `1 + n`
  /// input `n` as heard, [kRawStreamBase] `+ n` input `n` raw. Read from
  /// the sidecar's `parts` (#1198), or for a take finalized before them,
  /// its single `master.wav` and `live-input-<n>.wav`.
  static Map<int, List<DawClip>> _partsByStream(
    String captureDir,
    Map<String, dynamic> manifest,
    int sampleRate,
  ) {
    final byStream = <int, List<(int, String, int)>>{};
    final listed = manifest['parts'];
    if (listed is List) {
      for (final part in listed.whereType<Map<String, dynamic>>()) {
        final stream = part['stream'];
        final index = part['index'];
        final file = part['file'];
        if (stream is! num || index is! num || file is! String) continue;
        byStream.putIfAbsent(stream.toInt(), () => []).add((
          index.toInt(),
          file,
          (part['frames'] as num?)?.toInt() ?? 0,
        ));
      }
    } else {
      final frames = (manifest['capture_frames'] as num?)?.toInt() ?? 0;
      byStream[0] = [(1, 'master.wav', frames)];
      for (final input in capturedInputsOf(manifest)) {
        byStream[1 + input] = [(1, 'live-input-$input.wav', frames)];
      }
    }
    final clips = <int, List<DawClip>>{};
    for (final MapEntry(key: stream, value: files) in byStream.entries) {
      files.sort((a, b) => a.$1.compareTo(b.$1));
      var start = 0.0;
      final list = <DawClip>[];
      for (final (_, file, frames) in files) {
        final audio = _audioFile(
          captureDir,
          file,
          sampleRate: sampleRate,
          fallbackFrames: frames,
        );
        // A missing part leaves a gap rather than shifting what follows; one
        // whose length is unknown too ends the stream there, since nothing
        // after it could be placed.
        if (audio == null && frames <= 0) break;
        if (audio != null) list.add(DawClip(audio: audio, startSeconds: start));
        start += (audio?.frames ?? frames) / (audio?.sampleRate ?? sampleRate);
      }
      if (list.isNotEmpty) clips[stream] = list;
    }
    return clips;
  }

  /// [relative]'s [DawAudioFile]: its rate and length from its WAV
  /// header, or, when the header does not read, [sampleRate] and
  /// [fallbackFrames] from the manifest. `null` when the file is missing,
  /// or unreadable with no manifest length to fall back on.
  static DawAudioFile? _audioFile(
    String captureDir,
    String relative, {
    required int sampleRate,
    int? fallbackFrames,
  }) {
    final path = '$captureDir/$relative';
    if (!File(path).existsSync()) return null;
    final info = readWavInfo(path);
    if (info != null && info.frames > 0) {
      return DawAudioFile(
        fileRef: relative,
        sampleRate: info.sampleRate,
        frames: info.frames,
      );
    }
    if (fallbackFrames == null || fallbackFrames <= 0) return null;
    return DawAudioFile(
      fileRef: relative,
      sampleRate: sampleRate,
      frames: fallbackFrames,
    );
  }
}

/// One lane's loops in `loops/`: its clean take, the loop as it played, and
/// the manifest's length for them, if it has one.
typedef _LaneLoops = ({String clean, String heard, int? frames});
