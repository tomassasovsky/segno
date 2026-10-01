import 'package:controller_repository/src/controller_input.dart';
import 'package:equatable/equatable.dart';

/// A qualified console input reaching the application's one dispatcher.
sealed class ControllerDispatchEvent extends Equatable {
  const ControllerDispatchEvent();
}

/// An exact console sample or source-lifetime boundary.
final class ControllerConsoleEvent extends ControllerDispatchEvent {
  /// Carries a console event without interpreting its configuration.
  const ControllerConsoleEvent(this.input);

  /// The physical sample or unavailable identity.
  final ControllerSourceEvent input;

  @override
  List<Object?> get props => [input];
}
