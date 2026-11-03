import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:routing_graph/routing_graph.dart' show FocusableTapTarget;
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/notices/cubit/notices_cubit.dart';
import 'package:segno/notices/model/notice.dart';
import 'package:segno/notices/view/notice_palette.dart';
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
    final tone = context.select<NoticesCubit, NoticeTone?>(
      (cubit) => cubit.state.banner?.notice.tone,
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
    final message = context.select<NoticesCubit, ShownNotice?>(
      (cubit) => cubit.state.held ? null : cubit.state.message,
    );
    final banner = context.select<NoticesCubit, ShownNotice?>(
      (cubit) => cubit.state.banner,
    );
    final track = showsTrackMessages
        ? context.select<NoticesCubit, ({int channel, ShownNotice shown})?>(
            (cubit) => cubit.state.latestTrackMessage,
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
    final action = notice.action;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        key: Key('notice_bar_${notice.id}'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lead case final lead?) ...[lead, SizedBox(width: spacing.lg)],
          Flexible(
            child: AppText.rich(
              TextSpan(
                children: [
                  if (trackName != null)
                    TextSpan(
                      text: trackName,
                      style: theme.barTitle.copyWith(
                        color: surface.textSecondary,
                      ),
                    ),
                  if (trackName != null) _gap(spacing.lg),
                  TextSpan(text: title, style: titleStyle),
                  if (body != null) ...[
                    _gap(spacing.lg),
                    TextSpan(
                      text: body,
                      style: theme.barBody.copyWith(
                        color: surface.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
              key: const Key('notice_bar_text'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (action != null) ...[
            SizedBox(width: spacing.xl),
            _ActionButton(action: action, tone: notice.tone),
          ],
        ],
      ),
    );
  }

  static InlineSpan _gap(double width) => WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: SizedBox(width: width),
  );
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
  const _ActionButton({required this.action, required this.tone});

  final NoticeAction action;
  final NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final spacing = context.spacing;
    final theme = context.noticeTheme;
    final colors = NoticePalette.of(surface, tone);
    final label = action.label(context.l10n);
    final icon = action.icon;
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
          border: Border.all(color: colors.actionLine),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: theme.barAction.fontSize,
                color: surface.textPrimary,
              ),
              SizedBox(width: spacing.sm),
            ],
            AppText(
              label,
              maxLines: 1,
              style: theme.barAction.copyWith(color: surface.textPrimary),
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
