import 'package:looper_repository/looper_repository.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/model/one_shot.dart';
import 'package:segno/looper/model/overdub_decay.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_start.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:session_repository/session_repository.dart';
import 'package:settings_repository/settings_repository.dart';

/// Bloc-layer mapping between the session bundle (data) and the looper
/// repository (domain) — the two never depend on each other, so the
/// translation lives here, above both. Shared by `SessionCubit` and the
/// end-to-end round-trip test so the mapping has a single definition.
///
/// This is also where the FX chain ENVELOPE (R13/R15) crosses the boundary:
/// `looper_repository` owns the codec, `session_repository` only ever sees the
/// resulting opaque string, so the encode/decode calls all live here.

/// Gathers the live chains of all four FX stages from [looper] into the
/// manifest models a save persists. The rig — not settings — is the truth being
/// saved, so chains are read straight from the repository. Chains encode with
/// the same envelope format settings use, so a saved chain round-trips exactly:
/// entries, per-slot enabled bits, stable slot ids, the chain-enabled flag, and
/// (for the Loop stage) inheritance provenance.
SessionChains chainsFromLooper(
  LooperRepository looper, {
  required FxChainPersistence projection,
  MixSettingsSnapshot? mix,
}) => SessionChains(
  laneChains: [
    for (final entry in looper.allLaneChains().entries)
      SessionLaneChain(
        channel: entry.key.$1,
        lane: entry.key.$2,
        encoded: encodeFxChain(
          projection.project(
            FxAddress(
              stage: FxStage.loop,
              index: entry.key.$1,
              lane: entry.key.$2,
            ),
            entry.value,
          ),
        ),
      ),
  ],
  monitors: [
    // Every CONFIGURED monitor, not just inputs carrying an FX chain — a
    // dry-but-enabled monitor must round-trip too, or it would be dropped on
    // save and disabled on the next load.
    for (final monitor in looper.allMonitors().values)
      SessionMonitor(
        input: monitor.input,
        mode: monitor.mode.name,
        outputMask: monitor.outputMask,
        volume: mix?.monitorLevels[monitor.input] ?? monitor.volume,
        muted: monitor.muted,
        // No pan: on load the monitors' pans are rebuilt from the session's
        // input setup (`loopSettingsFromLooper`), which is what produced
        // them, so a written copy would never be read back.
        encoded: encodeFxChain(
          projection.project(
            FxAddress(stage: FxStage.input, index: monitor.input),
            FxChainEnvelope(
              chainEnabled: monitor.chainEnabled,
              entries: monitor.effects,
            ),
          ),
        ),
      ),
  ],
  // The bus stages. All go through the same envelope codec as the stages
  // above; the output chains are keyed by destination (manifest v9).
  trackChains: [
    for (final entry in looper.allTrackChains().entries)
      SessionTrackChain(
        channel: entry.key,
        encoded: encodeFxChain(
          projection.project(
            FxAddress(stage: FxStage.track, index: entry.key),
            entry.value,
          ),
        ),
      ),
  ],
  outputChains: [
    for (final entry in looper.allOutputChains().entries)
      SessionOutputChain(
        bus: entry.key,
        encoded: encodeFxChain(
          projection.project(
            FxAddress(stage: FxStage.output, index: entry.key),
            entry.value,
          ),
        ),
      ),
  ],
  allTracksChain: _encodedAllTracksChain(looper, projection: projection),
);

