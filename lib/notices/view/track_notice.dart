import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/notices/cubit/notices_cubit.dart';
import 'package:segno/notices/model/notice.dart';
import 'package:segno/notices/view/notice_palette.dart';
import 'package:segno/notices/view/select_notices.dart';
import 'package:segno/theme/theme.dart';

/// The ring colour of [channel]'s card while a message it caused is up, or
/// null when there is none (#1562).
///
/// Every card that shows a track — the Track view's column, the Wave view's
/// row and the Mixer's strip — reads it, so a track's message looks the same
/// whichever view is up.
Color? trackNoticeRing(BuildContext context, int channel) {
  final tone = context.selectNotices<NoticeTone?>(
    (state) => state.trackMessage(channel)?.notice.tone,
  );
  return tone == null ? null : NoticePalette.resolve(context, tone).line;
}

/// A message one track caused, over that track's card (#1562): the short
/// cause in the tone colour, the message, and what to do, centred in the
/// card's free area at one type ramp on every card.
///
/// It takes the place of the area's own content ([child]: the meter, the
/// waveform) for as long as the message is up, and gives it back as it was:
/// the content keeps its state behind the message, unseen. The message
/// itself takes no touch, so a tap still reaches the card. Only display
/// goes behind it, never a control: the Mixer's strip, which is all
/// controls, rings and leaves the words to the top bar.
///
/// While the area says something more pressing ([yields]: an action queued
/// on the track) the message steps aside and the card only rings.
class TrackNotice extends StatelessWidget {
  /// Creates a [TrackNotice] for [channel] over [child].
  const new({
    required this.channel,
    required this.child,
    this.yields = false,
    super.key,
  });

  /// The track whose message this shows.
  final int channel;

  /// The area's own content.
  final Widget child;

  /// Whether the area's own content wins over the message for now.
  final bool yields;

  @override
  Widget build(BuildContext context) {
    final message = context.selectNotices<ShownNotice?>(
      (state) => state.trackMessage(channel),
    );
    final shown = yields ? null : message;
    return Stack(
      fit: StackFit.expand,
      children: [
        Visibility(
          visible: shown == null,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: child,
        ),
        if (shown != null) _TrackMessage(channel: channel, shown: shown),
      ],
    );
  }
}

/// The message itself, centred in the area.
class _TrackMessage extends StatelessWidget {
  const new({required this.channel, required this.shown});

  final int channel;
  final ShownNotice shown;

  @override
  Widget build(BuildContext context) {
    final notice = shown.notice;
    final l10n = context.l10n;
    final surface = context.surface;
    final spacing = context.spacing;
    final theme = context.noticeTheme;
    final colors = NoticePalette.of(surface, notice.tone);
    final overline = notice.overline?.call(l10n);
    final body = notice.body?.call(l10n);
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        container: true,
        child: KeyedSubtree(
          key: Key('track_notice_$channel'),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: spacing.lg),
            // The console's cards all hold the whole message at full size;
            // a smaller window (a desktop, a test) cuts it at the area's
            // edges rather than shrinking the type.
            child: ClipRect(
              child: OverflowBox(
                minHeight: 0,
                maxHeight: double.infinity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (overline != null) ...[
                      AppText(
                        overline.toUpperCase(),
                        key: Key('track_notice_overline_$channel'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.trackOverline.copyWith(color: colors.mark),
                      ),
                      SizedBox(height: spacing.lg),
                    ],
                    AppText(
                      notice.title(l10n),
                      key: Key('track_notice_title_$channel'),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.trackTitle.copyWith(
                        color: surface.textPrimary,
                      ),
                    ),
                    if (body != null) ...[
                      SizedBox(height: spacing.sm),
                      AppText(
                        body,
                        key: Key('track_notice_body_$channel'),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.trackBody.copyWith(
                          color: surface.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
