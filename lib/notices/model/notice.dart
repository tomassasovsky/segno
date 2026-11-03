import 'package:flutter/widgets.dart';
import 'package:segno/l10n/l10n.dart';

/// How much a notice matters (#1562).
///
/// - [neutral]: everything else: an explanation, an offer to undo.
/// - [success]: a confirmation of what the player just did.
/// - [warning]: it works, but not as expected, or a press did nothing.
/// - [critical]: sound stopped, nothing is heard, or material is lost. Only
///   a must-act message is critical; a message that goes by itself never is.
enum NoticeTone { neutral, success, warning, critical }

/// A notice's words, resolved where it is drawn so it follows the locale.
typedef NoticeText = String Function(AppLocalizations l10n);

/// A notice's one action: the fix for a must-act message, or a shortcut
/// (Undo) on one that goes by itself. Never the only way to do it.
@immutable
class NoticeAction {
  /// Creates a [NoticeAction].
  const NoticeAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.key,
  });

  /// The button's label.
  final NoticeText label;

  /// What the button does.
  final VoidCallback onPressed;

  /// An icon before the label.
  final IconData? icon;

  /// The button's key, for tests and the encoder.
  final Key? key;
}

/// One message: what the top bar, a track's card or the readout says.
///
/// [id] names the cause. One cause shows one notice: a message with the id of
/// a standing must-act message is dropped, and raising a must-act message
/// takes the place of a passing one with its id.
@immutable
class Notice {
  /// Creates a [Notice].
  const Notice({
    required this.id,
    required this.title,
    this.tone = NoticeTone.neutral,
    this.body,
    this.overline,
    this.icon,
    this.action,
    this.secondary,
    this.explains = false,
  });

  /// The cause.
  final String id;

  /// How much it matters.
  final NoticeTone tone;

  /// The message.
  final NoticeText title;

  /// A second part: the consequence or what to do.
  final NoticeText? body;

  /// A track's message: the short cause over it.
  final NoticeText? overline;

  /// An icon in place of the tone's own.
  final IconData? icon;

  /// The one action.
  final NoticeAction? action;

  /// A must-act message's way to put it off ("Not now"), beside [action].
  /// Only where the condition can wait (#1352's power-cycle prompt, the
  /// effects held off).
  final NoticeAction? secondary;

  /// A one-time explanation, which stays the longest.
  final bool explains;

  /// How long a message that goes by itself stays: four seconds, six for a
  /// warning, eight with an action, ten for a one-time explanation.
  Duration get duration {
    if (explains) return const Duration(seconds: 10);
    if (action != null) return const Duration(seconds: 8);
    if (tone == NoticeTone.warning) return const Duration(seconds: 6);
    return const Duration(seconds: 4);
  }
}
