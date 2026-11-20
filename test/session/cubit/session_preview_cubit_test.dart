import 'dart:async';
import 'dart:typed_data';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

class _Sessions extends Mock implements SessionRepository;

class _FakeTrack extends Fake implements SessionPreviewTrack;

String _chain(List<TrackEffectType> types) => encodeFxChain(
  FxChainEnvelope(
    entries: [for (final type in types) BuiltInEffect(type: type)],
  ),
);

SessionPreviewTrack _track(int channel) => SessionPreviewTrack(
  channel: channel,
  lengthFrames: 96000,
  baseLengthFrames: 96000,
  bars: 1,
  layers: 1,
  muted: false,
  fxCount: 0,
  liveLayerFile: 'track${channel}_lane0_L0.wav',
);

SessionPreview _preview(
  String id, {
  List<SessionPreviewTrack> tracks = const [],
  List<String> inputChains = const [],
  List<String> trackChains = const [],
  String allTracksChain = '',
  List<String> outputChains = const [],
}) => SessionPreview(
  summary: SessionSummary(id: id, name: id),
  tracks: tracks,
  fxCount: 0,
  sampleRate: 48000,
  inputChains: inputChains,
  trackChains: trackChains,
  allTracksChain: allTracksChain,
  outputChains: outputChains,
);

List<TrackEffectType> _types(List<TrackEffect> effects) => [
  for (final effect in effects) (effect as BuiltInEffect).type,
];

