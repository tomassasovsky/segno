import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/looper/model/fx_destination.dart';

part 'fx_state.dart';

/// Where the Effects page is pointed, and what each strip remembers.
///
/// Selection only: every effect, flag and parameter the page edits belongs to
/// the looper repository, reached through `LooperBloc`. What lives here is the
/// part of the page that is not rig state — which source is being looked at,
/// and where each strip was left.
///
/// Per-kind memory rather than one selection, because the pen's Sound type row
/// switches between three strips that each keep their place: coming back to
/// Live inputs after a look at Outputs lands on the input that was open, not
/// on the first one (accepted design, "Back and context switches preserve each
/// strip's position").
class FxCubit extends Cubit<FxState> {
  /// Creates an [FxCubit] pointed at [initial].
  FxCubit({FxDestination? initial})
    : super(
        initial == null ? const FxState() : FxState.at(initial),
      );

  /// Moves to [kind], landing on the source that kind was left on.
  void showKind(FxDestinationKind kind) {
    if (state.kind == kind) return;
    emit(state.copyWith(kind: kind));
  }

  /// Selects [index] within the current kind.
  ///
  /// Switching tracks resets the part to Whole track: a part index means a
  /// lane of the track it was chosen on, and carrying it to another track
  /// would open a stranger's second part — or nothing at all.
  void selectSource(int index) {
    if (state.index == index) return;
    emit(
      state.kind == FxDestinationKind.recordedTrack
          ? state.copyWith(index: index, part: FxTrackPart.whole)
          : state.copyWith(index: index),
    );
  }

  /// Selects which part of the current recorded track is being edited.
  void selectPart(FxTrackPart part) {
    if (state.kind != FxDestinationKind.recordedTrack) return;
    emit(state.copyWith(part: part));
  }

  /// Points the page at [destination] outright — for an entry from somewhere
  /// that already knows the target (an FX marker, a pedal assignment).
  void show(FxDestination destination) => emit(
    state.copyWith(
      kind: destination.kind,
      index: destination.index,
      part: destination.part,
    ),
  );
}
