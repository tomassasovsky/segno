import 'package:flutter/material.dart';
import 'package:segno/notices/model/notice.dart';
import 'package:segno/notices/view/notice_palette.dart';
import 'package:segno/theme/theme.dart';

/// A condition of the page it stands on (#1562): the tone's tint with its
/// edge down the left, the sentence, and the page's own way to resolve it,
/// if it has one. It stands for as long as the condition holds; the page
/// decides that.
///
/// The same tones and type as the top bar's messages, so the Effects
/// pages' "effects are off", Loop settings' lock and the Updates page's
/// rollback read as one family.
class InlineNotice extends StatelessWidget {
  /// Creates an [InlineNotice].
  const InlineNotice({
    required this.message,
    this.tone = NoticeTone.warning,
    this.action,
    super.key,
  });

  /// What holds on this page.
  final String message;

  /// How much it matters.
  final NoticeTone tone;

  /// The page's button that resolves it.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final spacing = context.spacing;
    final theme = context.noticeTheme;
    final colors = NoticePalette.of(surface, tone);
    final action = this.action;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: spacing.xl,
          vertical: spacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.tint,
          border: Border(
            left: BorderSide(color: colors.line, width: theme.edgeThickness),
          ),
        ),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Expanded(
              child: AppText(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.inlineText.copyWith(color: surface.textPrimary),
              ),
            ),
            if (action != null) ...[SizedBox(width: spacing.lg), action],
          ],
        ),
      ),
    );
  }
}
