import 'package:flutter/widgets.dart';

/// The one unfinished numeric edit on a Loop settings page. Back cancels it
/// before leaving the page; opening another target cancels it as well.
class LoopEditCoordinator {
  VoidCallback? _cancel;

  /// Whether a control currently owns a draft.
  bool get hasDraft => _cancel != null;

  /// Gives a control ownership of the unfinished edit.
  void begin(VoidCallback cancel) {
    this.cancel();
    _cancel = cancel;
  }

  /// Clears the registration after commit or a local cancellation.
  void finish(VoidCallback cancel) {
    if (_cancel == cancel) _cancel = null;
  }

  /// Discards the current draft, returning whether one existed.
  bool cancel() {
    final pending = _cancel;
    if (pending == null) return false;
    _cancel = null;
    pending();
    return true;
  }
}

/// Makes page Back and scope selection share one cancellation boundary.
class LoopEditScope extends InheritedWidget {
  /// Creates a scope for the active Loop settings route.
  const LoopEditScope({
    required this.coordinator,
    required super.child,
    super.key,
  });

  /// The current page's draft owner.
  final LoopEditCoordinator coordinator;

  /// Returns the nearest coordinator, if this control is on a Loop page.
  static LoopEditCoordinator? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LoopEditScope>()?.coordinator;

  @override
  bool updateShouldNotify(LoopEditScope oldWidget) =>
      coordinator != oldWidget.coordinator;
}