/// Captures repository-owned settings without depending on an engine report.
SessionSettings settingsFromLooper(
  LooperRepository looper, {
  required double clickVolume,
  required ClickMode clickMode,
  required RecordStartSettings recordStart,
  required DecaySnapshot decay,
  required OneShotSnapshot oneShot,
  required RecordLengthSnapshot recordLength,
  required RecordTimingSnapshot recordTiming,
  required FadeDurations fade,
  MixSettingsSnapshot? mix,
}) {
  final transport = looper.sessionTransport;
  final snapshot = mix ?? looper.mixSettingsSnapshot;
  return SessionSettings(
    tempoBpm: transport.tempoBpm,
    tempoSource: transport.tempoSource,
    tsNum: transport.tsNum,
    tsDen: transport.tsDen,
    syncTempo: transport.syncTempo,
    quantizeDiv: recordTiming.rememberedDivision,
    loopBars: transport.loopBars,
    loopBeats: transport.loopBeats > 0 || transport.loopBars == 0
        ? transport.loopBeats
        : transport.loopBars * transport.tsNum,
    recordTiming: recordTiming.defaultTiming,
    overdubDecay: decay.defaultPercent,
    defaultOneShot: oneShot.defaultOneShot,
    defaultFadeDurationMs: fade.defaultMs,
    trackFadeDurationOverrides: fade.overrides,
    defaultLengthPresetBars: recordLength.defaultBars,
    trackRecordTimingOverrides: recordTiming.trackOverrides,
    trackOverdubDecayOverrides: decay.trackOverrides,
    trackOneShotOverrides: oneShot.trackOverrides,
    trackLengthPresetOverrides: recordLength.trackOverrides,
    trackLevels: snapshot.trackLevels,
    trackPans: snapshot.trackPans,
    laneInputs: snapshot.laneInputs,
    laneOutputs: snapshot.laneOutputs,
    laneCounts: snapshot.laneCounts,
    laneMix: {
      for (final track in looper.state.tracks)
        for (var lane = 0; lane < track.lanes.length; lane++)
          (track.channel, lane): (
            level:
                snapshot.laneLevels[(track.channel, lane)] ??
                track.lanes[lane].volume,
            imagePan: track.lanes[lane].imagePan,
            balance: track.lanes[lane].balance,
          ),
    },
    inputSetup: SessionInputSetup(
      trimDb: snapshot.inputSetup.trimDb,
      pan: snapshot.inputSetup.pan,
      pairs: snapshot.inputSetup.pairs,
    ),
    outputSetup: _sessionOutputSetup(snapshot.outputSetup),
    clickMode: clickMode,
    clickMask: transport.clickMask,
    clickVolume: clickVolume,
    countInBars: recordStart.countInBars,
    recDub: transport.recDub,
    autoRecord: recordStart.soundStart,
    defaultMultiple: transport.defaultMultiple,
    looperMode: transport.looperMode,
    primaryTrack: transport.primaryTrack,
  );
}

/// The manifest form of the looper domain's [setup].
SessionOutputSetup _sessionOutputSetup(OutputSetup setup) {
  final maps = setup.toMaps();
  return SessionOutputSetup(
    level: maps.level,
    muted: maps.muted,
    mono: maps.mono,
    balance: maps.balance,
  );
}

/// The looper-domain output setup of a manifest's [setup]: one [OutputBus]
/// per destination any of its four maps names.
OutputSetup outputSetupFromSession(SessionOutputSetup setup) =>
    OutputSetup.fromMaps(
      level: setup.level,
      muted: setup.muted,
      mono: setup.mono,
      balance: setup.balance,
    );

/// The All tracks recorded-mix chain as an envelope string, or the manifest's
/// own "no chain" spelling (`''`) when the rig has no All tracks state at all
/// — so a default rig does not persist a redundant envelope, and the manifest
/// has ONE way to say "empty". Both spellings decode to the same empty enabled
/// envelope, and both reset a leftover chain on load.
String _encodedAllTracksChain(
  LooperRepository looper, {
  FxChainPersistence? projection,
}) {
  final live = looper.allTracksChainEnvelope();
  final chain =
      projection?.project(const FxAddress(stage: FxStage.allTracks), live) ??
      live;
  return chain == const FxChainEnvelope() ? '' : encodeFxChain(chain);
}

