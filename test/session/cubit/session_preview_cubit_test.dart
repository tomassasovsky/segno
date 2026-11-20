import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:segno/session/session.dart';
import 'package:session_repository/session_repository.dart';

class _Sessions extends Mock implements SessionRepository;

String _chain(List<TrackEffectType> types) => encodeFxChain(
  FxChainEnvelope(
    entries: [for (final type in types) BuiltInEffect(type: type)],
  ),
);

SessionPreview _preview(
  String id, {
  List<String> inputChains = const [],
  List<String> trackChains = const [],
  String allTracksChain = '',
  List<String> outputChains = const [],
}) => SessionPreview(
  summary: SessionSummary(id: id, name: id),
  tracks: const [],
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

  setUp(() => sessions = _Sessions());

  group(SessionPreviewCubit, () {
    test('starts with no preview', () {
      final cubit = SessionPreviewCubit(sessions);
      addTearDown(cubit.close);
      expect(cubit.state, const SessionPreviewState());
      expect(cubit.state.status, SessionPreviewStatus.none);
    });

    test('reads the manifest and names the effects in signal order: the '
        'inputs, the tracks, All tracks, the outputs', () async {
      final preview = _preview(
        'a',
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
      ]);
      expect(states[1].preview, same(preview));
      expect(_types(states[1].effects), [
        TrackEffectType.delay,
        TrackEffectType.reverb,
        TrackEffectType.drive,
        TrackEffectType.compressor,
        TrackEffectType.eq,
      ]);
    });

    blocTest<SessionPreviewCubit, SessionPreviewState>(
      'a session with no effects is ready with none',
      setUp: () =>
          when(() => sessions.readPreview('a'))
              .thenAnswer((_) async => _preview('a')),
      build: () => SessionPreviewCubit(sessions),
      act: (cubit) => cubit.show('a'),
      verify: (cubit) {
        expect(cubit.state.status, SessionPreviewStatus.ready);
        expect(cubit.state.effects, isEmpty);
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
        expect(_types(cubit.state.effects), [TrackEffectType.reverb]);
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

    test('a read that ends after none was asked for is dropped', () async {
      final read = Completer<SessionPreview>();
      when(() => sessions.readPreview('a')).thenAnswer((_) => read.future);
      final cubit = SessionPreviewCubit(sessions);
      addTearDown(cubit.close);

      final slow = cubit.show('a');
      await cubit.show(null);
      read.complete(_preview('a'));
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
