import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
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

/// One Loop settings page as the pen draws it: the top bar (Back, the
/// breadcrumb, Stage), the title, and the page's own content positioned in
/// pen pixels under the title.
///
/// [titleLeft] is the pen's title inset: 36 on the hub, mode, recording and
/// tempo pages, 100 on the scoped editors.
class LoopSettingsFrame extends StatelessWidget {
  /// Creates a [LoopSettingsFrame].
  const LoopSettingsFrame({
    required this.title,
    required this.onBack,
    required this.onStage,
    required this.children,
    this.crumb,
    this.tabs,
    this.titleLeft = 36,
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

  /// The page content, positioned in the 1920 x 984 main area under the
  /// top bar.
  final List<Widget> children;

  /// The title's inset from the left edge.
  final double titleLeft;

  /// The page's own actions, drawn at the title's right edge (the Pedals
  /// page's Cancel and Save). Inset by [titleLeft] on the right so the row
  /// reads as one titlebar rather than a heading with a stray button.
  final Widget? actions;

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
    return LoopPenCanvas(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: kLoopTopBarHeight,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: surface.frameRule)),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 36,
                  top: 16,
                  child: LoopOutlinedButton(
                    key: const Key('loop_settings_back'),
                    width: 64,
                    radius: 8,
                    tone: LoopButtonTone.frame,
                    icon: LucideIcons.chevronLeft,
                    semanticLabel: l10n.loopSettingsBack,
                    onTap: onBack,
                  ),
                ),
                if (tabs case final tabs?)
                  Positioned(left: 124, top: 16, child: tabs),
                if (crumb case final crumb?)
                  Positioned(
                    left: 124,
                    top: 36,
                    child: AppText(
                      crumb,
                      style: TextStyle(
                        color: surface.frameCrumb,
                        fontFamily: SurfaceTheme.frameFont,
                        fontSize: 20,
                        letterSpacing: 0,
                        height: 1,
                      ),
                    ),
                  ),
                Positioned(
                  left: 1771,
                  top: 16,
                  // Arimo's line metrics put a label centred in a 64 high
                  // box 2 px under where the pen's text box sets it.
                  child: AppTextOptics(
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
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned(
                  left: titleLeft,
                  top: row.top,
                  right: 36,
                  height: row.height,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AppText(
                      title,
                      key: const Key('loop_settings_title'),
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
                    right: titleLeft,
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
        ],
      ),
    );
  }
}