/// Gathers the same live chains into the models a
/// performance-capture arm snapshot records, plus the master-limiter state the
/// engine snapshot cannot read back. The rig — not settings — is the truth
/// being captured, exactly as in [chainsFromLooper]; the manifest keeps effects
/// structured (canonical JSON `daw_export` reads directly) rather than encoded,
/// so the chains cross the boundary as engine models — with each stage's
/// chain-enabled flag alongside, since a bypassed chain must replay bypassed
/// (R3).
PerformanceChains performanceChainsFromLooper(LooperRepository looper) {
  return PerformanceChains(
    laneChains: [
      for (final entry in looper.allLaneChains().entries)
        PerformanceLaneChain(
          channel: entry.key.$1,
          lane: entry.key.$2,
          effects: trackEffectsToEngine(entry.value.entries),
          chainEnabled: entry.value.chainEnabled,
        ),
    ],
    monitors: [
      // Every CONFIGURED monitor, not just inputs carrying an FX chain —
      // same rule as [chainsFromLooper]: a dry-but-enabled monitor is part of
      // the rig the capture is documenting.
      for (final monitor in looper.allMonitors().values)
        PerformanceMonitorState(
          input: monitor.input,
          enabled: monitor.mode != MonitorMode.off,
          outputMask: monitor.outputMask,
          volume: monitor.volume,
          muted: monitor.muted,
          effects: trackEffectsToEngine(monitor.effects),
          chainEnabled: monitor.chainEnabled,
        ),
    ],
    trackChains: [
      for (final entry in looper.allTrackChains().entries)
        PerformanceTrackChain(
          channel: entry.key,
          effects: trackEffectsToEngine(entry.value.entries),
          chainEnabled: entry.value.chainEnabled,
        ),
    ],
    // One read path for the output stage, the same accessor
    // [chainsFromLooper] uses — two ways to read one piece of state at one
    // boundary would be free to drift.
    outputChains: [
      for (final entry in looper.allOutputChains().entries)
        PerformanceOutputChain(
          bus: entry.key,
          effects: trackEffectsToEngine(entry.value.entries),
          chainEnabled: entry.value.chainEnabled,
        ),
    ],
    limiterEnabled: looper.limiterEnabled,
    limiterCeiling: looper.limiterCeiling,
  );
}

/// Maps a decoded session [bundle] into the looper-domain [SessionRig] the
/// looper repository applies, decoding the manifest's opaque chain strings back
/// into effect models. A lane with no decoded audio is dropped; a track left
/// with no lane is dropped whole.
SessionRig rigFromBundle(SessionBundle bundle) => SessionRig(
  baseLengthFrames: bundle.session.baseLengthFrames,
  tracks: _rigTracks(bundle),
  // Envelope-aware decode (R15): a v5+ manifest carries the chain envelope in
  // the opaque string; a v4-or-earlier bare-array chain decodes with every
  // level defaulted to enabled. The whole envelope reaches the rig — the flag
  // and the provenance marker restore with the entries, and any stage the
  // manifest does NOT describe is reset on apply, never inherited (R17).
  laneChains: {
    for (final chain in bundle.session.laneChains)
      (chain.channel, chain.lane): decodeFxChain(chain.encoded),
  },
  monitors: [
    for (final monitor in bundle.session.monitors)
      _rigMonitor(monitor, decodeFxChain(monitor.encoded)),
  ],
  // Current schema v9 carries every configured bus stage. An absent chain
  // resets that destination when the session replaces the live rig.
  trackChains: {
    for (final chain in bundle.session.trackChains)
      chain.channel: decodeFxChain(chain.encoded),
  },
  outputChains: {
    for (final chain in bundle.session.outputChains)
      chain.bus: decodeFxChain(chain.encoded),
  },
  // The required All tracks field also resets any old live chain when empty.
  allTracksChain: decodeFxChain(bundle.session.allTracksChain),
  // Looper mode + crown (schema v4, B5c) — session-level, so read straight
  // off the manifest rather than through `_rigTracks`.
  looperMode: bundle.session.looperMode,
  primaryTrack: bundle.session.primaryTrack,
  // Desired settings are independent of the audio tracks kept by _rigTracks.
  tempoBpm: bundle.session.tempoBpm,
  tempoSource: bundle.session.tempoSource,
  tsNum: bundle.session.tsNum,
  tsDen: bundle.session.tsDen,
  syncTempo: bundle.session.syncTempo,
  quantizeDiv: bundle.session.quantizeDiv,
  loopBars: bundle.session.loopBars,
  loopBeats: bundle.session.loopBeats,
  defaultOneShot: bundle.session.defaultOneShot,
  defaultLengthPresetBars: bundle.session.defaultLengthPresetBars,
  trackRecordTimingOverrides: bundle.session.trackRecordTimingOverrides,
  trackOverdubDecayOverrides: bundle.session.trackOverdubDecayOverrides,
  trackOneShotOverrides: bundle.session.trackOneShotOverrides,
  trackLengthPresetOverrides: bundle.session.trackLengthPresetOverrides,
  trackLevels: bundle.session.trackLevels,
  trackPans: bundle.session.trackPans,
  laneInputs: bundle.session.laneInputs,
  laneOutputs: bundle.session.laneOutputs,
  laneCounts: bundle.session.laneCounts,
  clickMode: bundle.session.clickMode,
  clickMask: bundle.session.clickOutputMask,
  clickVolume: bundle.session.clickVolume,
  countInBars: bundle.session.countInBars,
  recDub: bundle.session.recDub,
  autoRecord: bundle.session.autoRecord,
  defaultMultiple: bundle.session.defaultMultiple,
  recordTiming: bundle.session.recordTiming,
  overdubDecay: bundle.session.overdubDecay,
  // The input setup (slice 3): trims, pans and pairs. The monitors' pans are
  // not mapped from the manifest's monitors — the repository derives them
  // from this on apply, the same way it did when the session was saved.
  inputSetup: InputSetup(
    trimDb: bundle.session.inputSetup.trimDb,
    pan: bundle.session.inputSetup.pan,
    pairs: bundle.session.inputSetup.pairs,
  ),
  // The output setup (slice 3b), session-owned like the input setup.
  outputSetup: outputSetupFromSession(bundle.session.outputSetup),
);

