import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';

import '../../../helpers/helpers.dart';

class _MockLooperBloc extends MockBloc<LooperEvent, LooperState>
    implements LooperBloc {}

void main() {
  late _MockLooperBloc bloc;

  setUp(() {
    bloc = _MockLooperBloc();
    whenListen(
      bloc,
      const Stream<LooperState>.empty(),
      initialState: const LooperState(
        tracks: [Track(state: TrackState.playing, lengthFrames: 48000)],
      ),
    );
  });

  Future<void> pump(WidgetTester tester, FxDestination destination) =>
      tester.pumpApp(
        BlocProvider<LooperBloc>.value(
          value: bloc,
          child: Scaffold(body: FxTrackSolo(destination: destination)),
        ),
      );

  testWidgets('a recorded track and its parts carry the Solo', (tester) async {
    for (final destination in [
      const FxDestination.recordedTrack(0),
      FxDestination.recordedTrack(0, part: FxTrackPart.part(1)),
    ]) {
      await pump(tester, destination);
      expect(find.byKey(const Key('fx_track_solo')), findsOneWidget);
    }
  });

  testWidgets('no other destination has a Solo', (tester) async {
    for (final destination in const [
      FxDestination.liveInput(0),
      FxDestination.allTracks(),
      FxDestination.output(0),
    ]) {
      await pump(tester, destination);
      expect(
        find.byKey(const Key('fx_track_solo')),
        findsNothing,
        reason: '$destination',
      );
    }
  });
}
