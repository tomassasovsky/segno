import 'package:flutter/widgets.dart';
import 'package:segno/theme/theme.dart';

/// A notice's words on one line (#1562): the track's name when a track
/// caused it, the title, and the body, all on the title's baseline.
///
/// The body is the detail and is shown whole or not at all: when the line
/// has no room for it, it is left out rather than cut, and only a title too
/// long for the room is cut short. So a message never ends in a cut-off
/// second part, in a wide bar or a narrow one.
class NoticeSentence extends StatelessWidget {
  /// Creates a [NoticeSentence].
  const NoticeSentence({
    required this.title,
    required this.titleStyle,
    this.body,
    this.bodyStyle,
    this.source,
    this.sourceStyle,
    this.scale = 1,
    super.key,
  });

  /// The message.
  final String title;

  /// The message's style.
  final TextStyle titleStyle;

  /// The detail, shown when it fits.
  final String? body;

  /// The detail's style.
  final TextStyle? bodyStyle;

  /// The name of the track that caused it, before the title.
  final String? source;

  /// The track name's style.
  final TextStyle? sourceStyle;

  /// The factor a proportional surface (the readout) draws at: the gaps
  /// follow its type.
  final double scale;

  @override
  Widget build(BuildContext context) {
    final gap = context.spacing.lg * scale;
    final source = this.source;
    final body = this.body;
    return LayoutBuilder(
      builder: (context, constraints) {
        final ambient = DefaultTextStyle.of(context).style;
        final direction = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        double width(String text, TextStyle? style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: ambient.merge(style)),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        final lead = source == null ? 0.0 : width(source, sourceStyle) + gap;
        final showsBody =
            body != null &&
            lead + width(title, titleStyle) + gap + width(body, bodyStyle) <=
                constraints.maxWidth;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (source != null) ...[
              AppText(
                source,
                key: const Key('notice_sentence_source'),
                maxLines: 1,
                softWrap: false,
                style: sourceStyle,
              ),
              SizedBox(width: gap),
            ],
            Flexible(
              child: AppText(
                title,
                key: const Key('notice_sentence_title'),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (showsBody) ...[
              SizedBox(width: gap),
              AppText(
                body,
                key: const Key('notice_sentence_body'),
                maxLines: 1,
                softWrap: false,
                style: bodyStyle,
              ),
            ],
          ],
        );
      },
    );
  }
}
