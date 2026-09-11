import 'package:looper_repository/looper_repository.dart';

/// Which track a binding acts on (accepted design, controls 11: "Selected,
/// fixed and all-track scopes are explicit and resolved once").
///
/// A scope is not part of the target — the same chain target means a different
/// chain under each of these — so it rides beside it and is applied when the
/// action fires, never when the switch goes down.
///
/// Resolving at dispatch rather than at press is the whole of "target
/// following". The accepted rule says a pending hold follows the newly
/// selected track until it fires, and stays attached to what it resolved
/// afterwards; a scope read at the moment the action runs does both without
/// any machinery of its own, because the press of a switch carrying a hold is
/// itself deferred to the release.
enum BindingScope {
  /// The track the binding names. A fixed target is resolved by the engine
  /// channel it was bound to, which is a track's identity here — tracks are
  /// never reordered, so the channel is not a visible slot that could drift
  /// under the binding.
  fixed,

  /// Whatever track is selected when the action fires.
  selected;

  /// The scope called [name], or [fixed] for anything unrecognised — a
  /// persisted binding whose scope no longer exists must keep acting on the
  /// track it names rather than silently following the cursor.
  static BindingScope fromName(String? name) {
    for (final scope in BindingScope.values) {
      if (scope.name == name) return scope;
    }
    return BindingScope.fixed;
  }
}

/// Returns [address] with its track coordinate replaced by [cursor] when
/// [scope] is [BindingScope.selected].
///
/// Only the two stages whose index IS a track: the Loop stage's per-lane
/// chains and the Track stage's bus. An input or an output has no relationship
/// to the selected track, so a scope on one of those is honoured as written
/// rather than pointed somewhere arbitrary.
FxAddress resolveBindingAddress(
  FxAddress address,
  BindingScope scope,
  int cursor,
) {
  if (scope != BindingScope.selected) return address;
  return switch (address.stage) {
    FxStage.loop || FxStage.track => FxAddress(
      stage: address.stage,
      index: cursor,
      lane: address.lane,
    ),
    FxStage.input || FxStage.allTracks || FxStage.output => address,
  };
}