/// The rig `New loop` applies (plan D9): [live]'s settings and chains with
/// no tracks, no grid and no crown ([Session.forNewLoop]), mapped by the same
/// [rigFromBundle] an Open uses, so the two cannot disagree about a setting.
///
/// The transforms reset with the clear inside the apply: lane mutes go with
/// the tracks, and Fade and Reverse reset with the material
/// (`LE_CMD_RESET_TRANSFORMS`). Speed and Transpose resets belong in that same
/// apply path when they land, not here.
SessionRig rigForNewLoop(Session live) =>
    rigFromBundle((session: live.forNewLoop(), laneStems: const {}));

/// Projects one manifest monitor + its decoded chain into the rig's Input-stage
/// model. The monitor carries routing/mix of its own, so the envelope is
/// flattened onto it rather than nested (see [SessionRig]'s doc).
SessionRigMonitor _rigMonitor(SessionMonitor monitor, FxChainEnvelope chain) =>
    SessionRigMonitor(
      input: monitor.input,
      mode: _monitorMode(monitor),
      outputMask: monitor.outputMask,
      volume: monitor.volume,
      muted: monitor.muted,
      effects: chain.entries,
      chainEnabled: chain.chainEnabled,
    );

/// The gate a manifest monitor restores to.
///
/// An unknown name is corrupt current-schema data, not an alternate gate.
MonitorMode _monitorMode(SessionMonitor monitor) =>
    monitorModeFromName(monitor.mode) ??
    (throw FormatException('invalid monitor mode ${monitor.mode}'));

/// Builds the rig's tracks from [bundle], zipping each manifest lane with its
/// decoded PCM. A lane with no decoded audio is dropped; a track left with no
/// lane is dropped whole.
List<SessionRigTrack> _rigTracks(SessionBundle bundle) {
  final tracks = <SessionRigTrack>[];
  for (final track in bundle.session.tracks) {
    if (!track.fadeAmount.isFinite ||
        track.fadeAmount < 0 ||
        track.fadeAmount > 1) {
      throw const FormatException('invalid track Fade amount');
    }
    final lanes = <SessionRigLane>[];
    for (final lane in track.lanes) {
      final layers = bundle.laneStems[(track.channel, lane.lane)];
      if (layers == null || layers.isEmpty) continue;
      lanes.add(
        SessionRigLane(
          lane: lane.lane,
          layers: layers,
          volume: lane.volume,
          muted: lane.muted,
          outputMask: lane.outputMask,
          inputChannel: lane.inputChannel,
          pan: lane.pan,
          balance: lane.balance,
          history: lane.history,
        ),
      );
    }
    if (lanes.isNotEmpty) {
      tracks.add(
        SessionRigTrack(
          channel: track.channel,
          fadeAmount: track.fadeAmount,
          reversed: track.reversed,
          lanes: lanes,
        ),
      );
    }
  }
  return tracks;
}
