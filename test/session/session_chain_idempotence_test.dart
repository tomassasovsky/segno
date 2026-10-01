import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/session/session_mapping.dart';
import 'package:segno_engine/segno_engine.dart' show MockAudioEngine;
import 'package:session_repository/session_repository.dart';

/// The chain decoder and slot-id invariants that only a save → load → save
/// cycle can prove (flow SC-6), exercised through the REAL bloc-layer mapping
/// and a REAL `LooperRepository` — the mint-once slot-id rule lives at the
/// repository's chain write boundary, so a mapping-only test cannot see it.
///
/// No audio and no file I/O: chains exist independently of content, so a
/// manifest carrying chains and no tracks is enough (and keeps the engine a
/// plain in-memory mock).
void main() {
  late MockAudioEngine engine;
  late LooperRepository looper;

  setUp(() {
    engine = MockAudioEngine();
    looper = LooperRepository(engine: engine)
      ..startEngine(const EngineConfig(sampleRate: 48000));
  });

  tearDown(() => looper.dispose());

  /// A manifest carrying [chains] and nothing else — the shape `rigFromBundle`
  /// consumes.
  SessionBundle bundleOf(SessionChains chains) => (
    session: Session(
      sampleRate: 48000,
      channels: 1,
      baseLengthFrames: 0,
      tracks: const [],
      laneChains: chains.laneChains,
      monitors: chains.monitors,
      trackChains: chains.trackChains,
      masterChain: chains.masterChain,
    ),
    laneStems: const {},
  );

  Future<void> load(SessionBundle bundle) => looper.applySession(
    rigFromBundle(bundle),
    clearPollInterval: Duration.zero,
  );

  test(
    'bare-array FX payloads mint slot ids once, then save -> load -> '
    'save is byte-idempotent across all four stages (flow SC-6)',
    () async {
      // A current Session object carrying bare-array FX payloads. The manifest
      // reader itself accepts only schema 8; this exercises the FX decoder.
      final bareChains = (
        session: Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 0,
          tracks: const [],
          laneChains: [
            SessionLaneChain(
              channel: 0,
              lane: 0,
              encoded: encodeTrackEffects([
                BuiltInEffect(type: TrackEffectType.drive),
                BuiltInEffect(type: TrackEffectType.reverb),
              ]),
            ),
          ],
          monitors: [
            SessionMonitor(
              input: 0,
              mode: 'on',
              outputMask: 0x3,
              volume: 1,
              muted: false,
              encoded: encodeTrackEffects([
                BuiltInEffect(type: TrackEffectType.filter),
              ]),
            ),
          ],
        ),
        laneStems: const <(int, int), List<Never>>{},
      );

      await load(bareChains);

      // Mint-once, part 1: decoded entries came back with stable ids.
      final minted = [
        for (final fx in looper.laneEffects(0, 0)) fx.slotId,
      ];
      expect(minted, everyElement(isNotNull));
      expect(minted.toSet(), hasLength(2)); // unique within the session

      // Stage the two bus chains, one disabled, so the round-trip covers all
      // four stages.
      looper
        ..setTrackEffects(
          channel: 0,
          effects: [BuiltInEffect(type: TrackEffectType.delay)],
        )
        ..setTrackChainEnabled(channel: 1, enabled: false)
        ..setMasterEffects(
          effects: [BuiltInEffect(type: TrackEffectType.filter)],
        )
        ..setMasterChainEnabled(enabled: false)
        ..setLaneChainEnabled(channel: 0, lane: 0, enabled: false);

      final first = chainsFromLooper(looper);
      await load(bundleOf(first));
      final second = chainsFromLooper(looper);

      // Mint-once, part 2: the ids that survived the reload are the SAME ones
      // — a re-mint per load would silently dangle every stored binding.
      expect([for (final fx in looper.laneEffects(0, 0)) fx.slotId], minted);

      // Byte-idempotent: the second save is indistinguishable from the first,
      // for every stage.
      expect(
        [for (final c in second.laneChains) (c.channel, c.lane, c.encoded)],
        [for (final c in first.laneChains) (c.channel, c.lane, c.encoded)],
      );
      expect(
        [for (final m in second.monitors) m.encoded],
        [for (final m in first.monitors) m.encoded],
      );
      expect(
        [for (final c in second.trackChains) (c.channel, c.encoded)],
        [for (final c in first.trackChains) (c.channel, c.encoded)],
      );
      expect(second.masterChain, first.masterChain);

      // And the flags themselves survived, not just the bytes.
      expect(looper.laneChainEnabled(0, 0), isFalse);
      expect(looper.trackChainEnabled(1), isFalse);
      expect(looper.masterChainEnabled, isFalse);
    },
  );

  test(
    'bare-array FX payload has the same audible fingerprint after decode: '
    'the enabled defaults fold as audible and slot ids are excluded from the '
    'fingerprint (flow SC-6)',
    () async {
      final entries = [
        BuiltInEffect(type: TrackEffectType.drive),
        BuiltInEffect(type: TrackEffectType.reverb, params: const [0.3, 0.7]),
      ];
      // The bare-array FX decoder assigns current defaults and slot ids while
      // preserving the chain's audible fingerprint.
      final bare = encodeTrackEffects(entries);
      final before = fxChainFingerprint(entries);

      await load((
        session: Session(
          sampleRate: 48000,
          channels: 1,
          baseLengthFrames: 0,
          tracks: const [],
          laneChains: [
            SessionLaneChain(channel: 0, lane: 0, encoded: bare),
          ],
        ),
        laneStems: const {},
      ));

      expect(looper.laneChainFingerprint(0, 0), before);
      // Minting ids did not move the fingerprint (it folds sound, not
      // identity), which is exactly why only the idempotence test above can
      // catch a re-mint regression.
      expect(looper.laneEffects(0, 0).first.slotId, isNotNull);
      expect(looper.laneChainFingerprint(0, 0), before);
    },
  );
}
