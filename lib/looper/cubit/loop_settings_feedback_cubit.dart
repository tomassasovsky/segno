import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:looper_repository/looper_repository.dart';

/// Refusals and the identity of the session open in Loop settings.
typedef LoopSettingsFeedback = ({int refused, int sessionRevision});

/// Tracks refused settings changes and session replacement while the route is
/// open. Each refusal is a new notification, including identical failures.
class LoopSettingsFeedbackCubit extends Cubit<LoopSettingsFeedback> {
  /// Subscribes to the repository's immediate and callback refusals.
  LoopSettingsFeedbackCubit({required LooperRepository repository})
    : super((refused: 0, sessionRevision: repository.sessionRevision)) {
    _failureSubscription = repository.lengthSettingsFailures.listen((_) {
      emit((
        refused: state.refused + 1,
        sessionRevision: state.sessionRevision,
      ));
    });
    _rigSubscription = repository.rigReplaced.listen((_) {
      emit((
        refused: state.refused,
        sessionRevision: repository.sessionRevision,
      ));
    });
  }

  late final StreamSubscription<EngineResult> _failureSubscription;
  late final StreamSubscription<void> _rigSubscription;

  @override
  Future<void> close() async {
    await _failureSubscription.cancel();
    await _rigSubscription.cancel();
    await super.close();
  }
}
