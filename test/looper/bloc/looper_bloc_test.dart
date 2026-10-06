import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/looper/application/playback_settings.dart';
import 'package:segno/looper/looper.dart';
import 'package:segno/looper/model/record_length.dart';
import 'package:segno/looper/model/record_timing.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

class _MockLooperRepository extends Mock implements LooperRepository {}

class _MockRecordLengthControl extends Mock implements RecordLengthControl {}

class _MockRecordTimingControl extends Mock implements RecordTimingControl {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

const _playingState = LooperState(
  transport: TransportState(isRunning: true, masterLengthFrames: 48000),
  tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
);

void main() {
  late LooperRepository repository;
  late _MockRecordLengthControl recordLength;
  late _MockRecordTimingControl recordTiming;
  late StreamController<LooperState> stateController;
  late MixSettingsSnapshot currentMix;
  late int confirmedDecay;
  late Map<int, int> confirmedTrackDecay;
  late bool confirmedOneShot;
  late Map<int, bool> confirmedTrackOneShot;

  setUpAll(() {
    registerFallbackValue(<TrackEffect>[]);
    registerFallbackValue(const PluginRef(format: PluginFormat.vst3, id: ''));
    registerFallbackValue(ClickMode.off);
    registerFallbackValue(LooperMode.multi);
    registerFallbackValue(MixSettingsSnapshot());
    registerFallbackValue(FxPlacement.post);
  });

  setUp(() {
    repository = _MockLooperRepository();
    recordLength = _MockRecordLengthControl();
    recordTiming = _MockRecordTimingControl();
    when(
      () => recordTiming.setTrackTiming(
        channel: any(named: 'channel'),
        timing: any(named: 'timing'),
      ),
    ).thenAnswer(
      (_) async => const RecordTimingOutcome(RecordTimingStatus.applied),
    );
    when(() => recordLength.setLooperMode(any())).thenAnswer(
      (_) async => const RecordLengthOutcome(RecordLengthStatus.rejected),
    );
    when(
      () => recordLength.setTrackRecordLength(
        channel: any(named: 'channel'),
        bars: any(named: 'bars'),
      ),
    ).thenAnswer(
      (_) async => const RecordLengthOutcome(RecordLengthStatus.rejected),
    );
    currentMix = MixSettingsSnapshot();
    confirmedDecay = 0;
    confirmedTrackDecay = {};
    confirmedOneShot = false;
    confirmedTrackOneShot = {};
    when(() => repository.mixGeneration).thenReturn(0);
    when(() => repository.sessionRevision).thenReturn(0);
    when(
      () => repository.defaultOverdubDecay,
    ).thenAnswer((_) => confirmedDecay);
    when(
      () => repository.trackOverdubDecayOverrides,
    ).thenAnswer((_) => Map.unmodifiable(confirmedTrackDecay));
    when(() => repository.decayRestartIntent).thenAnswer(
      (_) => (
        defaultPercent: confirmedDecay,
        trackOverrides: Map.unmodifiable(confirmedTrackDecay),
      ),
    );
    when(() => repository.defaultOneShot).thenAnswer((_) => confirmedOneShot);
    when(() => repository.trackOneShotOverrides).thenAnswer(
      (_) => Map.unmodifiable(confirmedTrackOneShot),
    );
    when(() => repository.oneShotSettingsSettled).thenReturn(true);
    when(() => repository.oneShotRecoveryRequired).thenReturn(false);
    when(
      () => repository.oneShotFailures,
    ).thenAnswer((_) => const Stream<EngineResult>.empty());
    when(
      () => repository.settleOneShot(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(() => repository.oneShotRestartIntent).thenAnswer(
      (_) => (
        defaultOneShot: confirmedOneShot,
        trackOverrides: Map<int, bool>.unmodifiable(confirmedTrackOneShot),
      ),
    );
    when(
      () => repository.setOneShotSnapshot(
        defaultOneShot: any(named: 'defaultOneShot'),
        trackOverrides: any(named: 'trackOverrides'),
        released: any(named: 'released'),
      ),
    ).thenAnswer((call) {
      confirmedOneShot = call.namedArguments[#defaultOneShot] as bool;
      confirmedTrackOneShot = Map.of(
        call.namedArguments[#trackOverrides] as Map<int, bool>,
      );
      return EngineResult.ok;
    });

    when(
      () => repository.setDecayRestartIntent(
        defaultPercent: any(named: 'defaultPercent'),
        trackOverrides: any(named: 'trackOverrides'),
      ),
    ).thenAnswer((_) {});
    when(() => repository.setOverdubDecay(any())).thenAnswer((call) {
      confirmedDecay = call.positionalArguments.single as int;
      return EngineResult.ok;
    });
    when(() => repository.fxReplayConfirmed).thenAnswer(
      (_) => const Stream<({int mixGeneration, int sessionRevision})>.empty(),
    );
    when(() => repository.fxRecipesSettled).thenReturn(true);
    when(
      () => repository.settleFxRecipes(
        waitForCallback: true,
        cancelled: any(named: 'cancelled'),
      ),
    ).thenAnswer((_) async => EngineResult.ok);
    when(() => repository.mixSettingsSettled).thenReturn(true);
    when(() => repository.mixRecoveryRequired).thenReturn(false);
    when(
      () => repository.mixSettingsFailures,
    ).thenAnswer((_) => const Stream.empty());
    when(() => repository.mixSettingsSnapshot).thenAnswer((_) => currentMix);
    when(() => repository.allTracksChainEnabled).thenReturn(true);
    when(() => repository.allTracksEffects).thenReturn(const []);
    when(repository.allLaneChains).thenReturn(const {});
    when(repository.allTrackChains).thenReturn(const {});
    when(
      () => repository.validateMixSettings(any()),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.prepareInputPair(
        any(),
        input: any(named: 'input'),
        paired: any(named: 'paired'),
      ),
    ).thenAnswer((call) {
      final snapshot = call.positionalArguments.first as MixSettingsSnapshot;
      final input = call.namedArguments[#input] as int;
      final paired = call.namedArguments[#paired] as bool;
      return snapshot.copyWith(
        inputSetup: snapshot.inputSetup.withPair(input, paired: paired),
      );
    });
    when(() => repository.applyMixSettings(any())).thenAnswer((call) {
      currentMix = call.positionalArguments.first as MixSettingsSnapshot;
      return EngineResult.ok;
    });
    when(() => repository.laneCount(any())).thenReturn(1);
    when(() => repository.sessionRevision).thenReturn(0);
    when(
      () => repository.settleLengthSettings(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.settleMixSettings(),
    ).thenAnswer((_) async => EngineResult.ok);
    when(
      () => repository.trackLengthPresetOverrides,
    ).thenReturn(const {1: 8});
    stateController = StreamController<LooperState>.broadcast();
    when(
      () => repository.looperState,
    ).thenAnswer((_) => stateController.stream);
    // Repository state is a fresh synchronous snapshot; per-test overrides
    // supply recorded or pending tracks independently of stream publication.
    when(() => repository.state).thenReturn(const LooperState());
    // The mute toggle resolves against the repository's remembered intent
    // (synchronous), not the polled snapshot — see LooperMuteToggled.
    final laneMutes = <(int, int), bool>{};
    when(() => repository.laneMuted(any(), any())).thenAnswer(
      (call) =>
          laneMutes[(
            call.positionalArguments[0] as int,
            call.positionalArguments[1] as int,
          )] ??
          false,
    );
    when(() => repository.trackMuted(any())).thenReturn(false);
    when(
      () => repository.record(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.stopTrack(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.play(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.clear(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.undo(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.redo(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setVolume(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setTrackRecordTiming(
        channel: any(named: 'channel'),
        timing: any(named: 'timing'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setTrackOverdubDecay(
        channel: any(named: 'channel'),
        percent: any(named: 'percent'),
      ),
    ).thenAnswer((call) {
      final channel = call.namedArguments[#channel] as int;
      final percent = call.namedArguments[#percent] as int?;
      if (percent == null) {
        confirmedTrackDecay.remove(channel);
      } else {
        confirmedTrackDecay[channel] = percent;
      }
      return EngineResult.ok;
    });
    when(
      () => repository.setTrackLengthPreset(
        channel: any(named: 'channel'),
        bars: any(named: 'bars'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.crownPrimary(channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    // The mix (slice 3).
    when(
      () => repository.setTrackPan(any(), channel: any(named: 'channel')),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setTrackSolo(
        channel: any(named: 'channel'),
        solo: any(named: 'solo'),
      ),
    ).thenReturn(EngineResult.ok);
    when(repository.clearSolo).thenReturn(EngineResult.ok);
    when(repository.resetMixer).thenReturn(EngineResult.ok);
    when(repository.cutSound).thenReturn(EngineResult.ok);
    when(
      () => repository.setInputTrimDb(
        input: any(named: 'input'),
        db: any(named: 'db'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setInputPan(
        input: any(named: 'input'),
        pan: any(named: 'pan'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setInputPair(
        input: any(named: 'input'),
        paired: any(named: 'paired'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setPairBalance(
        input: any(named: 'input'),
        balance: any(named: 'balance'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.inputSetup).thenReturn(const InputSetup.empty());

    when(() => repository.setLooperMode(any())).thenReturn(EngineResult.ok);
    // What the repository HOLDS after a set — the value the bloc persists.
    // Tests that care about a refusal or a closed engine override it.
    when(() => repository.settledLooperMode).thenReturn(LooperMode.multi);
    when(
      () => repository.setLaneCount(
        channel: any(named: 'channel'),
        count: any(named: 'count'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneInput(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        inputChannel: any(named: 'inputChannel'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneOutput(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        mask: any(named: 'mask'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneVolume(
        any(),
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneMute(
        muted: any(named: 'muted'),
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
      ),
    ).thenAnswer((call) {
      laneMutes[(
            call.namedArguments[#channel] as int,
            call.namedArguments[#lane] as int,
          )] =
          call.namedArguments[#muted] as bool;
      return EngineResult.ok;
    });
    when(
      () => repository.setLaneEffects(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        effects: any(named: 'effects'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneEffectPlacement(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        slotId: any(named: 'slotId'),
        placement: any(named: 'placement'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setTrackEffectPlacement(
        channel: any(named: 'channel'),
        slotId: any(named: 'slotId'),
        placement: any(named: 'placement'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLaneEffectParam(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        param: any(named: 'param'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.setLanePluginParam(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        paramId: any(named: 'paramId'),
        value: any(named: 'value'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.openLanePluginEditor(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.closeLanePluginEditor(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(EngineResult.ok);
    when(
      () => repository.refreshLanePluginParams(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(false);
    when(
      () => repository.isLanePluginEditorOpen(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
      ),
    ).thenReturn(true);
    when(
      () => repository.relinkLanePlugin(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        index: any(named: 'index'),
        ref: any(named: 'ref'),
      ),
    ).thenReturn(EngineResult.ok);
    when(() => repository.laneEffects(any(), any())).thenReturn(const []);
    when(() => repository.laneChainEnabled(any(), any())).thenReturn(true);
    when(
      () => repository.laneChainInheritedFrom(any(), any()),
    ).thenReturn(const []);
    when(
      () => repository.setOutputEnabled(
        output: any(named: 'output'),
        enabled: any(named: 'enabled'),
      ),
    ).thenReturn(EngineResult.ok);
    when(repository.tapTempo).thenReturn(EngineResult.ok);
    when(() => repository.setClickMode(any())).thenReturn(EngineResult.ok);
  });

  tearDown(() => stateController.close());

  LooperBloc buildBloc() => LooperBloc(
    fxPersistence: FxChainPersistence(looper: repository),
    repository: repository,
    mixSettings: testMixSettings(repository),
  );

  test('initial state is an empty looper', () {
    final bloc = buildBloc();
    addTearDown(bloc.close);
    expect(bloc.state, const LooperState());
  });

  test(
    'a full confirmed chain refuses append without dropping its new ID',
    () async {
      when(() => repository.trackEffects(0)).thenReturn([
        for (var i = 0; i < kTrackEffectMax; i++)
          BuiltInEffect(type: TrackEffectType.drive, slotId: 'old-$i'),
      ]);
      final bloc = buildBloc();
      addTearDown(bloc.close);
      final receipt = Completer<bool>();
      bloc.add(
        LooperBusEffectsAppended(
          const FxAddress(stage: FxStage.track),
          [BuiltInEffect(type: TrackEffectType.delay, slotId: 'new-choice')],
          receipt: receipt,
          expectedMixGeneration: 0,
        ),
      );

      expect(await receipt.future, isFalse);
      verifyNever(
        () => repository.setTrackEffects(
          channel: 0,
          effects: any(named: 'effects'),
        ),
      );
    },
  );

  blocTest<LooperBloc, LooperState>(
    'emits repository states pushed through the stream',
    build: buildBloc,
    act: (_) => stateController.add(_playingState),
    expect: () => [_playingState],
  );

  blocTest<LooperBloc, LooperState>(
    'LooperRecordPressed forwards to repository.record with the channel',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperRecordPressed(2)),
    verify: (_) => verify(() => repository.record(channel: 2)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'takeLocked suppresses LooperRecordPressed',
    build: () => LooperBloc(
      fxPersistence: FxChainPersistence(looper: repository),
      mixSettings: testMixSettings(repository),
      repository: repository,
      takeLocked: () => true,
    ),
    act: (bloc) => bloc.add(const LooperRecordPressed(2)),
    verify: (_) =>
        verifyNever(() => repository.record(channel: any(named: 'channel'))),
  );

  blocTest<LooperBloc, LooperState>(
    'takeLocked suppresses LooperClearPressed',
    build: () => LooperBloc(
      fxPersistence: FxChainPersistence(looper: repository),
      mixSettings: testMixSettings(repository),
      repository: repository,
      takeLocked: () => true,
    ),
    act: (bloc) => bloc.add(const LooperClearPressed(0)),
    verify: (_) {
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
      verifyNever(
        () => repository.setMute(
          muted: any(named: 'muted'),
          channel: any(named: 'channel'),
        ),
      );
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperStopPressed forwards to repository.stopTrack',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperStopPressed(1)),
    verify: (_) => verify(() => repository.stopTrack(channel: 1)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperRedoPressed forwards to repository.redo with the channel',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperRedoPressed(2)),
    verify: (_) => verify(() => repository.redo(channel: 2)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed removes the layer when the track has overdubs',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(),
        Track(
          channel: 1,
          state: TrackState.playing,
          lengthFrames: 100,
          undoDepth: 2,
        ),
      ],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed on a base-loop track undoes (never clears): the '
    'engine empties it redo-ably',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(),
        Track(channel: 1, state: TrackState.playing, lengthFrames: 100),
      ],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed on an empty track forwards to undo, not clear',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [Track(), Track(channel: 1)],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperVolumeChanged applies whole-track gain without part edits',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperVolumeChanged(3, 0.5)),
    verify: (_) {
      expect(currentMix.trackLevels[3], 0.5);
      expect(currentMix.laneLevels, isEmpty);
      verify(() => repository.applyMixSettings(any())).called(1);
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperMuteToggled mutes from the current (unmuted) state',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperMuteToggled(0)),
    verify: (_) => verify(() => repository.setMute(muted: true)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperMuteToggled resolves against repository intent, not the polled '
    'state — a double-tap inside the echo window must unmute',
    build: buildBloc,
    // The polled snapshot still says unmuted (the echo has not landed), but
    // the repository already remembers the first tap's mute. Resolving from
    // the snapshot would re-send muted:true and leave the track silent.
    seed: () => const LooperState(tracks: [Track()]),
    setUp: () => when(() => repository.trackMuted(0)).thenReturn(true),
    act: (bloc) => bloc.add(const LooperMuteToggled(0)),
    verify: (_) => verify(() => repository.setMute(muted: false)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperClearPressed clears the track and re-arms it (unmutes)',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(state: TrackState.stopped, lengthFrames: 100, muted: true),
      ],
    ),
    act: (bloc) => bloc.add(const LooperClearPressed(0)),
    verify: (_) {
      verify(() => repository.clear()).called(1);
      verify(() => repository.setMute(muted: false)).called(1);
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperUndoPressed on a muted base-loop track still undoes — the mute '
    'is untouched (undo/redo are exact inverses)',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(),
        Track(
          channel: 1,
          state: TrackState.stopped,
          lengthFrames: 100,
          muted: true,
        ),
      ],
    ),
    act: (bloc) => bloc.add(const LooperUndoPressed(1)),
    verify: (_) {
      verify(() => repository.undo(channel: 1)).called(1);
      verifyNever(() => repository.clear(channel: any(named: 'channel')));
      verifyNever(
        () => repository.setMute(
          muted: any(named: 'muted'),
          channel: any(named: 'channel'),
        ),
      );
    },
  );

  late SettingsRepository trackSettings;
  LooperBloc buildBlocWithSettings() {
    trackSettings = SettingsRepository(store: FakeKeyValueStore());
    final playback = PlaybackSettings(
      repository: repository,
      settings: trackSettings,
    );
    addTearDown(() => unawaited(playback.close()));
    return LooperBloc(
      fxPersistence: FxChainPersistence(looper: repository),
      mixSettings: testMixSettings(repository, settings: trackSettings),
      repository: repository,
      settings: trackSettings,
    );
  }

  blocTest<LooperBloc, LooperState>(
    'LooperTrackPanChanged persists confirmed pan',
    build: () {
      when(() => repository.state).thenReturn(
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1),
            Track(channel: 2, pan: -0.5),
          ],
        ),
      );
      return buildBlocWithSettings();
    },
    act: (bloc) => bloc.add(const LooperTrackPanChanged(2, pan: -0.5)),
    verify: (_) async {
      expect(currentMix.trackPans[2], -0.5);
      expect((await trackSettings.loadMixSettings('test')).trackPans[2], -0.5);
    },
  );

  blocTest<LooperBloc, LooperState>(
    'a refused track pan leaves the saved value unchanged',
    setUp: () {
      when(
        () => repository.applyMixSettings(any()),
      ).thenReturn(EngineResult.notReady);
    },
    build: buildBlocWithSettings,
    act: (bloc) async {
      await trackSettings.seedTrackPan(2, 0.25);
      bloc.add(const LooperTrackPanChanged(2, pan: -0.5));
    },
    verify: (_) async => expect(
      (await trackSettings.loadMixSettings('test')).trackPans[2],
      0.25,
    ),
  );

  blocTest<LooperBloc, LooperState>(
    'a late mix refusal leaves the saved value unchanged',
    setUp: () {
      when(
        () => repository.settleMixSettings(),
      ).thenAnswer((_) async => EngineResult.invalid);
    },
    build: buildBlocWithSettings,
    act: (bloc) async {
      await trackSettings.seedTrackPan(2, 0.25);
      bloc.add(const LooperTrackPanChanged(2, pan: -0.5));
    },
    verify: (_) async => expect(
      (await trackSettings.loadMixSettings('test')).trackPans[2],
      0.25,
    ),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperTrackSoloToggled applies temporary solo',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperTrackSoloToggled(1)),
    verify: (_) => expect(currentMix.trackSolos[1], isTrue),
  );

  blocTest<LooperBloc, LooperState>(
    'rapid Solo presses cancel before the published widget state changes',
    build: buildBloc,
    act: (bloc) => bloc
      ..add(const LooperTrackSoloToggled(1))
      ..add(const LooperTrackSoloToggled(1)),
    verify: (_) => expect(currentMix.trackSolos[1] ?? false, isFalse),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperSoloCleared clears temporary solo',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperSoloCleared()),
    verify: (_) => expect(currentMix.trackSolos, isEmpty),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperMixerReset resets the mixer and puts every saved track pan back '
    'to centre',
    build: () {
      when(() => repository.state).thenReturn(
        const LooperState(tracks: [Track(), Track(channel: 1)]),
      );
      return buildBlocWithSettings();
    },
    act: (bloc) async {
      await trackSettings.seedTrackPan(0, -1);
      await trackSettings.seedTrackPan(1, 0.5);
      currentMix = MixSettingsSnapshot(trackPans: const {0: -1, 1: 0.5});
      bloc.add(const LooperMixerReset());
    },
    verify: (_) async {
      expect(currentMix.trackPans, isEmpty);
      expect(
        (await trackSettings.loadMixSettings('test')).trackPans[0] ?? 0,
        0,
      );
      expect(
        (await trackSettings.loadMixSettings('test')).trackPans[1] ?? 0,
        0,
      );
    },
  );

  group('the input setup (slice 3)', () {
    // The coordinator writes a complete device setup with each accepted edit.
    final setup = InputSetup(
      trimDb: const {0: -6},
      pan: const {2: -0.5},
      pairs: const {0: 0.2},
    );

    LooperBloc buildWithDevice() {
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(deviceName: 'Scarlett 18i20', inputChannels: 4),
        ),
      );
      when(() => repository.inputSetup).thenReturn(setup);
      return buildBlocWithSettings();
    }

    /// The keys written under the open device.
    Future<StoredInputSetup> stored() => trackSettings.loadInputSetup(
      device: 'Scarlett 18i20',
      inputCount: 4,
    );

    blocTest<LooperBloc, LooperState>(
      'LooperInputTrimChanged forwards the trim and persists that trim only',
      build: buildWithDevice,
      act: (bloc) => bloc.add(const LooperInputTrimChanged(0, db: -6)),
      verify: (_) async {
        expect(currentMix.inputSetup.trimDb, {0: -6});
        final s = await stored();
        expect(s.trimDb, {0: -6.0});
        expect(s.pan, isEmpty);
        expect(s.pairs, isEmpty);
        final other = await trackSettings.loadInputSetup(
          device: 'Built-in',
          inputCount: 4,
        );
        expect(other.trimDb, isEmpty);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperInputPanChanged forwards the pan and persists that pan only',
      build: buildWithDevice,
      act: (bloc) => bloc.add(const LooperInputPanChanged(2, pan: -0.5)),
      verify: (_) async {
        expect(currentMix.inputSetup.pan, {2: -0.5});
        final s = await stored();
        expect(s.pan, {2: -0.5});
        expect(s.trimDb, isEmpty);
        expect(s.pairs, isEmpty);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperInputPairChanged forwards the link and persists that pair only',
      build: buildWithDevice,
      act: (bloc) => bloc.add(const LooperInputPairChanged(0, paired: true)),
      verify: (_) async {
        expect(currentMix.inputSetup.pairs, {0: 0});
        final s = await stored();
        expect(s.pairs, {0: 0});
        expect(s.trimDb, isEmpty);
        expect(s.pan, isEmpty);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperInputBalanceChanged forwards the balance and persists it under '
      "the pair's lower member",
      build: () {
        final bloc = buildWithDevice();
        currentMix = MixSettingsSnapshot(
          inputSetup: InputSetup(pairs: const {0: 0}),
        );
        return bloc;
      },
      act: (bloc) async {
        await trackSettings.seedInputPair('Scarlett 18i20', 0, 0);
        bloc.add(const LooperInputBalanceChanged(0, balance: 0.2));
      },
      verify: (_) async {
        expect(currentMix.inputSetup.pairs, {0: 0.2});
        expect((await stored()).pairs, {0: 0.2});
      },
    );

    blocTest<LooperBloc, LooperState>(
      'a value put back to its default is cleared from the store, and the '
      'other inputs are left alone',
      build: () {
        final bloc = buildWithDevice();
        currentMix = MixSettingsSnapshot(inputSetup: setup);
        return bloc;
      },
      act: (bloc) async {
        await trackSettings.seedInputSetup('Scarlett 18i20', (
          trimDb: setup.trimDb,
          pan: setup.pan,
          pairs: setup.pairs,
        ));
        bloc
          ..add(const LooperInputTrimChanged(0, db: 0))
          ..add(const LooperInputPairChanged(0, paired: false));
      },
      verify: (_) async {
        final s = await stored();
        expect(s.trimDb, isEmpty);
        expect(s.pairs, isEmpty);
        // Input 2's pan was not touched by either event.
        expect(s.pan, {2: -0.5});
      },
    );

    blocTest<LooperBloc, LooperState>(
      'without a device, setup edits are refused before storage and audio',
      build: () {
        when(() => repository.state).thenReturn(const LooperState());
        when(() => repository.inputSetup).thenReturn(setup);
        return buildBlocWithSettings();
      },
      act: (bloc) => bloc
        ..add(const LooperInputTrimChanged(0, db: -6))
        ..add(const LooperInputPanChanged(2, pan: -0.5))
        ..add(const LooperInputPairChanged(0, paired: true))
        ..add(const LooperInputBalanceChanged(0, balance: 0.2)),
      verify: (_) async {
        verifyNever(() => repository.applyMixSettings(any()));
        final s = await trackSettings.loadInputSetup(
          device: '',
          inputCount: 4,
        );
        expect(s.trimDb, isEmpty);
        expect(s.pan, isEmpty);
        expect(s.pairs, isEmpty);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'an in-memory coordinator applies edits with no bloc settings writer',
      build: buildBloc,
      act: (bloc) => bloc.add(const LooperTrackPanChanged(1, pan: 0.25)),
      verify: (_) async {
        expect(currentMix.trackPans[1], 0.25);
      },
    );
  });

  group('output setup through the shared mix coordinator', () {
    LooperBloc buildWithDevice() {
      when(() => repository.state).thenReturn(
        const LooperState(
          status: EngineStatus(deviceName: 'Scarlett 18i20', outputChannels: 4),
        ),
      );
      return buildBlocWithSettings();
    }

    blocTest<LooperBloc, LooperState>(
      'level, mute, Mono and balance persist as one device mix',
      build: buildWithDevice,
      act: (bloc) => bloc
        ..add(const LooperOutputLevelChanged(1, level: 0.5))
        ..add(const LooperOutputMuteChanged(1, muted: true))
        ..add(const LooperOutputMonoChanged(0, mono: true))
        ..add(const LooperOutputBalanceChanged(0, balance: -0.25)),
      verify: (_) async {
        final setup = (await trackSettings.loadMixSettings(
          'Scarlett 18i20',
        )).outputSetup;
        expect(setup.level, {1: .5});
        expect(setup.muted, {1: true});
        expect(setup.mono, {0: true});
        expect(setup.balance, {0: -.25});
        expect(
          currentMix.outputSetup,
          const OutputSetup(
            buses: {
              0: OutputBus(mono: true, balance: -.25),
              1: OutputBus(level: .5, muted: true),
            },
          ),
        );
      },
    );

    blocTest<LooperBloc, LooperState>(
      'an output edit without an open device is refused before publication',
      build: buildBlocWithSettings,
      act: (bloc) => bloc.add(const LooperOutputMuteChanged(1, muted: true)),
      verify: (_) async {
        expect(currentMix.outputSetup, const OutputSetup());
        expect(
          (await trackSettings.loadMixSettings('')).outputSetup.muted,
          isEmpty,
        );
      },
    );

    blocTest<LooperBloc, LooperState>(
      'Cut sound forwards to the repository',
      build: buildBloc,
      act: (bloc) => bloc.add(const LooperCutSoundPressed()),
      verify: (_) => verify(repository.cutSound).called(1),
    );
  });

  blocTest<LooperBloc, LooperState>(
    'LooperCrownPrimaryPressed forwards the channel to the repository (D18, '
    'B5c)',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperCrownPrimaryPressed(2)),
    verify: (_) => verify(() => repository.crownPrimary(channel: 2)).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneVolumeChanged applies the live lane level',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneVolumeChanged(3, 1, 0.5)),
    verify: (_) => expect(currentMix.laneLevels[(3, 1)], 0.5),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperOutputEnabledToggled forwards the output gate to the repository',
    build: buildBloc,
    act: (bloc) =>
        bloc.add(const LooperOutputEnabledToggled(2, enabled: false)),
    verify: (_) => verify(
      () => repository.setOutputEnabled(output: 2, enabled: false),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneMuteToggled mutes from the current (unmuted) state',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneMuteToggled(0, 0)),
    verify: (_) => verify(
      () => repository.setLaneMute(muted: true, channel: 0, lane: 0),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneMuteToggled unmutes when the lane is already muted',
    build: buildBloc,
    setUp: () => when(() => repository.laneMuted(0, 0)).thenReturn(true),
    seed: () => const LooperState(
      tracks: [
        Track(lanes: [Lane(muted: true)]),
      ],
    ),
    act: (bloc) => bloc.add(const LooperLaneMuteToggled(0, 0)),
    verify: (_) => verify(
      () => repository.setLaneMute(muted: false, channel: 0, lane: 0),
    ).called(1),
  );

  // The chain surgery lives in the bloc: each intent event reads the current
  // chain from the repository, computes the next one, and pushes it back — the
  // view never builds the list. We capture the pushed chain to assert it.
  List<TrackEffect> capturePushedChain() =>
      verify(
            () => repository.setLaneEffects(
              channel: 1,
              lane: 2,
              effects: captureAny(named: 'effects'),
            ),
          ).captured.single
          as List<TrackEffect>;

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectAdded appends a default drive to the chain',
    build: buildBloc,
    act: (bloc) => bloc.add(const LooperLaneEffectAdded(1, 2)),
    verify: (_) {
      final pushed = capturePushedChain();
      expect(pushed, hasLength(1));
      expect((pushed.single as BuiltInEffect).type, TrackEffectType.drive);
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectRemoved drops the entry at the given index',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay),
        BuiltInEffect(type: TrackEffectType.reverb),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(const LooperLaneEffectRemoved(1, 2, 0)),
    verify: (_) => expect(
      capturePushedChain().map((e) => (e as BuiltInEffect).type),
      [TrackEffectType.reverb],
    ),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectTypeChanged retypes the entry at the given index',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(
      const LooperLaneEffectTypeChanged(1, 2, 0, TrackEffectType.reverb),
    ),
    verify: (_) => expect(
      (capturePushedChain().single as BuiltInEffect).type,
      TrackEffectType.reverb,
    ),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectMoved reorders the chain',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay),
        BuiltInEffect(type: TrackEffectType.reverb),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(const LooperLaneEffectMoved(1, 2, 0, 1)),
    verify: (_) =>
        expect(capturePushedChain().map((e) => (e as BuiltInEffect).type), [
          TrackEffectType.reverb,
          TrackEffectType.delay,
        ]),
  );

  blocTest<LooperBloc, LooperState>(
    'a lane retype keeps identity, power, placement, and channels',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(
          type: TrackEffectType.delay,
          enabled: false,
          slotId: 'keep-me',
          placement: FxPlacement.pre,
          channels: const FxChannels(
            input: FxChannelInput.right,
            output: FxChannelOutput.mono,
            placement: -.3,
            level: .7,
          ),
        ),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(
      const LooperLaneEffectTypeChanged(1, 2, 0, TrackEffectType.reverb),
    ),
    verify: (_) {
      final fx = capturePushedChain().single as BuiltInEffect;
      expect(fx.type, TrackEffectType.reverb);
      // A retype that drops these silently re-mints the entry (dangling every
      // binding on it), powers a bypassed device back on, and moves a printed
      // entry downstream of the player.
      expect(fx.slotId, 'keep-me');
      expect(fx.enabled, isFalse);
      expect(fx.placement, FxPlacement.pre);
      expect(
        fx.channels,
        const FxChannels(
          input: FxChannelInput.right,
          output: FxChannelOutput.mono,
          placement: -.3,
          level: .7,
        ),
      );
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperTrackEffectPlacementChanged moves a whole-track instance by '
    'identity',
    build: () {
      when(() => repository.trackEffects(1)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay, slotId: 'a'),
        BuiltInEffect(type: TrackEffectType.reverb, slotId: 'b'),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(
      const LooperTrackEffectPlacementChanged(1, 'b', FxPlacement.pre),
    ),
    verify: (_) => verify(
      () => repository.setTrackEffectPlacement(
        channel: 1,
        slotId: 'b',
        placement: FxPlacement.pre,
      ),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectPlacementChanged moves the instance by identity',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(type: TrackEffectType.delay, slotId: 'a'),
        BuiltInEffect(type: TrackEffectType.reverb, slotId: 'b'),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(
      const LooperLaneEffectPlacementChanged(1, 2, 'b', FxPlacement.pre),
    ),
    verify: (_) => verify(
      () => repository.setLaneEffectPlacement(
        channel: 1,
        lane: 2,
        // By identity, never index: the move is the one operation that
        // changes the index.
        slotId: 'b',
        placement: FxPlacement.pre,
      ),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'a lane reorder across the Pre/Post boundary is refused (slice 3e)',
    build: () {
      when(() => repository.laneEffects(1, 2)).thenReturn([
        BuiltInEffect(
          type: TrackEffectType.delay,
          placement: FxPlacement.pre,
        ),
        BuiltInEffect(type: TrackEffectType.reverb),
      ]);
      return buildBloc();
    },
    act: (bloc) => bloc.add(const LooperLaneEffectMoved(1, 2, 0, 1)),
    verify: (_) => verifyNever(
      () => repository.setLaneEffects(
        channel: any(named: 'channel'),
        lane: any(named: 'lane'),
        effects: any(named: 'effects'),
      ),
    ),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLaneEffectParamChanged forwards the param to the repository',
    build: buildBloc,
    act: (bloc) =>
        bloc.add(const LooperLaneEffectParamChanged(2, 1, 1, 0, 0.6)),
    verify: (_) => verify(
      () => repository.setLaneEffectParam(
        channel: 2,
        lane: 1,
        index: 1,
        param: 0,
        value: 0.6,
      ),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLanePluginParamChanged routes the plain value by plugin param id',
    build: buildBloc,
    act: (bloc) =>
        bloc.add(const LooperLanePluginParamChanged(2, 1, 0, 100, 0.8)),
    verify: (_) => verify(
      () => repository.setLanePluginParam(
        channel: 2,
        lane: 1,
        index: 0,
        paramId: 100,
        value: 0.8,
      ),
    ).called(1),
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLanePluginInserted appends a PluginEffect to the lane chain',
    build: buildBloc,
    act: (bloc) => bloc.add(
      const LooperLanePluginInserted(
        1,
        0,
        PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb'),
      ),
    ),
    verify: (_) {
      final effects =
          verify(
                () => repository.setLaneEffects(
                  channel: 1,
                  lane: 0,
                  effects: captureAny(named: 'effects'),
                ),
              ).captured.single
              as List<TrackEffect>;
      expect(
        effects.single,
        isA<PluginEffect>().having(
          (e) => e.ref.id,
          'ref.id',
          'com.acme.reverb',
        ),
      );
    },
  );

  blocTest<LooperBloc, LooperState>(
    'LooperLanePluginRelinked relinks the entry to the new ref',
    build: buildBloc,
    act: (bloc) => bloc.add(
      const LooperLanePluginRelinked(
        2,
        1,
        0,
        PluginRef(format: PluginFormat.vst3, id: 'replacement'),
      ),
    ),
    verify: (_) => verify(
      () => repository.relinkLanePlugin(
        channel: 2,
        lane: 1,
        index: 0,
        ref: const PluginRef(format: PluginFormat.vst3, id: 'replacement'),
      ),
    ).called(1),
  );

  group('plugin editor', () {
    blocTest<LooperBloc, LooperState>(
      'opening starts the inbound sync poll',
      build: buildBloc,
      act: (bloc) => bloc.add(const LooperLanePluginEditorOpened(0, 0, 1)),
      wait: const Duration(milliseconds: 250),
      verify: (_) {
        verify(
          () => repository.openLanePluginEditor(channel: 0, lane: 0, index: 1),
        ).called(1);
        // The ≤10 Hz poll fired at least once while the editor is open.
        verify(
          () =>
              repository.refreshLanePluginParams(channel: 0, lane: 0, index: 1),
        ).called(greaterThanOrEqualTo(1));
      },
    );

    blocTest<LooperBloc, LooperState>(
      'closing cancels the poll and reads params back',
      build: buildBloc,
      act: (bloc) async {
        bloc.add(const LooperLanePluginEditorOpened(0, 0, 1));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        bloc.add(const LooperLanePluginEditorClosed(0, 0, 1));
      },
      wait: const Duration(milliseconds: 300),
      verify: (_) {
        verify(
          () => repository.closeLanePluginEditor(channel: 0, lane: 0, index: 1),
        ).called(1);
        // After close the poll is cancelled: record the tick count, then prove
        // it stops climbing.
        final ticks = verify(
          () =>
              repository.refreshLanePluginParams(channel: 0, lane: 0, index: 1),
        ).callCount;
        expect(ticks, greaterThanOrEqualTo(1));
      },
    );

    blocTest<LooperBloc, LooperState>(
      'the poll self-terminates when the native window is gone',
      build: buildBloc,
      setUp: () {
        // The user closes the OS window: the editor reports not-open, so the
        // poll must stop on its own (no leaked timer).
        when(
          () => repository.isLanePluginEditorOpen(
            channel: any(named: 'channel'),
            lane: any(named: 'lane'),
            index: any(named: 'index'),
          ),
        ).thenReturn(false);
      },
      act: (bloc) => bloc.add(const LooperLanePluginEditorOpened(0, 0, 1)),
      wait: const Duration(milliseconds: 250),
      verify: (_) {
        // One tick ran, saw the window gone, and cancelled the timer — so the
        // refresh count stays at exactly 1.
        verify(
          () =>
              repository.refreshLanePluginParams(channel: 0, lane: 0, index: 1),
        ).called(1);
      },
    );

    test('a structural chain edit cancels the lane poll', () async {
      // A reorder/remove reseats the slots, so the poll keyed by a stale index
      // must stop (otherwise it would mirror the wrong plugin).
      var refreshCount = 0;
      when(
        () => repository.refreshLanePluginParams(
          channel: any(named: 'channel'),
          lane: any(named: 'lane'),
          index: any(named: 'index'),
        ),
      ).thenAnswer((_) {
        refreshCount++;
        return false;
      });
      final bloc = buildBloc()
        ..add(const LooperLanePluginEditorOpened(0, 0, 1));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      addTearDown(bloc.close);
      expect(refreshCount, greaterThanOrEqualTo(1));
      // A structural edit (add) reseats the lane → the poll is cancelled.
      bloc.add(const LooperLaneEffectAdded(0, 0));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final after = refreshCount;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(refreshCount, after);
    });

    test('close() disposes any open editor poll timers', () async {
      // Count ticks via a stub side-effect (verify() consumes matches, so it
      // can't be read twice).
      var refreshCount = 0;
      when(
        () => repository.refreshLanePluginParams(
          channel: any(named: 'channel'),
          lane: any(named: 'lane'),
          index: any(named: 'index'),
        ),
      ).thenAnswer((_) {
        refreshCount++;
        return false;
      });
      final bloc = buildBloc()
        ..add(const LooperLanePluginEditorOpened(0, 0, 0));
      // Wait past one poll period so the timer has ticked at least once.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await bloc.close();
      final before = refreshCount;
      expect(before, greaterThanOrEqualTo(1));
      // No further ticks after close — the timer was cancelled.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(refreshCount, before);
    });
  });

  group('routing persistence', () {
    late SettingsRepository settings;

    setUp(() {
      settings = _MockSettingsRepository();
      when(
        () => settings.saveLaneMute(any(), any(), muted: any(named: 'muted')),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveLaneEffects(any(), any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveOutputEnabled(
          device: any(named: 'device'),
          output: any(named: 'output'),
          enabled: any(named: 'enabled'),
        ),
      ).thenAnswer((_) async {});
    });

    blocTest<LooperBloc, LooperState>(
      'LooperOutputEnabledToggled forwards to the repo and persists the gate',
      build: () {
        // The gate is persisted against the OPEN device (#569), so the save
        // must carry the interface's name, not just the output index.
        when(() => repository.state).thenReturn(
          const LooperState(
            status: EngineStatus(deviceName: 'Scarlett 18i20'),
          ),
        );
        return LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        );
      },
      act: (bloc) =>
          bloc.add(const LooperOutputEnabledToggled(1, enabled: false)),
      verify: (_) {
        verify(
          () => repository.setOutputEnabled(output: 1, enabled: false),
        ).called(1);
        verify(
          () => settings.saveOutputEnabled(
            device: 'Scarlett 18i20',
            output: 1,
            enabled: false,
          ),
        ).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneVolumeChanged persists the volume onto the lane',
      build: buildBlocWithSettings,
      setUp: () => when(() => repository.state).thenReturn(
        const LooperState(
          tracks: [
            Track(),
            Track(channel: 1),
            Track(channel: 2, lanes: [Lane(), Lane(volume: 0.4)]),
          ],
        ),
      ),
      act: (bloc) => bloc.add(const LooperLaneVolumeChanged(2, 1, 0.4)),
      verify: (_) async {
        expect(currentMix.laneLevels[(2, 1)], 0.4);
        expect(
          (await trackSettings.loadMixSettings('test')).laneLevels[(2, 1)],
          0.4,
        );
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneMuteToggled persists the toggled mute onto the lane',
      build: () => LooperBloc(
        fxPersistence: FxChainPersistence(looper: repository),
        mixSettings: testMixSettings(repository),
        repository: repository,
        settings: settings,
      ),
      act: (bloc) => bloc.add(const LooperLaneMuteToggled(1, 0)),
      verify: (_) {
        verify(
          () => repository.setLaneMute(muted: true, channel: 1, lane: 0),
        ).called(1);
        verify(() => settings.saveLaneMute(1, 0, muted: true)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperClearPressed persists the unmute so a cleared track stays armed',
      build: () => LooperBloc(
        fxPersistence: FxChainPersistence(looper: repository),
        mixSettings: testMixSettings(repository),
        repository: repository,
        settings: settings,
      ),
      seed: () => const LooperState(
        tracks: [
          Track(),
          Track(
            channel: 1,
            state: TrackState.stopped,
            lengthFrames: 100,
            muted: true,
          ),
        ],
      ),
      act: (bloc) => bloc.add(const LooperClearPressed(1)),
      verify: (_) {
        verify(() => repository.setMute(muted: false, channel: 1)).called(1);
        verify(() => settings.saveLaneMute(1, 0, muted: false)).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'refused Clear leaves mute and its saved value untouched',
      setUp: () => when(
        () => repository.clear(channel: 1),
      ).thenReturn(EngineResult.invalid),
      build: () => LooperBloc(
        fxPersistence: FxChainPersistence(looper: repository),
        mixSettings: testMixSettings(repository),
        repository: repository,
        settings: settings,
      ),
      act: (bloc) => bloc.add(const LooperClearPressed(1)),
      verify: (_) {
        verifyNever(() => repository.setMute(muted: false, channel: 1));
        verifyNever(() => settings.saveLaneMute(1, 0, muted: false));
      },
    );

    blocTest<LooperBloc, LooperState>(
      'a lane effect structural edit persists the encoded chain onto the lane',
      build: () => LooperBloc(
        fxPersistence: FxChainPersistence(looper: repository),
        mixSettings: testMixSettings(repository),
        repository: repository,
        settings: settings,
      ),
      act: (bloc) => bloc.add(const LooperLaneEffectAdded(1, 2)),
      verify: (_) {
        verify(
          () => repository.setLaneEffects(
            channel: 1,
            lane: 2,
            effects: any(named: 'effects'),
          ),
        ).called(1);
        verify(() => settings.saveLaneEffects(1, 2, any())).called(1);
      },
    );

    test(
      'persists the take chain when the repository reports a record-time '
      'snapshot copy (F3)',
      () async {
        final bloc = LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        );
        addTearDown(bloc.close);
        // The bloc wires a chain-persist callback onto the repository; capture
        // it and simulate the record-time snapshot firing it.
        final callback =
            verify(
                  () => repository.onLaneChainChanged = captureAny(),
                ).captured.last
                as void Function(int, int)?;
        expect(callback, isNotNull);

        final takeChain = [BuiltInEffect(type: TrackEffectType.delay)];
        when(() => repository.laneEffects(0, 1)).thenReturn(takeChain);

        callback!(0, 1);
        await pumpEventQueue();
        final saved =
            verify(
                  () => settings.saveLaneEffects(0, 1, captureAny()),
                ).captured.single
                as String;
        expect(decodeFxChain(saved), FxChainEnvelope(entries: takeChain));
      },
    );

    blocTest<LooperBloc, LooperState>(
      'inserting a plugin persists the chain enriched with its resolved name',
      build: () {
        // The repository resolves the display name while applying the chain;
        // the save must persist THAT enriched chain, not the name-less input —
        // else the name is lost on restart and the card shows the raw id.
        when(() => repository.laneEffects(1, 2)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb'),
            name: 'Acme Reverb',
          ),
        ]);
        return LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        );
      },
      act: (bloc) => bloc.add(
        const LooperLanePluginInserted(
          1,
          2,
          PluginRef(format: PluginFormat.clap, id: 'com.acme.reverb'),
        ),
      ),
      verify: (_) {
        final encoded =
            verify(
                  () => settings.saveLaneEffects(1, 2, captureAny()),
                ).captured.single
                as String;
        final decoded = decodeFxChain(encoded).entries.single as PluginEffect;
        expect(decoded.name, 'Acme Reverb');
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLaneEffectParamChanged persists the re-encoded chain',
      build: () => LooperBloc(
        fxPersistence: FxChainPersistence(looper: repository),
        mixSettings: testMixSettings(repository),
        repository: repository,
        settings: settings,
        fxPersistDebounce: Duration.zero,
      ),
      act: (bloc) =>
          bloc.add(const LooperLaneEffectParamChanged(0, 1, 1, 2, 0.25)),
      verify: (_) {
        verify(
          () => repository.setLaneEffectParam(
            channel: 0,
            lane: 1,
            index: 1,
            param: 2,
            value: 0.25,
          ),
        ).called(1);
        verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
      },
    );

    blocTest<LooperBloc, LooperState>(
      'LooperLanePluginParamChanged persists the re-encoded chain',
      build: () => LooperBloc(
        fxPersistence: FxChainPersistence(looper: repository),
        mixSettings: testMixSettings(repository),
        repository: repository,
        settings: settings,
        fxPersistDebounce: Duration.zero,
      ),
      act: (bloc) =>
          bloc.add(const LooperLanePluginParamChanged(0, 1, 0, 100, 0.8)),
      verify: (_) {
        verify(
          () => repository.setLanePluginParam(
            channel: 0,
            lane: 1,
            index: 0,
            paramId: 100,
            value: 0.8,
          ),
        ).called(1);
        verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
      },
    );

    group('track/master chain events (FX v3 part 3a)', () {
      final trackChain = [BuiltInEffect(type: TrackEffectType.delay)];
      final masterChain = [BuiltInEffect(type: TrackEffectType.reverb)];

      setUp(() {
        when(
          () => repository.setTrackEffects(
            channel: any(named: 'channel'),
            effects: any(named: 'effects'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setTrackEffectEnabled(
            channel: any(named: 'channel'),
            index: any(named: 'index'),
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setTrackChainEnabled(
            channel: any(named: 'channel'),
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setOutputEffects(
            bus: 0,
            effects: any(named: 'effects'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setOutputEffectEnabled(
            bus: 0,
            index: any(named: 'index'),
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(
          () => repository.setOutputChainEnabled(
            bus: 0,
            enabled: any(named: 'enabled'),
          ),
        ).thenReturn(EngineResult.ok);
        when(() => repository.trackEffects(any())).thenReturn(trackChain);
        when(() => repository.trackChainEnabled(any())).thenReturn(false);
        when(() => repository.outputEffects(0)).thenReturn(masterChain);
        when(() => repository.outputChainEnabled(0)).thenReturn(false);
        when(
          () => settings.saveTrackFxChain(any(), any()),
        ).thenAnswer((_) async {});
        when(
          () => settings.saveOutputFxChain(0, any()),
        ).thenAnswer((_) async {});
      });

      blocTest<LooperBloc, LooperState>(
        'LooperTrackEffectsChanged pushes the chain and persists the '
        'envelope with the repo chain flag',
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(LooperTrackEffectsChanged(1, trackChain)),
        verify: (_) {
          verify(
            () => repository.setTrackEffects(channel: 1, effects: trackChain),
          ).called(1);
          final encoded =
              verify(
                    () => settings.saveTrackFxChain(1, captureAny()),
                  ).captured.single
                  as String;
          final decoded = decodeFxChain(encoded);
          expect(decoded.entries, trackChain);
          expect(decoded.chainEnabled, isFalse); // the repo flag rode along
        },
      );

      test(
        'a delayed recipe callback still leads to one durable editor save',
        () async {
          final applied = Completer<EngineResult>();
          var settled = false;
          when(() => repository.fxRecipesSettled).thenAnswer((_) => settled);
          when(
            () => repository.settleFxRecipes(
              waitForCallback: true,
              cancelled: any(named: 'cancelled'),
            ),
          ).thenAnswer((_) => applied.future);
          final bloc = LooperBloc(
            fxPersistence: FxChainPersistence(looper: repository),
            mixSettings: testMixSettings(repository),
            repository: repository,
            settings: settings,
          );
          addTearDown(bloc.close);
          bloc.add(LooperTrackEffectsChanged(1, trackChain));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          verifyNever(() => settings.saveTrackFxChain(1, any()));
          // Longer than the boot/session deadline: an accepted editor recipe
          // must not lose its save when the callback temporarily stops.
          await Future<void>.delayed(const Duration(milliseconds: 520));
          verifyNever(() => settings.saveTrackFxChain(1, any()));
          settled = true;
          applied.complete(EngineResult.ok);
          await pumpEventQueue();
          verify(() => settings.saveTrackFxChain(1, any())).called(1);
        },
      );

      test(
        'a structural receipt waits for its recipe and refuses a rejected edit',
        () async {
          final applied = Completer<EngineResult>();
          when(
            () => repository.settleFxRecipes(
              waitForCallback: true,
              cancelled: any(named: 'cancelled'),
            ),
          ).thenAnswer((_) => applied.future);
          final bloc = LooperBloc(
            fxPersistence: FxChainPersistence(looper: repository),
            mixSettings: testMixSettings(repository),
            repository: repository,
            settings: settings,
          );
          addTearDown(bloc.close);
          final accepted = Completer<bool>();
          bloc.add(
            LooperBusEffectsChanged(
              const FxAddress(stage: FxStage.track, index: 1),
              trackChain,
              receipt: accepted,
            ),
          );
          await pumpEventQueue();
          expect(accepted.isCompleted, isFalse);
          await Future<void>.delayed(const Duration(milliseconds: 550));
          expect(accepted.isCompleted, isFalse);
          applied.complete(EngineResult.ok);
          expect(await accepted.future, isTrue);

          when(
            () => repository.setTrackEffects(
              channel: 1,
              effects: trackChain,
            ),
          ).thenReturn(EngineResult.notReady);
          final refused = Completer<bool>();
          bloc.add(
            LooperBusEffectsChanged(
              const FxAddress(stage: FxStage.track, index: 1),
              trackChain,
              receipt: refused,
            ),
          );
          expect(await refused.future, isFalse);
        },
      );

      test('restart saves only an interrupted accepted FX target', () async {
        final replay =
            StreamController<
              ({int mixGeneration, int sessionRevision})
            >.broadcast();
        addTearDown(replay.close);
        when(
          () => repository.fxReplayConfirmed,
        ).thenAnswer((_) => replay.stream);
        var generation = 0;
        var settled = false;
        when(() => repository.mixGeneration).thenAnswer((_) => generation);
        when(() => repository.fxRecipesSettled).thenAnswer((_) => settled);
        final oldWait = Completer<EngineResult>();
        when(
          () => repository.settleFxRecipes(
            waitForCallback: true,
            cancelled: any(named: 'cancelled'),
          ),
        ).thenAnswer((_) => oldWait.future);
        final bloc = LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        );
        addTearDown(bloc.close);

        // An unrelated boot/replay signal cannot write an unloaded chain.
        replay.add((mixGeneration: 0, sessionRevision: 0));
        await pumpEventQueue();
        verifyNever(() => settings.saveTrackFxChain(1, any()));
        verifyNever(() => settings.saveOutputFxChain(0, any()));

        bloc.add(LooperTrackEffectsChanged(1, trackChain));
        await pumpEventQueue();
        verifyNever(() => settings.saveTrackFxChain(1, any()));
        generation = 1;
        oldWait.complete(EngineResult.notReady);
        await pumpEventQueue();
        settled = true;
        replay.add((mixGeneration: 1, sessionRevision: 0));
        await pumpEventQueue();
        verify(() => settings.saveTrackFxChain(1, any())).called(1);
        verifyNever(() => settings.saveOutputFxChain(0, any()));
      });

      test(
        'a new session edit waits behind the old in-flight store write',
        () async {
          final firstWrite = Completer<void>();
          var sessionRevision = 0;
          var writes = 0;
          when(
            () => repository.sessionRevision,
          ).thenAnswer((_) => sessionRevision);
          when(() => settings.saveTrackFxChain(1, any())).thenAnswer((_) {
            writes++;
            return writes == 1 ? firstWrite.future : Future<void>.value();
          });
          final bloc = LooperBloc(
            fxPersistence: FxChainPersistence(looper: repository),
            mixSettings: testMixSettings(repository),
            repository: repository,
            settings: settings,
          );
          addTearDown(bloc.close);

          bloc.add(LooperTrackEffectsChanged(1, trackChain));
          await pumpEventQueue();
          expect(writes, 1);
          sessionRevision = 1;
          bloc.add(LooperTrackEffectsChanged(1, trackChain));
          await pumpEventQueue();
          expect(writes, 1, reason: 'same target writes stay serialized');
          firstWrite.complete();
          await pumpEventQueue();
          expect(writes, 2, reason: 'new session edit must not be orphaned');
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a failed FX store write reports once without a retry spin',
        setUp: () => when(
          () => settings.saveTrackFxChain(1, any()),
        ).thenAnswer((_) async => throw StateError('storage refused')),
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) async {
          bloc.add(LooperTrackEffectsChanged(1, trackChain));
          await pumpEventQueue();
          await pumpEventQueue();
        },
        errors: () => [isA<StateError>()],
        verify: (_) =>
            verify(() => settings.saveTrackFxChain(1, any())).called(1),
      );

      blocTest<LooperBloc, LooperState>(
        'a bus add-of-type composes from the repository, so an add and a '
        'retype dispatched together do not clobber each other',
        setUp: () {
          // The repository is the authority each handler composes from; the
          // fake starts empty and accumulates, exactly like the real one.
          var chain = <TrackEffect>[];
          when(() => repository.trackEffects(0)).thenAnswer((_) => chain);
          when(
            () => repository.setTrackEffects(
              channel: any(named: 'channel'),
              effects: any(named: 'effects'),
            ),
          ).thenAnswer((invocation) {
            chain = invocation.namedArguments[#effects] as List<TrackEffect>;
            return EngineResult.ok;
          });
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc
          ..add(
            const LooperBusEffectAdded(
              FxAddress(stage: FxStage.track),
              type: TrackEffectType.reverb,
            ),
          )
          ..add(
            const LooperBusEffectAdded(
              FxAddress(stage: FxStage.track),
              type: TrackEffectType.echo,
            ),
          ),
        verify: (_) {
          final pushes = verify(
            () => repository.setTrackEffects(
              channel: 0,
              effects: captureAny(named: 'effects'),
            ),
          ).captured.cast<List<TrackEffect>>();
          // Both adds landed, each carrying its own picked type — the second
          // did not overwrite the first from a stale base.
          expect(pushes.last, hasLength(2));
          expect(
            pushes.last.map((fx) => (fx as BuiltInEffect).type),
            [TrackEffectType.reverb, TrackEffectType.echo],
          );
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus edit on the master stage writes the Master insert',
        setUp: () {
          when(
            () => repository.outputEffects(0),
          ).thenReturn([BuiltInEffect(type: TrackEffectType.drive)]);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperBusEffectTypeChanged(
            FxAddress(stage: FxStage.output),
            0,
            TrackEffectType.reverb,
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setOutputEffects(
                      bus: 0,
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          expect(
            (pushed.single as BuiltInEffect).type,
            TrackEffectType.reverb,
          );
          verify(() => settings.saveOutputFxChain(0, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus retype keeps power, identity, placement, and channels',
        setUp: () {
          when(() => repository.trackEffects(0)).thenReturn([
            BuiltInEffect(
              type: TrackEffectType.drive,
              enabled: false,
              slotId: 'slot-a',
              placement: FxPlacement.pre,
              channels: const FxChannels(
                input: FxChannelInput.right,
                output: FxChannelOutput.mono,
                placement: .2,
                level: .8,
              ),
            ),
          ]);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperBusEffectTypeChanged(
            FxAddress(stage: FxStage.track),
            0,
            TrackEffectType.reverb,
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setTrackEffects(
                      channel: 0,
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          final fx = pushed.single as BuiltInEffect;
          expect(fx.type, TrackEffectType.reverb);
          // A retype changes the device, not the power decision or the identity
          // bindings target (D-POWER/R23, A9).
          expect(fx.enabled, isFalse);
          expect(fx.slotId, 'slot-a');
          expect(fx.placement, FxPlacement.pre);
          expect(
            fx.channels,
            const FxChannels(
              input: FxChannelInput.right,
              output: FxChannelOutput.mono,
              placement: .2,
              level: .8,
            ),
          );
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus relink onto another plugin drops the name it replaced',
        setUp: () {
          when(() => repository.outputEffects(0)).thenReturn([
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'old'),
              name: 'Ancient Chorus',
              unavailable: true,
              unsupported: true,
            ),
          ]);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperBusPluginRelinked(
            FxAddress(stage: FxStage.output),
            0,
            PluginRef(format: PluginFormat.vst3, id: 'new'),
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setOutputEffects(
                      bus: 0,
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          // The repository re-resolves it from the catalog. Carrying the old
          // name through leaves the card confidently naming the plugin that
          // was replaced whenever the catalog cannot answer.
          expect((pushed.single as PluginEffect).name, isEmpty);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus relink onto the SAME plugin keeps its name',
        setUp: () {
          when(() => repository.outputEffects(0)).thenReturn([
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'same'),
              name: 'Ancient Chorus',
              unavailable: true,
              unsupported: true,
            ),
          ]);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperBusPluginRelinked(
            FxAddress(stage: FxStage.output),
            0,
            // Accepting a version change: same plugin, so the name it is
            // already showing is the right one whatever the catalog knows.
            PluginRef(format: PluginFormat.vst3, id: 'same', version: 2),
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setOutputEffects(
                      bus: 0,
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          expect((pushed.single as PluginEffect).name, 'Ancient Chorus');
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a different bus plugin keeps entry controls but drops foreign state',
        setUp: () {
          when(() => repository.outputEffects(0)).thenReturn([
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'old', version: 1),
              paramValues: {3: 0.8},
              state: 'blob',
              enabled: false,
              slotId: 'slot-b',
              placement: FxPlacement.pre,
              channels: FxChannels(
                input: FxChannelInput.left,
                output: FxChannelOutput.mono,
                placement: .2,
                level: .7,
              ),
              unavailable: true,
              unsupported: true,
            ),
          ]);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperBusPluginRelinked(
            FxAddress(stage: FxStage.output),
            0,
            PluginRef(format: PluginFormat.vst3, id: 'new', version: 2),
          ),
        ),
        verify: (_) {
          final pushed =
              verify(
                    () => repository.setOutputEffects(
                      bus: 0,
                      effects: captureAny(named: 'effects'),
                    ),
                  ).captured.single
                  as List<TrackEffect>;
          final fx = pushed.single as PluginEffect;
          expect(fx.ref.id, 'new');
          // A different plugin cannot interpret the old plugin's state or
          // parameter ids; entry controls and identity still belong here.
          expect(fx.state, isEmpty);
          expect(fx.paramValues, isEmpty);
          expect(fx.enabled, isFalse);
          expect(fx.slotId, 'slot-b');
          expect(fx.placement, FxPlacement.pre);
          expect(fx.channels.level, .7);
          expect(fx.unavailable, isFalse);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus param change goes through the granular setter, not a re-push',
        setUp: () {
          when(() => repository.trackEffects(0)).thenReturn([
            BuiltInEffect(type: TrackEffectType.reverb),
          ]);
          when(
            () => repository.setTrackEffectParam(
              channel: any(named: 'channel'),
              index: any(named: 'index'),
              param: any(named: 'param'),
              value: any(named: 'value'),
            ),
          ).thenReturn(EngineResult.ok);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
          fxPersistDebounce: Duration.zero,
        ),
        act: (bloc) => bloc.add(
          const LooperBusEffectParamChanged(
            FxAddress(stage: FxStage.track),
            0,
            1,
            0.25,
          ),
        ),
        verify: (_) {
          verify(
            () => repository.setTrackEffectParam(
              channel: 0,
              index: 0,
              param: 1,
              value: 0.25,
            ),
          ).called(1);
          // A whole-chain push would re-send every slot's TYPE, and the engine
          // resets a slot's DSP on every type push — so a knob drag would clear
          // the bus's reverb tails and delay lines at pointer-move rate.
          verifyNever(
            () => repository.setTrackEffects(
              channel: any(named: 'channel'),
              effects: any(named: 'effects'),
            ),
          );
          verify(() => settings.saveTrackFxChain(0, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus PLUGIN param change goes through the granular setter too',
        setUp: () {
          when(() => repository.outputEffects(0)).thenReturn([
            const PluginEffect(
              ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
              unsupported: true,
            ),
          ]);
          when(
            () => repository.setOutputPluginParam(
              bus: 0,
              index: any(named: 'index'),
              paramId: any(named: 'paramId'),
              value: any(named: 'value'),
            ),
          ).thenReturn(EngineResult.ok);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
          fxPersistDebounce: Duration.zero,
        ),
        act: (bloc) => bloc.add(
          const LooperBusPluginParamChanged(
            FxAddress(stage: FxStage.output),
            0,
            7,
            0.5,
          ),
        ),
        verify: (_) {
          verify(
            () => repository.setOutputPluginParam(
              bus: 0,
              index: 0,
              paramId: 7,
              value: 0.5,
            ),
          ).called(1);
          // The plugin itself never instantiates at this stage, so the
          // whole-chain push this used to take would have reset the DSP of
          // the BUILT-INS beside it for nothing.
          verifyNever(
            () => repository.setOutputEffects(
              bus: 0,
              effects: any(named: 'effects'),
            ),
          );
          verify(() => settings.saveOutputFxChain(0, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a re-sync cancels the lane editor polls it would otherwise rebind',
        setUp: () {
          when(
            () => repository.resyncLaneChainFromInput(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
            ),
          ).thenReturn(true);
          when(
            () => repository.isLanePluginEditorOpen(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              index: any(named: 'index'),
            ),
          ).thenReturn(true);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) async {
          bloc.add(const LooperLanePluginEditorOpened(0, 0, 0));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          bloc.add(const LooperLaneChainResyncedFromInput(0, 0));
          await Future<void>.delayed(const Duration(milliseconds: 250));
        },
        verify: (_) {
          // The poll must stop at the re-sync: the chain it was keyed to is
          // gone, so continuing would rebind it to whatever lands at that
          // index. Without the cancel it keeps ticking (~10 Hz).
          verify(
            () => repository.resyncLaneChainFromInput(channel: 0, lane: 0),
          ).called(1);
          verifyNever(
            () => repository.refreshLanePluginParams(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              index: any(named: 'index'),
            ),
          );
        },
      );

      blocTest<LooperBloc, LooperState>(
        'a bus edit past the end of the chain is ignored',
        setUp: () =>
            when(() => repository.trackEffects(0)).thenReturn(const []),
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperBusEffectRemoved(FxAddress(stage: FxStage.track), 3),
        ),
        verify: (_) {
          verifyNever(
            () => repository.setTrackEffects(
              channel: any(named: 'channel'),
              effects: any(named: 'effects'),
            ),
          );
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperLaneEffectEnabledToggled flips the slot and re-persists',
        setUp: () {
          when(
            () => repository.setLaneEffectEnabled(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              index: any(named: 'index'),
              enabled: any(named: 'enabled'),
            ),
          ).thenReturn(EngineResult.ok);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperLaneEffectEnabledToggled(0, 1, 2, enabled: false),
        ),
        verify: (_) {
          verify(
            () => repository.setLaneEffectEnabled(
              channel: 0,
              lane: 1,
              index: 2,
              enabled: false,
            ),
          ).called(1);
          verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperLaneChainEnabledToggled flips the chain flag and re-persists',
        setUp: () {
          when(
            () => repository.setLaneChainEnabled(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
              enabled: any(named: 'enabled'),
            ),
          ).thenReturn(EngineResult.ok);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) =>
            bloc.add(const LooperLaneChainEnabledToggled(0, 1, enabled: false)),
        verify: (_) {
          verify(
            () => repository.setLaneChainEnabled(
              channel: 0,
              lane: 1,
              enabled: false,
            ),
          ).called(1);
          verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperLaneChainResyncedFromInput re-copies the routed input chain',
        setUp: () {
          when(
            () => repository.resyncLaneChainFromInput(
              channel: any(named: 'channel'),
              lane: any(named: 'lane'),
            ),
          ).thenReturn(true);
        },
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(const LooperLaneChainResyncedFromInput(0, 1)),
        verify: (_) {
          // Explicit and user initiated (A6) — the repository owns the copy and
          // notifies back for persistence, so the bloc adds no second write.
          verify(
            () => repository.resyncLaneChainFromInput(channel: 0, lane: 1),
          ).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperTrackEffectEnabledToggled flips the slot and re-persists',
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperTrackEffectEnabledToggled(0, 1, enabled: false),
        ),
        verify: (_) {
          verify(
            () => repository.setTrackEffectEnabled(
              channel: 0,
              index: 1,
              enabled: false,
            ),
          ).called(1);
          verify(() => settings.saveTrackFxChain(0, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperTrackChainEnabledToggled flips the chain flag and '
        're-persists',
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) =>
            bloc.add(const LooperTrackChainEnabledToggled(2, enabled: false)),
        verify: (_) {
          verify(
            () => repository.setTrackChainEnabled(channel: 2, enabled: false),
          ).called(1);
          verify(() => settings.saveTrackFxChain(2, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperOutputEffectsChanged pushes the chain and persists the '
        'envelope',
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(LooperOutputEffectsChanged(0, masterChain)),
        verify: (_) {
          verify(
            () => repository.setOutputEffects(bus: 0, effects: masterChain),
          ).called(1);
          final encoded =
              verify(
                    () => settings.saveOutputFxChain(0, captureAny()),
                  ).captured.single
                  as String;
          expect(decodeFxChain(encoded).entries, masterChain);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperMasterEffectEnabledToggled flips the slot and re-persists',
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) => bloc.add(
          const LooperOutputEffectEnabledToggled(0, 0, enabled: false),
        ),
        verify: (_) {
          verify(
            () => repository.setOutputEffectEnabled(
              bus: 0,
              index: 0,
              enabled: false,
            ),
          ).called(1);
          verify(() => settings.saveOutputFxChain(0, any())).called(1);
        },
      );

      blocTest<LooperBloc, LooperState>(
        'LooperOutputChainEnabledToggled flips the chain flag and '
        're-persists',
        build: () => LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        ),
        act: (bloc) =>
            bloc.add(const LooperOutputChainEnabledToggled(0, enabled: false)),
        verify: (_) {
          verify(
            () => repository.setOutputChainEnabled(bus: 0, enabled: false),
          ).called(1);
          verify(() => settings.saveOutputFxChain(0, any())).called(1);
        },
      );
    });

    blocTest<LooperBloc, LooperState>(
      'incoming ticks never bypass the record owner to persist mode',
      build: () {
        when(() => settings.saveLooperMode(any())).thenAnswer((_) async {});
        when(() => repository.settledLooperMode).thenReturn(LooperMode.band);
        return LooperBloc(
          fxPersistence: FxChainPersistence(looper: repository),
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
        );
      },
      act: (bloc) => bloc
        ..add(
          const LooperStateUpdated(
            LooperState(
              status: EngineStatus(isConnected: true),
              transport: TransportState(looperMode: LooperMode.band),
            ),
          ),
        )
        ..add(
          const LooperStateUpdated(
            LooperState(
              status: EngineStatus(isConnected: true),
              transport: TransportState(
                looperMode: LooperMode.band,
                masterPositionFrames: 10,
              ),
            ),
          ),
        ),
      verify: (_) {
        verifyNever(() => settings.saveLooperMode(any()));
      },
    );
  });

  group('knob-drag persistence is debounced', () {
    // Advance the debounce clock explicitly so event processing cannot race
    // the persistence deadline when the full suite runs under load.
    const debounce = Duration(milliseconds: 30);
    late SettingsRepository settings;

    setUp(() {
      settings = _MockSettingsRepository();
      when(
        () => settings.saveLaneEffects(any(), any(), any()),
      ).thenAnswer((_) async {});
      when(
        () => settings.saveTrackFxChain(any(), any()),
      ).thenAnswer((_) async {});
      when(() => repository.trackEffects(any())).thenReturn(const []);
      when(() => repository.trackChainEnabled(any())).thenReturn(true);
      when(() => repository.outputEffects(0)).thenReturn(const []);
      when(() => repository.outputChainEnabled(0)).thenReturn(true);
      when(() => repository.allLaneChains()).thenReturn(const {});
      when(() => repository.allTrackChains()).thenReturn(const {});
      when(() => repository.allOutputChains()).thenReturn(const {});
      when(() => settings.saveOutputFxChain(0, any())).thenAnswer((_) async {});
      when(() => settings.clearOutputFxChain(any())).thenAnswer((_) async {});
      when(() => settings.saveAllTracksFxChain(any())).thenAnswer((_) async {});
      when(
        () => repository.setTrackEffectParam(
          channel: any(named: 'channel'),
          index: any(named: 'index'),
          param: any(named: 'param'),
          value: any(named: 'value'),
        ),
      ).thenReturn(EngineResult.ok);
      when(
        () => repository.setTrackPluginParam(
          channel: any(named: 'channel'),
          index: any(named: 'index'),
          paramId: any(named: 'paramId'),
          value: any(named: 'value'),
        ),
      ).thenReturn(EngineResult.ok);
    });

    LooperBloc buildDebounced() => LooperBloc(
      fxPersistence: FxChainPersistence(looper: repository),
      mixSettings: testMixSettings(repository),
      repository: repository,
      settings: settings,
      fxPersistDebounce: debounce,
    );

    test(
      'a lane knob drag writes the engine per move and the store once',
      () => fakeAsync((clock) {
        final bloc = buildDebounced();
        try {
          for (var i = 0; i < 8; i++) {
            bloc.add(LooperLaneEffectParamChanged(0, 1, 1, 2, i / 10));
          }
          clock.flushMicrotasks();

          // Every move reached the engine: nothing audible waits on the timer.
          verify(
            () => repository.setLaneEffectParam(
              channel: 0,
              lane: 1,
              index: 1,
              param: 2,
              value: any(named: 'value'),
            ),
          ).called(8);
          verifyNever(() => settings.saveLaneEffects(any(), any(), any()));

          clock.elapse(debounce * 3);

          verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
        } finally {
          unawaited(bloc.close());
          clock.flushMicrotasks();
        }
      }),
    );

    test(
      'a bus knob drag writes the engine per move and the store once',
      () => fakeAsync((clock) {
        final bloc = buildDebounced();
        try {
          for (var i = 0; i < 8; i++) {
            bloc.add(
              LooperBusEffectParamChanged(
                const FxAddress(stage: FxStage.track),
                0,
                1,
                i / 10,
              ),
            );
          }
          clock.flushMicrotasks();

          verify(
            () => repository.setTrackEffectParam(
              channel: 0,
              index: 0,
              param: 1,
              value: any(named: 'value'),
            ),
          ).called(8);
          verifyNever(() => settings.saveTrackFxChain(any(), any()));

          clock.elapse(debounce * 3);

          verify(() => settings.saveTrackFxChain(0, any())).called(1);
        } finally {
          unawaited(bloc.close());
          clock.flushMicrotasks();
        }
      }),
    );

    test(
      'a bus PLUGIN knob drag writes the model per move and the store once',
      () => fakeAsync((clock) {
        when(() => repository.trackEffects(0)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.vst3, id: 'p'),
            unsupported: true,
          ),
        ]);
        final bloc = buildDebounced();
        try {
          for (var i = 0; i < 8; i++) {
            bloc.add(
              LooperBusPluginParamChanged(
                const FxAddress(stage: FxStage.track),
                0,
                7,
                i / 10,
              ),
            );
          }
          clock.flushMicrotasks();

          verify(
            () => repository.setTrackPluginParam(
              channel: 0,
              index: 0,
              paramId: 7,
              value: any(named: 'value'),
            ),
          ).called(8);
          verifyNever(() => settings.saveTrackFxChain(any(), any()));

          clock.elapse(debounce * 3);

          verify(() => settings.saveTrackFxChain(0, any())).called(1);
        } finally {
          unawaited(bloc.close());
          clock.flushMicrotasks();
        }
      }),
    );

    test(
      'drags on two lanes each get their own write',
      () => fakeAsync((clock) {
        final bloc = buildDebounced();
        try {
          bloc
            ..add(const LooperLaneEffectParamChanged(0, 1, 1, 2, 0.2))
            ..add(const LooperLaneEffectParamChanged(0, 1, 1, 2, 0.3))
            ..add(const LooperLaneEffectParamChanged(1, 0, 0, 0, 0.4));
          clock
            ..flushMicrotasks()
            ..elapse(debounce * 3);

          verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
          verify(() => settings.saveLaneEffects(1, 0, any())).called(1);
        } finally {
          unawaited(bloc.close());
          clock.flushMicrotasks();
        }
      }),
    );

    test(
      'a bus PLUGIN drag persists once too',
      () => fakeAsync((clock) {
        when(() => repository.trackEffects(0)).thenReturn(const [
          PluginEffect(
            ref: PluginRef(format: PluginFormat.clap, id: 'p'),
          ),
        ]);
        final bloc = buildDebounced();
        try {
          for (var i = 0; i < 6; i++) {
            bloc.add(
              LooperBusPluginParamChanged(
                const FxAddress(stage: FxStage.track),
                0,
                100,
                i / 10,
              ),
            );
          }
          clock.flushMicrotasks();

          // The engine still sees every move through the granular setter.
          // Re-pushing the whole chain reset the DSP of the built-ins sharing
          // the bus.
          verify(
            () => repository.setTrackPluginParam(
              channel: 0,
              index: 0,
              paramId: 100,
              value: any(named: 'value'),
            ),
          ).called(6);
          verifyNever(
            () => repository.setTrackEffects(
              channel: 0,
              effects: any(named: 'effects'),
            ),
          );
          verifyNever(() => settings.saveTrackFxChain(any(), any()));

          clock.elapse(debounce * 3);

          verify(() => settings.saveTrackFxChain(0, any())).called(1);
        } finally {
          unawaited(bloc.close());
          clock.flushMicrotasks();
        }
      }),
    );

    test(
      'a session load drops a knob write still in flight',
      () => fakeAsync((clock) {
        // The session's chains are the new truth, and the resync sweep clears
        // the keys it has no chain for — a pending write landing after it would
        // resurrect one of them.
        final bloc = buildDebounced()
          ..add(const LooperLaneEffectParamChanged(0, 1, 1, 2, 0.25));
        try {
          clock.flushMicrotasks();

          when(() => repository.sessionRevision).thenReturn(1);
          clock
            ..flushMicrotasks()
            ..elapse(debounce * 3);

          verifyNever(() => settings.saveLaneEffects(any(), any(), any()));
        } finally {
          unawaited(bloc.close());
          clock.flushMicrotasks();
        }
      }),
    );

    test(
      'closing flushes a drag that ended inside the window',
      () => fakeAsync((clock) {
        final bloc = buildDebounced()
          ..add(const LooperLaneEffectParamChanged(0, 1, 1, 2, 0.25));
        clock.flushMicrotasks();
        verifyNever(() => settings.saveLaneEffects(any(), any(), any()));

        unawaited(bloc.close());
        clock.flushMicrotasks();

        verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
      }),
    );

    test(
      'an FX flush writes a drag that ended inside the window',
      () => fakeAsync((clock) {
        // The flush also confirms lane mutes; only the FX write is asserted.
        when(
          () => settings.saveLaneMute(
            any(),
            any(),
            muted: any(named: 'muted'),
          ),
        ).thenAnswer((_) async {});
        final fx = FxChainPersistence(looper: repository);
        final bloc = LooperBloc(
          fxPersistence: fx,
          mixSettings: testMixSettings(repository),
          repository: repository,
          settings: settings,
          fxPersistDebounce: debounce,
        )..add(const LooperLaneEffectParamChanged(0, 1, 1, 2, 0.25));
        try {
          clock.flushMicrotasks();
          verifyNever(() => settings.saveLaneEffects(any(), any(), any()));

          unawaited(fx.flush());
          clock.flushMicrotasks();

          verify(() => settings.saveLaneEffects(0, 1, any())).called(1);
        } finally {
          unawaited(bloc.close());
          clock.flushMicrotasks();
        }
      }),
    );
  });

  blocTest<LooperBloc, LooperState>(
    'LooperPlayAllPressed plays every track with content',
    build: buildBloc,
    seed: () => const LooperState(
      tracks: [
        Track(state: TrackState.playing, lengthFrames: 100),
        Track(channel: 1, lengthFrames: 100, state: TrackState.stopped),
        Track(channel: 2), // empty -> skipped
      ],
    ),
    act: (bloc) => bloc.add(const LooperPlayAllPressed()),
    verify: (_) {
      verify(() => repository.play()).called(1);
      verify(() => repository.play(channel: 1)).called(1);
      verifyNever(() => repository.play(channel: 2));
    },
  );
}
