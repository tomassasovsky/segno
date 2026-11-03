import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/notices/cubit/notices_cubit.dart';
import 'package:segno/notices/model/notice.dart';
import 'package:segno/notices/view/notice_palette.dart';
import 'package:segno/notices/view/notice_sentence.dart';
import 'package:segno/notices/view/select_notices.dart';
import 'package:segno/theme/theme.dart';

/// How long the top bar's centre takes to cross-fade between the session
/// name, a message and a must-act message.
const Duration _fade = Duration(milliseconds: 160);

/// How long a must-act tint takes to come up or go.
const Duration _tintFade = Duration(milliseconds: 240);

/// A top bar's surface (#1562): the rule along its bottom edge, and, while a
/// must-act message stands, the tone's tint over the whole bar with the
/// tone's rule under it.
///
/// It sizes nothing: the bar keeps its own height and its controls stay
/// exactly where they are in every state. Every top bar wraps its content in
/// one: the stage's, the performance views' and the settings frame's.
class NoticeBar extends StatelessWidget {
  /// Creates a [NoticeBar] around a top bar's [child].
  const NoticeBar({required this.child, this.restingRule, super.key});

  /// The bar's content.
  final Widget child;

  /// The rule's colour while no must-act message stands; the stage's
  /// [SurfaceTheme.line] when null.
  final Color? restingRule;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final theme = context.noticeTheme;
    final tone = context.selectNotices<NoticeTone?>(
      (state) => state.banner?.notice.tone,
    );
    final colors = tone == null ? null : NoticePalette.of(surface, tone);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: AnimatedContainer(
            key: const Key('notice_bar_tint'),
            duration: _disabled(context) ? Duration.zero : _tintFade,
            color: colors?.tint ?? Colors.transparent,
          ),
        ),
        Positioned(
          key: const Key('notice_bar_rule'),
          left: 0,
          right: 0,
          bottom: 0,
          height: colors == null ? 1 : theme.ruleThickness,
          child: ColoredBox(
            color: colors?.line ?? restingRule ?? surface.line,
          ),
        ),
        child,
      ],
    );
  }
}

/// The top bar's centre (#1562): the session name ([fallback]) until there
/// is something to say, then the message in its place, on the name's
/// baseline and at its size.
///
/// - A passing message: its icon, the sentence, its one action, and a line
///   on the bar's bottom edge, exactly as wide as the message, that shrinks
///   to its centre as the time runs out.
/// - A must-act message: the dot or icon, the sentence and the one fix,
///   while [NoticeBar] tints the bar. A passing message still takes the
///   centre for its time, then the must-act message comes back.
/// - [showsTrackMessages]: on a bar whose screen shows no track cards (the
///   performance views, the settings pages), a message a track caused is
///   said here, after the track's name.
///
/// Laid out by `TopBarLayout` at the bar's full height.
class NoticeBarMessage extends StatelessWidget {
  /// Creates a [NoticeBarMessage].
  const NoticeBarMessage({
    this.fallback,
    this.showsTrackMessages = false,
    super.key,
  });

  /// What the centre shows when nothing is said: the session name on the
  /// stage, nothing elsewhere.
  final Widget? fallback;

  /// Whether a message a track caused is said here too.
  final bool showsTrackMessages;

  @override
  Widget build(BuildContext context) {
    final message = context.selectNotices<ShownNotice?>(
      (state) => state.held ? null : state.message,
    );
    final banner = context.selectNotices<ShownNotice?>(
      (state) => state.banner,
    );
    final track = showsTrackMessages
        ? context.selectNotices<({int channel, ShownNotice shown})?>(
            (state) => state.latestTrackMessage,
          )
        : null;
    final Widget current;
    if (message != null &&
        (track == null || message.serial > track.shown.serial)) {
      current = _PassingMessage(
        key: ValueKey('message_${message.notice.id}'),
        shown: message,
      );
    } else if (track != null) {
      current = _PassingMessage(
        key: ValueKey('track_${track.channel}_${track.shown.notice.id}'),
        shown: track.shown,
        channel: track.channel,
      );
    } else if (banner != null) {
      current = _MustActMessage(
        key: ValueKey('banner_${banner.notice.id}'),
        notice: banner.notice,
      );
    } else {
      current = KeyedSubtree(
        key: const ValueKey('notice_bar_fallback'),
        child: Center(widthFactor: 1, child: fallback ?? const SizedBox()),
      );
    }
    // One baseline for every string in the centre: the content-based nudge
    // would move an all-caps session name a pixel off a message's line.
    return AppTextOptics(
      opticalOffset: Offset.zero,
      child: AnimatedSwitcher(
        duration: _disabled(context) ? Duration.zero : _fade,
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.passthrough,
          alignment: Alignment.center,
          children: [...previous, ?current],
        ),
        child: current,
      ),
    );
  }
}

