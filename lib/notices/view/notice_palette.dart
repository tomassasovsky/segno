import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/notices/model/notice.dart';
import 'package:segno/theme/theme.dart';

/// The colours a notice of one [NoticeTone] is drawn in, all from
/// [SurfaceTheme] tokens.
///
/// - [mark]: the icon, the must-act dot and a track message's overline.
/// - [line]: the time-left line, a track card's ring and the must-act rule.
/// - [tint]: the fill of a bar or band that holds a must-act message.
/// - [actionLine]: the edge of the message's action button.
@immutable
class NoticePalette {
  const NoticePalette._({
    required this.mark,
    required this.line,
    required this.tint,
    required this.actionLine,
  });

  /// The colours for [tone] in [surface].
  ///
  /// A confirmation's line stays the neutral grey, as the approved top-bar
  /// design draws it: the green is the check mark's, not the time's.
  factory NoticePalette.of(SurfaceTheme surface, NoticeTone tone) =>
      switch (tone) {
        NoticeTone.neutral => NoticePalette._(
          mark: surface.textSecondary,
          line: surface.textSecondary,
          tint: surface.cardHigh,
          actionLine: surface.borderStrong,
        ),
        NoticeTone.success => NoticePalette._(
          mark: surface.success,
          line: surface.textSecondary,
          tint: surface.successSurface,
          actionLine: surface.borderStrong,
        ),
        NoticeTone.warning => NoticePalette._(
          mark: surface.warning,
          line: surface.warning,
          tint: surface.warningTint,
          actionLine: surface.warningLine,
        ),
        NoticeTone.critical => NoticePalette._(
          mark: surface.rec,
          line: surface.rec,
          tint: surface.recTint,
          actionLine: surface.recLine,
        ),
      };

  /// The colours for [tone] under [context]'s theme.
  factory NoticePalette.resolve(BuildContext context, NoticeTone tone) =>
      NoticePalette.of(context.surface, tone);

  final Color mark;
  final Color line;
  final Color tint;
  final Color actionLine;
}

/// The icon a notice of [tone] shows when it names none: a check for a
/// confirmation, a triangle for a warning, and nothing for the rest (a
/// must-act critical message shows a dot instead).
IconData? noticeToneIcon(NoticeTone tone) => switch (tone) {
  NoticeTone.success => LucideIcons.circleCheck,
  NoticeTone.warning => LucideIcons.triangleAlert,
  NoticeTone.neutral || NoticeTone.critical => null,
};

/// The icon [notice] shows: its own, else its tone's.
IconData? noticeIcon(Notice notice) =>
    notice.icon ?? noticeToneIcon(notice.tone);
