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
/// reference the capture's already-rendered stems (`stems/wet/`, falling
/// back to `stems/dry/` for a channel whose wet render failed or hasn't run)
/// and per-lane loop exports (`loops/`), and whose tracks carry automation
/// lanes reconstructed from the raw logged volume/mute gestures (part 10)
/// only where the clip is the unity-gain dry stem: the wet render already
/// applies those gestures, so automating them again would apply them twice.
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

    // channel -> (lane -> heardPcmRef or pcmRef). Built from arm first,
    // then disarm overwrites — disarm is the later, fresher pass (a track
    // recorded fresh during the session has no arm-time entry at all, and a
    // track that was already settled at arm keeps its arm-time entry unless
    // disarm captured something newer for the same lane).
    final pcmRefsByChannel = <int, Map<int, String>>{};
    final laneFramesByChannel = <int, Map<int, int>>{};
    for (final t in [...armTracks, ...disarmTracks]) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      final laneMap = pcmRefsByChannel.putIfAbsent(channel, () => {});
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final laneIndex = (laneJson['lane'] as num?)?.toInt();
        // A take's heard image (#1713) is what it played as, so its clip
        // carries that unless the lane played clean (its effects edited) or
        // the image is missing; otherwise the clean loop.
        final heardRef = laneJson['heardPcmRef'] as String?;
        final pcmRef =
            heardRef != null &&
                laneJson['source'] != 'clean' &&
                File('$captureDir/$heardRef').existsSync()
            ? heardRef
            : laneJson['pcmRef'] as String?;
        if (laneIndex == null || pcmRef == null) continue;
        laneMap[laneIndex] = pcmRef;
        final lenFrames = (laneJson['lenFrames'] as num?)?.toInt();
        if (lenFrames != null && lenFrames > 0) {
          laneFramesByChannel.putIfAbsent(channel, () => {})[laneIndex] =
              lenFrames;
        }
      }
    }

    // Arm-time gains, mute and solo per channel: the state the logged
    // gestures start from (events.log is relative to arm). Solo is tracked
    // across channels, since a solo on one track silences the others.
    // Mute is lane 0's flag, or the track's when lane 0 has none, as the
    // renderer reads it (perf_render.c).
    final mutedAtArm = <int>{};
    final soloedAtArm = <int>{};
    final trackGainAtArm = <int, double>{};
    final laneVolumeAtArm = <int, double>{};
    for (final t in armTracks) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      if (t['solo'] as bool? ?? false) soloedAtArm.add(channel);
      final gain = (t['volume'] as num?)?.toDouble();
      if (gain != null) trackGainAtArm[channel] = gain;
      bool? laneMuted;
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        if ((laneJson['lane'] as num?)?.toInt() != 0) continue;
        final volume = (laneJson['volume'] as num?)?.toDouble();
        if (volume != null) laneVolumeAtArm[channel] = volume;
        laneMuted = laneJson['muted'] as bool?;
      }
      if (laneMuted ?? t['muted'] as bool? ?? false) mutedAtArm.add(channel);
    }

    final logEntries = EventLogReader.readAll(captureDir);

    final tracks = <DawTrack>[];
    for (final channel in pcmRefsByChannel.keys.toList()..sort()) {
      final sessionClips = <DawSessionClip>[];
      final lanes = pcmRefsByChannel[channel]!;
      for (final lane in lanes.keys.toList()..sort()) {
        final pcmRef = lanes[lane]!;
        final audio = _audioFile(
          captureDir,
          pcmRef,
          sampleRate: sampleRate,
          fallbackFrames: laneFramesByChannel[channel]?[lane],
        );
        if (audio == null) continue;
        sessionClips.add(DawSessionClip(laneIndex: lane, audio: audio));
      }

      DawClip? stem(String kind) {
        final audio = _audioFile(
          captureDir,
          'stems/$kind/track$channel.wav',
          sampleRate: sampleRate,
          fallbackFrames: captureFrames,
        );
        return audio == null ? null : DawClip(audio: audio, startSeconds: 0);
      }

      final wet = stem('wet');
      final dry = stem('dry');
      if (wet == null && dry == null && sessionClips.isEmpty) continue;

      // The dry stem plays at unity, so its track carries the logged volume
      // and mute as volume automation: off while not audible. The wet render
      // already applies them (perf_render.c's wet pass), so the wet track
      // carries none.
      final volume = dry == null || logEntries == null
          ? null
          : _dryVolume(
              EventLogReader.readChannelAutomation(
                logEntries,
                channel,
                sampleRate,
                effectiveTempoBpm,
                initialTrackGain: trackGainAtArm[channel] ?? 1,
                initialLaneVolume: laneVolumeAtArm[channel] ?? 1,
                initiallyMuted: mutedAtArm.contains(channel),
                initiallySoloed: soloedAtArm,
              ),
              effectiveTempoBpm,
            );
      final name = trackNameOf(manifest, channel);
      final info = _info(EffectText.track(manifest, channel));
      if (wet != null) {
        tracks.add(
          DawTrack(
            name: name,
            arrangementClips: [wet],
            sessionClips: sessionClips,
            info: info,
          ),
        );
        if (dry != null) {
          // The same take before its effects, for processing again: off, so
          // the set does not play it on top of the wet stem.
          tracks.add(
            DawTrack(
              name: '$name dry',
              active: false,
              arrangementClips: [dry],
              volume: volume,
              info: info,
            ),
          );
        }
      } else {
        tracks.add(
          DawTrack(
            name: name,
            arrangementClips: [?dry],
            sessionClips: sessionClips,
            volume: volume,
            info: info,
          ),
        );
      }
    }

    // Each captured input as the player heard it: the engine records an
    // input after its monitor chain, volume and pan (mix_monitors_frame,
    // silent while its monitor is off), so it plays beside the loops. Then
    // the captured output, which holds both: a reference, off.
    final parts = _partsByStream(captureDir, manifest, sampleRate);
    final layout = manifest['channel_layout'];
    final inputs = [
      if (layout is Map<String, dynamic> && layout['captured_inputs'] is List)
        for (final i in layout['captured_inputs'] as List)
          if (i is num) i.toInt(),
    ]..sort();
    for (final input in inputs) {
      final clips = parts[1 + input];
      if (clips == null) continue;
      tracks.add(
        DawTrack(
          name: inputNameOf(manifest, input),
          arrangementClips: clips,
          info:
              'The input as heard: after its effects, volume and pan.\n'
              '${_info(EffectText.input(manifest, input))}',
        ),
      );
    }
    final master = parts[0];
    if (master != null) {
      tracks.add(
        DawTrack(
          name: kMasterTrackName,
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
    // The ride's value at [beat], as Live interpolates it.
    double gainAt(double beat) {
      var before = raw.initialVolume;
      var beforeBeat = 0.0;
      for (final point in ride) {
        if (point.beat >= beat) {
          if (point.beat == beforeBeat) return point.value;
          final t = (beat - beforeBeat) / (point.beat - beforeBeat);
          return before + (point.value - before) * t;
        }
        before = point.value;
        beforeBeat = point.beat;
      }
      return before;
    }

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
      final toggle = raw.mute[mi++];
      final gain = gainAt(toggle.beat);
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
  /// input `n`. Read from the sidecar's `parts` (#1198), or for a take
  /// finalized before them, its single `master.wav` and
  /// `live-input-<n>.wav`.
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
      final layout = manifest['channel_layout'];
      if (layout is Map<String, dynamic> && layout['captured_inputs'] is List) {
        for (final input in layout['captured_inputs'] as List) {
          if (input is! num) continue;
          byStream[1 + input.toInt()] = [
            (1, 'live-input-${input.toInt()}.wav', frames),
          ];
        }
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
        // A missing part leaves a gap rather than shifting what follows.
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