void main() {
  late _Sessions sessions;

  setUpAll(() => registerFallbackValue(_FakeTrack()));

  setUp(() {
    sessions = _Sessions();
    when(() => sessions.readPeaks(any(), any())).thenAnswer((_) async => null);
  });

  group(SessionPreviewCubit, () {
    test('starts with no preview', () {
      final cubit = SessionPreviewCubit(sessions);
      addTearDown(cubit.close);
      expect(cubit.state, const SessionPreviewState());
      expect(cubit.state.status, SessionPreviewStatus.none);
    });

    test('reads the manifest, names the effects by place, then reads each '
        "recording's waveform", () async {
      final preview = _preview(
        'a',
        tracks: [_track(0), _track(2)],
        inputChains: [
          _chain(const [TrackEffectType.delay]),
          _chain(const [TrackEffectType.reverb]),
        ],
        trackChains: [
          _chain(const [TrackEffectType.drive]),
        ],
        allTracksChain: _chain(const [TrackEffectType.compressor]),
        outputChains: [
          _chain(const [TrackEffectType.eq]),
        ],
      );
      when(() => sessions.readPreview('a')).thenAnswer((_) async => preview);
      when(() => sessions.readPeaks('a', any())).thenAnswer((call) async {
        final track = call.positionalArguments[1] as SessionPreviewTrack;
        // The second track's audio does not read: it draws its length only.
        return track.channel == 0 ? Float32List.fromList([0.25, 0.5]) : null;
      });
      final cubit = SessionPreviewCubit(sessions);
      addTearDown(cubit.close);
      final states = <SessionPreviewState>[];
      final sub = cubit.stream.listen(states.add);
      addTearDown(sub.cancel);

      await cubit.show('a');
      await Future<void>.delayed(Duration.zero);

      expect(states.map((s) => s.status), [
        SessionPreviewStatus.loading,
        SessionPreviewStatus.ready,
        SessionPreviewStatus.ready,
      ]);
      // The setup lands before any audio is read.
      expect(states[1].preview, same(preview));
      expect(states[1].peaks, isEmpty);
      final effects = states[1].effects;
      expect(_types(effects.inputs), [
        TrackEffectType.delay,
        TrackEffectType.reverb,
      ]);
      expect(_types(effects.tracks), [TrackEffectType.drive]);
      expect(_types(effects.allTracks), [TrackEffectType.compressor]);
      expect(_types(effects.outputs), [TrackEffectType.eq]);
      expect(states[2].peaks.keys, [0]);
      expect(states[2].peaks[0], [0.25, 0.5]);
    });

    blocTest<SessionPreviewCubit, SessionPreviewState>(
      'a session with no recordings and no effects is ready with neither',
      setUp: () =>
          when(() => sessions.readPreview('a'))
              .thenAnswer((_) async => _preview('a')),
      build: () => SessionPreviewCubit(sessions),
      act: (cubit) => cubit.show('a'),
      verify: (cubit) {
        expect(cubit.state.status, SessionPreviewStatus.ready);
        expect(cubit.state.effects, const SessionPreviewEffects());
        expect(cubit.state.peaks, isEmpty);
        verifyNever(() => sessions.readPeaks(any(), any()));
      },
    );

    blocTest<SessionPreviewCubit, SessionPreviewState>(
      'a session that does not read is unreadable',
      setUp: () =>
          when(() => sessions.readPreview('a')).thenThrow(StateError('gone')),
      build: () => SessionPreviewCubit(sessions),
      act: (cubit) => cubit.show('a'),
      expect: () => const [
        SessionPreviewState(id: 'a', status: SessionPreviewStatus.loading),
        SessionPreviewState(id: 'a', status: SessionPreviewStatus.unreadable),
      ],
    );

    blocTest<SessionPreviewCubit, SessionPreviewState>(
      'a chain that does not decode names nothing and does not fail the '
      'preview',
      setUp: () => when(() => sessions.readPreview('a')).thenAnswer(
        (_) async => _preview(
          'a',
          inputChains: ['not json', '{"entries": 7}'],
          allTracksChain: _chain(const [TrackEffectType.reverb]),
        ),
      ),
      build: () => SessionPreviewCubit(sessions),
      act: (cubit) => cubit.show('a'),
      verify: (cubit) {
        expect(cubit.state.status, SessionPreviewStatus.ready);
        expect(cubit.state.effects.inputs, isEmpty);
        expect(_types(cubit.state.effects.allTracks), [TrackEffectType.reverb]);
      },
    );

    blocTest<SessionPreviewCubit, SessionPreviewState>(
      'showing none clears the preview, and the same session is then read '
      'again',
      setUp: () =>
          when(() => sessions.readPreview('a'))
              .thenAnswer((_) async => _preview('a')),
      build: () => SessionPreviewCubit(sessions),
      act: (cubit) async {
        await cubit.show('a');
        // The same session again while it is shown reads nothing.
        await cubit.show('a');
        await cubit.show(null);
        await cubit.show('a');
      },
      verify: (cubit) {
        verify(() => sessions.readPreview('a')).called(2);
        expect(cubit.state.status, SessionPreviewStatus.ready);
      },
    );

    test('a read that a later request superseded is dropped', () async {
      final first = Completer<SessionPreview>();
      when(() => sessions.readPreview('a')).thenAnswer((_) => first.future);
      when(() => sessions.readPreview('b'))
          .thenAnswer((_) async => _preview('b'));
      final cubit = SessionPreviewCubit(sessions);
      addTearDown(cubit.close);

      final slow = cubit.show('a');
      await cubit.show('b');
      first.complete(_preview('a'));
      await slow;

      expect(cubit.state.id, 'b');
      expect(cubit.state.preview?.summary.id, 'b');
    });

    test('waveforms of a superseded session are dropped', () async {
      final peaks = Completer<Float32List?>();
      when(() => sessions.readPreview('a'))
          .thenAnswer((_) async => _preview('a', tracks: [_track(0)]));
      when(() => sessions.readPeaks('a', any()))
          .thenAnswer((_) => peaks.future);
      final cubit = SessionPreviewCubit(sessions);
      addTearDown(cubit.close);

      final slow = cubit.show('a');
      await Future<void>.delayed(Duration.zero);
      await cubit.show(null);
      peaks.complete(Float32List.fromList([1]));
      await slow;

      expect(cubit.state, const SessionPreviewState());
    });

    test('asking after it is closed does nothing', () async {
      final cubit = SessionPreviewCubit(sessions);
      await cubit.close();

      await cubit.show('a');
      await cubit.show(null);

      verifyNever(() => sessions.readPreview(any()));
    });

    test('closing while a read is in flight emits nothing more', () async {
      final read = Completer<SessionPreview>();
      when(() => sessions.readPreview('a')).thenAnswer((_) => read.future);
      final cubit = SessionPreviewCubit(sessions);

      final pending = cubit.show('a');
      await cubit.close();
      read.complete(_preview('a'));
      await pending;

      expect(cubit.state.status, SessionPreviewStatus.loading);
    });
  });
}