/// A message that goes by itself, with its time-left line.
class _PassingMessage extends StatelessWidget {
  const _PassingMessage({required this.shown, this.channel, super.key});

  final ShownNotice shown;

  /// The track that caused it, when the bar says a track's message.
  final int? channel;

  @override
  Widget build(BuildContext context) {
    final notice = shown.notice;
    final colors = NoticePalette.resolve(context, notice.tone);
    final theme = context.noticeTheme;
    return Stack(
      alignment: Alignment.center,
      children: [
        _MessageRow(
          notice: notice,
          lead: noticeIcon(notice) == null
              ? null
              : _Icon(notice: notice, color: colors.mark),
          channel: channel,
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: theme.timeLineThickness,
          child: _TimeLeft(
            key: ValueKey(shown.serial),
            duration: notice.duration,
            color: colors.line,
          ),
        ),
      ],
    );
  }
}

/// A must-act message: the critical dot or the tone's icon, the sentence and
/// the fix. No time line: it stays until its condition is over.
class _MustActMessage extends StatelessWidget {
  const _MustActMessage({required this.notice, super.key});

  final Notice notice;

  @override
  Widget build(BuildContext context) {
    final colors = NoticePalette.resolve(context, notice.tone);
    final theme = context.noticeTheme;
    final lead = notice.tone == NoticeTone.critical && notice.icon == null
        ? DecoratedBox(
            key: const Key('notice_bar_dot'),
            decoration: BoxDecoration(
              color: colors.mark,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(dimension: theme.dotSize),
          )
        : noticeIcon(notice) == null
        ? null
        : _Icon(notice: notice, color: colors.mark);
    return Center(
      widthFactor: 1,
      child: _MessageRow(notice: notice, lead: lead),
    );
  }
}

/// The icon, the sentence and the action, centred on the bar's centre line.
///
/// The sentence is one paragraph — the title, then the body in the
/// secondary colour — so the two share a baseline and the body is the part
/// cut short when the bar has no room.
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.notice, required this.lead, this.channel});

  final Notice notice;
  final Widget? lead;
  final int? channel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final spacing = context.spacing;
    final theme = context.noticeTheme;
    final channel = this.channel;
    final trackName = channel == null
        ? null
        : l10n.trackName(
            context.select<TracksCubit, List<String>>(
              (cubit) => cubit.state.names,
            ),
            channel,
          );
    final title = notice.title(l10n);
    final body = notice.body?.call(l10n);
    final titleStyle = theme.barTitle.copyWith(color: surface.textPrimary);
    // The buttons take at most half of the room: in a bar too narrow for
    // that (a small desktop window) the message keeps its words and drops
    // the buttons, the put-off one first. A button is never the only way.
    return LayoutBuilder(
      builder: (context, constraints) {
        double buttons(Iterable<NoticeAction?> actions) {
          var width = 0.0;
          for (final action in actions.nonNulls) {
            width += spacing.xl + _ActionButton.widthOf(context, action);
          }
          return width;
        }

        final lead = this.lead == null ? 0.0 : spacing.lg + _leadWidth(theme);
        final room = constraints.maxWidth / 2;
        var action = notice.action;
        var secondary = notice.secondary;
        if (lead + buttons([action, secondary]) > room) secondary = null;
        if (lead + buttons([action]) > room) action = null;
        return Semantics(
          liveRegion: true,
          container: true,
          child: Row(
            key: Key('notice_bar_${notice.id}'),
            mainAxisSize: MainAxisSize.min,
            children: [
              if (this.lead case final lead?) ...[
                lead,
                SizedBox(width: spacing.lg),
              ],
              Flexible(
                child: NoticeSentence(
                  key: const Key('notice_bar_text'),
                  title: title,
                  titleStyle: titleStyle,
                  body: body,
                  bodyStyle: theme.barBody.copyWith(
                    color: surface.textSecondary,
                  ),
                  source: trackName,
                  sourceStyle: theme.barTitle.copyWith(
                    color: surface.textSecondary,
                  ),
                ),
              ),
              if (secondary != null) ...[
                SizedBox(width: spacing.xl),
                _ActionButton(
                  action: secondary,
                  tone: notice.tone,
                  quiet: true,
                ),
              ],
              if (action != null) ...[
                SizedBox(width: secondary == null ? spacing.xl : spacing.sm),
                _ActionButton(action: action, tone: notice.tone),
              ],
            ],
          ),
        );
      },
    );
  }

  /// The lead's width: the must-act dot, or an icon at the title's size.
  double _leadWidth(NoticeTheme theme) =>
      notice.tone == NoticeTone.critical && notice.icon == null
      ? theme.dotSize
      : theme.barIconSize;
}

