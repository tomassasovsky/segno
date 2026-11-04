import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/common/top_bar_layout.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/theme/theme.dart';

/// The pen's canvas for every Loop settings page: 1920 x 1080.
const Size kLoopPenSize = Size(1920, 1080);

/// The pen's top bar height on these pages.
const double kLoopTopBarHeight = 96;

/// Lays [child] out at the pen's size and scales it down uniformly when the
/// window is smaller, so the appliance draws the pen 1:1 and a desktop window
/// sees the same page smaller instead of overflowing.
class LoopPenCanvas extends StatelessWidget {
  /// Creates a [LoopPenCanvas].
  const LoopPenCanvas({required this.child, super.key});

  /// The page, laid out in pen pixels.
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.surface.frameBackground,
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox.fromSize(size: kLoopPenSize, child: child),
      ),
    ),
  );
}

/// The width of each of [count] cards [gap] apart so that the row spans
/// [width] (#1590), never narrower than [minWidth]: past that the cards keep
/// [minWidth] and the row scrolls.
double fillingCardWidth({
  required double width,
  required int count,
  required double gap,
  required double minWidth,
}) {
  if (count < 1) return minWidth;
  final share = (width - (count - 1) * gap) / count;
  return share < minWidth ? minWidth : share;
}

/// One settings page: the top bar (Back, the breadcrumb, Stage), the title,
/// and the page's own content positioned in pen pixels under the title.
///
/// Every page shares one inset (#1590): the top bar, the title and the
/// content all sit [insetOf] in from the canvas's left and right edges. The
/// page's [children] are positioned inside that content box, so a page
/// starts its content at `left: 0` and fills it with `right: 0`.
class LoopSettingsFrame extends StatelessWidget {
  /// Creates a [LoopSettingsFrame].
  const LoopSettingsFrame({
    required this.title,
    required this.onBack,
    required this.onStage,
    required this.children,
    this.crumb,
    this.tabs,
    this.titleRight = 0,
    this.actions,
    super.key,
  }) : assert(
         (crumb == null) != (tabs == null),
         'a page shows a breadcrumb or section tabs, not both',
       );

  /// The breadcrumb over the title.
  final String? crumb;

  /// Section tabs drawn where the breadcrumb goes (the Library's Sessions
  /// and Audio), for a page whose sections are peers rather than a path.
  final Widget? tabs;

  /// The page title (the pen's h1).
  final String title;

  /// Leaves this page.
  final VoidCallback onBack;

  /// Returns to the stage.
  final VoidCallback onStage;

  /// The page content, positioned in the content box under the top bar:
  /// the 984 high main area less [insetOf] at each side.
  final List<Widget> children;

  /// Where the title ends, measured from the content box's right edge. A
  /// page that puts its own controls in the title row ends the title before
  /// them, and a title too long for what is left ends in an ellipsis rather
  /// than running under them.
  final double titleRight;

  /// The page's own actions, drawn at the content box's right edge in the
  /// title row (the Pedals page's Cancel and Save), so the row reads as one
  /// titlebar rather than a heading with a stray button.
  final Widget? actions;

  /// The one inset of every page in the frame: the top bar's Back and
  /// Stage, the title and the content sit this far in from the canvas's
  /// left and right edges. The spacing scale's xxl (32).
  static double insetOf(BuildContext context) => context.spacing.xxl;

  /// The content box's width: the canvas less [insetOf] at each side.
  static double contentWidthOf(BuildContext context) =>
      kLoopPenSize.width - 2 * insetOf(context);

  /// The width of one of two equal columns across the content box, [gap]
  /// apart (an xl gap unless the page has its own). The second starts at
  /// this width plus the gap.
  static double halfWidthOf(BuildContext context, {double? gap}) =>
      (contentWidthOf(context) - (gap ?? context.spacing.xl)) / 2;

  /// The title row in the main area, as the pen draws its two kinds. A row
  /// that carries actions (Settings' Power, the Pedals pages' Cancel and
  /// Save) is 64 high at 30, the height of its buttons, and its title has no
  /// tracking; a title alone is 72 high at 28 and tracked -1.1. The title is
  /// centred in either.
  static ({double top, double height, double tracking}) _titleRow({
    required bool actions,
  }) => actions
      ? (top: 30, height: 64, tracking: 0)
      : (top: 28, height: 72, tracking: -1.1);

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final row = _titleRow(actions: actions != null);
    final inset = insetOf(context);
    return LoopPenCanvas(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: kLoopTopBarHeight,
            child: NoticeBar(
              restingRule: surface.frameRule,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                child: TopBarLayout(
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LoopOutlinedButton(
                        key: const Key('loop_settings_back'),
                        width: 64,
                        radius: 8,
                        tone: LoopButtonTone.frame,
                        icon: LucideIcons.chevronLeft,
                        semanticLabel: l10n.loopSettingsBack,
                        onTap: onBack,
                      ),
                      if (tabs != null || crumb != null)
                        SizedBox(width: context.spacing.xl),
                      ?tabs,
                      if (crumb case final crumb?)
                        AppText(
                          crumb,
                          style: TextStyle(
                            color: surface.frameCrumb,
                            fontFamily: SurfaceTheme.frameFont,
                            fontSize: 20,
                            letterSpacing: 0,
                            height: 1,
                          ),
                        ),
                    ],
                  ),
                  // The app's messages (#1562). A settings page draws no
                  // track cards, so a track's message is said here too.
                  centre: const NoticeBarMessage(),
                  // Arimo's line metrics put a label centred in a 64 high
                  // box 2 px under where the pen's text box sets it.
                  trailing: AppTextOptics(
                    opticalOffset: const Offset(0, -2),
                    child: LoopOutlinedButton(
                      key: const Key('loop_settings_stage'),
                      width: 113,
                      radius: 8,
                      tone: LoopButtonTone.frameRaised,
                      label: l10n.loopSettingsStage,
                      onTap: onStage,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: row.top,
                    right: titleRight,
                    height: row.height,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AppText(
                        title,
                        key: const Key('loop_settings_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: surface.frameText,
                          fontFamily: SurfaceTheme.frameFont,
                          fontSize: 42,
                          letterSpacing: row.tracking,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                  if (actions != null)
                    Positioned(
                      right: 0,
                      top: row.top,
                      height: row.height,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: actions,
                      ),
                    ),
                  ...children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
