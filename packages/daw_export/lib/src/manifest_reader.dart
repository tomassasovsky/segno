import 'dart:convert';
import 'dart:io';

import 'package:daw_export/src/automation_thinning.dart';
import 'package:daw_export/src/daw_project.dart';
import 'package:daw_export/src/device_chain_resolver.dart';
import 'package:daw_export/src/event_log_reader.dart';
import 'package:daw_export/src/manifest_json.dart';

/// Reads a finalized performance-recording capture directory's
/// `performance.json` (docs/design/performance-manifest-format.md) and
/// `events.log` (docs/design/performance-event-log-format.md) directly — no
/// import of `performance_repository`/`segno_engine`, matching this
/// package's own-input-model rule — into a [DawProject] whose clips
/// reference the capture's already-rendered stems (`stems/wet/`, falling
/// back to `stems/dry/` for a channel whose wet render failed or hasn't run)
/// and per-lane loop exports (`loops/`), and whose tracks carry automation
/// lanes reconstructed from the raw logged volume/mute gestures (part 10).
///
/// Part 10 additionally resolves each channel's real Segno VST3 device
/// chain from its captured lanes' `armSnapshot`-only `effects`
/// ([resolveDeviceChain], D-CHAIN-SOURCE) and, when a non-empty chain
/// resolves, prefers the `stems/dry/` stem over `stems/wet/` for that
/// channel's arrangement clip (D-WETDRY) — falling all the way back to
/// today's wet-preferred, no-device-chain behavior if the dry stem is
/// unexpectedly missing, never risking a silent double-application of
/// effects.
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
    final captureSeconds = captureFrames / sampleRate;

    final armTracks = tracksOf(manifest['armSnapshot']);
    final disarmTracks = tracksOf(manifest['disarmSnapshot']);

    // channel -> (lane -> pcmRef). Built from arm first, then disarm
    // overwrites — disarm is the later, fresher pass (a track recorded
    // fresh during the session has no arm-time entry at all, and a track
    // that was already settled at arm keeps its arm-time entry unless
    // disarm captured something newer for the same lane).
    final pcmRefsByChannel = <int, Map<int, String>>{};
    for (final t in [...armTracks, ...disarmTracks]) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      final laneMap = pcmRefsByChannel.putIfAbsent(channel, () => {});
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final laneIndex = (laneJson['lane'] as num?)?.toInt();
        final pcmRef = laneJson['pcmRef'] as String?;
        if (laneIndex == null || pcmRef == null) continue;
        laneMap[laneIndex] = pcmRef;
      }
    }

    // channel -> (lane -> raw effects[] entries), armSnapshot ONLY
    // (D-CHAIN-SOURCE — a disarmSnapshot lane entry never carries `effects`,
    // matching the already-shipped `fx_chains.dart` precedent). A lane with
    // no arm-time entry at all (recorded fresh during the performance, only
    // ever appearing in disarmSnapshot) has no evidence of any effects, so
    // it defaults to an empty chain below — the same honest "nothing to
    // report" default `resolveDeviceChain` already uses for a lane with an
    // arm-time entry but no `effects` key.
    final effectsByChannel = <int, Map<int, List<Map<String, dynamic>>>>{};
    for (final t in armTracks) {
      final channel = (t['channel'] as num?)?.toInt();
      if (channel == null) continue;
      final laneMap = effectsByChannel.putIfAbsent(channel, () => {});
      for (final lane in (t['lanes'] as List<dynamic>? ?? const [])) {
        final laneJson = lane as Map<String, dynamic>;
        final laneIndex = (laneJson['lane'] as num?)?.toInt();
        if (laneIndex == null) continue;
        final effects = laneJson['effects'] as List<dynamic>?;
        laneMap[laneIndex] = effects == null
            ? const []
            : [for (final e in effects) e as Map<String, dynamic>];
      }
    }

    final logEntries = EventLogReader.readAll(captureDir);

    final tracks = <DawTrack>[];
    for (final channel in pcmRefsByChannel.keys.toList()..sort()) {
      final sessionClips = <DawSessionClip>[];
      final lanes = pcmRefsByChannel[channel]!;
      for (final lane in lanes.keys.toList()..sort()) {
        final pcmRef = lanes[lane]!;
        if (!File('$captureDir/$pcmRef').existsSync()) continue;
        sessionClips.add(
          DawSessionClip(
            laneIndex: lane,
            fileRef: pcmRef,
            // The per-lane loop's own length isn't recorded in the
            // manifest at the top level (only the full capture's is) — a
            // fixed reference to the capture length is a placeholder until
            // part 11 threads the lane's actual settled length through;
            // documented as a known simplification, not a silent guess.
            lengthSeconds: captureSeconds,
          ),
        );
      }

      final resolution = resolveDeviceChain([
        for (final laneIndex in lanes.keys.toList()..sort())
          effectsByChannel[channel]?[laneIndex] ??
              const <Map<String, dynamic>>[],
      ]);
      // A device chain is only actually emitted for a NON-EMPTY chain
      // (als_builder.dart) — an empty resolved chain (a channel with no
      // effects on any lane) has nothing to double-apply, so it keeps
      // today's wet-preferred stem choice unchanged rather than switching
      // preference for no reason.
      var deviceChain = resolution.chain;
      final deviceChainFallbackReason = resolution.fallbackReason;
      String? arrangementFile;
      if (deviceChain != null && deviceChain.isNotEmpty) {
        final dryRef = 'stems/dry/track$channel.wav';
        if (File('$captureDir/$dryRef').existsSync()) {
          arrangementFile = dryRef;
        } else {
          // D-WETDRY: the dry stem this resolved chain needs is
          // unexpectedly missing — treat the whole channel exactly as if
          // resolution had failed rather than risk silently double-applying
          // effects (once baked into the wet render, once via the live
          // device chain). deviceChainFallbackReason intentionally stays
          // whatever resolveDeviceChain returned (null, since resolution
          // itself succeeded) — this is a data-availability gap, not a
          // chain-representability failure, and the umbrella's fallback
          // reasons cover only the latter.
          deviceChain = null;
          arrangementFile = _firstExisting(captureDir, [
            'stems/wet/track$channel.wav',
            'stems/dry/track$channel.wav',
          ]);
        }
      } else {
        arrangementFile = _firstExisting(captureDir, [
          'stems/wet/track$channel.wav',
          'stems/dry/track$channel.wav',
        ]);
      }

      if (arrangementFile == null && sessionClips.isEmpty) continue;

      final automationLanes = <AutomationLane>[];
      if (logEntries != null) {
        final raw = EventLogReader.readChannelAutomation(
          logEntries,
          channel,
          sampleRate,
          effectiveTempoBpm,
        );
        if (raw.volume.isNotEmpty) {
          automationLanes.add(
            AutomationLane(
              target: AutomationTarget.volume,
              breakpoints: thinVolumeAutomation(
                raw: raw.volume,
                tempoBpm: effectiveTempoBpm,
              ),
            ),
          );
        }
        if (raw.mute.isNotEmpty) {
          // Mute is step-shaped, never thinned — see AutomationTarget.
          // activator's own doc.
          automationLanes.add(
            AutomationLane(
              target: AutomationTarget.activator,
              breakpoints: raw.mute,
            ),
          );
        }
      }

      tracks.add(
        DawTrack(
          name: 'Track $channel',
          arrangementClip: arrangementFile == null
              ? null
              : DawClip(
                  fileRef: arrangementFile,
                  startSeconds: 0,
                  lengthSeconds: captureSeconds,
                ),
          sessionClips: sessionClips,
          automationLanes: automationLanes,
          deviceChain: deviceChain,
          deviceChainFallbackReason: deviceChainFallbackReason,
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

  static String? _firstExisting(String captureDir, List<String> candidates) {
    for (final relative in candidates) {
      if (File('$captureDir/$relative').existsSync()) return relative;
    }
    return null;
  }
}