/// The notice's icon at the title's size.
class _Icon extends StatelessWidget {
  const _Icon({required this.notice, required this.color});

  final Notice notice;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      noticeIcon(notice),
      key: const Key('notice_bar_icon'),
      size: context.noticeTheme.barIconSize,
      color: color,
    );
  }
}

/// The message's one action, the height of the bar's own controls.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.action,
    required this.tone,
    this.quiet = false,
  });

  final NoticeAction action;
  final NoticeTone tone;

  /// A way to put the message off: the label alone, in the secondary text
  /// colour, so the fix stays the one button that stands out.
  final bool quiet;

  /// How wide [action]'s button is drawn under [context]'s theme.
  static double widthOf(BuildContext context, NoticeAction action) {
    final spacing = context.spacing;
    final theme = context.noticeTheme;
    final painter = TextPainter(
      text: TextSpan(
        text: action.label(context.l10n),
        style: DefaultTextStyle.of(context).style.merge(theme.barAction),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final label = painter.width;
    painter.dispose();
    final icon = action.icon == null
        ? 0.0
        : theme.barAction.fontSize! + spacing.sm;
    return 2 * spacing.xl + icon + label + 2;
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final spacing = context.spacing;
    final theme = context.noticeTheme;
    final colors = NoticePalette.of(surface, tone);
    final label = action.label(context.l10n);
    final icon = action.icon;
    final labelColor = quiet ? surface.textSecondary : surface.textPrimary;
    return FocusableTapTarget(
      key: action.key,
      semanticLabel: label,
      borderRadius: theme.barActionRadius,
      onTap: action.onPressed,
      child: Container(
        height: theme.barActionHeight,
        padding: EdgeInsets.symmetric(horizontal: spacing.xl),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(theme.barActionRadius),
          border: quiet ? null : Border.all(color: colors.actionLine),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: theme.barAction.fontSize, color: labelColor),
              SizedBox(width: spacing.sm),
            ],
            AppText(
              label,
              maxLines: 1,
              style: theme.barAction.copyWith(color: labelColor),
            ),
          ],
        ),
      ),
    );
  }
}

/// The time-left line: as wide as the message when it appears, shrinking to
/// its centre at a steady rate until the message goes.
class _TimeLeft extends StatelessWidget {
  const _TimeLeft({required this.duration, required this.color, super.key});

  final Duration duration;
  final Color color;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 1, end: 0),
    duration: duration,
    builder: (context, left, _) => Center(
      child: FractionallySizedBox(
        key: const Key('notice_bar_time_left'),
        widthFactor: left,
        heightFactor: 1,
        child: ColoredBox(color: color),
      ),
    ),
  );
}

bool _disabled(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;
