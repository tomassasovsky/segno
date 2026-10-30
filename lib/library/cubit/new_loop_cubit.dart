import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/session/session.dart';

part 'new_loop_state.dart';

/// The New loop sheet's choice of what the new loop starts with (#1513 D1),
/// and, for Ed's setup, its sounds read and checked against the effects
/// budget before Start new loop is offered (D3).
class NewLoopCubit extends Cubit<NewLoopState> {
  /// Creates the sheet's state, with Empty tracks chosen. [loadEdsSetup]
  /// reads Ed's setup's sounds (null when one is missing) and [fits] checks
  /// a template against the effects budget on the live chains.
  NewLoopCubit({
    required Future<NewLoopTemplate?> Function() loadEdsSetup,
    required bool Function(NewLoopTemplate template) fits,
  }) : _loadEdsSetup = loadEdsSetup,
       _fits = fits,
       super(const NewLoopState());

  final Future<NewLoopTemplate?> Function() _loadEdsSetup;
  final bool Function(NewLoopTemplate template) _fits;

  /// Chooses [start]. Ed's setup reads its sounds the first time, and is
  /// checked against the budget each time it is chosen. Empty tracks never
  /// waits for them.
  Future<void> choose(NewLoopStart start) async {
    emit(state.copyWith(start: start));
    if (start != NewLoopStart.edsSetup) return;
    var template = state.template;
    if (template == null) {
      if (state.eds == EdsSetupStatus.loading) return;
      emit(state.copyWith(eds: EdsSetupStatus.loading));
      try {
        template = await _loadEdsSetup();
      } on Object {
        // A sound that cannot be read is a missing one, not a load that
        // never ends.
        template = null;
      }
      if (isClosed) return;
      if (template == null) {
        emit(state.copyWith(eds: EdsSetupStatus.missing));
        return;
      }
    }
    emit(
      state.copyWith(
        template: template,
        eds: _fits(template) ? EdsSetupStatus.ready : EdsSetupStatus.overBudget,
      ),
    );
  }
}
