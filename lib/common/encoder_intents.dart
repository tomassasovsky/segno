import 'package:flutter/widgets.dart';

/// The console encoder turned [delta] detents (positive is clockwise) while a
/// control has focus.
///
/// Only a control holding a draft takes it (the accepted rule: press enters a
/// draft, turn adjusts, press commits). Anywhere else the turn moves focus, so
/// controls register an [EncoderDraftAction] that is enabled only mid-draft.
class EncoderTurnIntent extends Intent {
  /// Creates an [EncoderTurnIntent].
  const EncoderTurnIntent(this.delta);

  /// Signed detents; positive is clockwise.
  final int delta;
}

/// Handles [EncoderTurnIntent] while [isDrafting] says a draft is open.
class EncoderDraftAction extends Action<EncoderTurnIntent> {
  /// Creates an [EncoderDraftAction].
  EncoderDraftAction({required this.isDrafting, required this.onTurn});

  /// Whether the control currently holds a draft the turn should adjust.
  final bool Function() isDrafting;

  /// Adjusts the draft by the signed detents.
  final ValueChanged<int> onTurn;

  @override
  bool isEnabled(EncoderTurnIntent intent) => isDrafting();

  @override
  void invoke(EncoderTurnIntent intent) => onTurn(intent.delta);
}
