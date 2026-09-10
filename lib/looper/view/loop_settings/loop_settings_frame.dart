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
    color: context.surface.background,
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
    required this.crumb,
    required this.title,
    required this.onBack,
    required this.onStage,
    required this.children,
    this.titleLeft = 36,
    super.key,
  });

  /// The breadcrumb over the title.
  final String crumb;

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

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return LoopPenCanvas(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: kLoopTopBarHeight,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: surface.line)),
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
                    icon: LucideIcons.arrowLeft,
                    semanticLabel: l10n.loopSettingsBack,
                    onTap: onBack,
                  ),
                ),
                Positioned(
                  left: 124,
                  top: 36,
                  child: AppText(
                    crumb,
                    style: TextStyle(
                      color: surface.textSecondary,
                      fontSize: 20,
                      height: 1,
                    ),
                  ),
                ),
                Positioned(
                  left: 1771,
                  top: 16,
                  child: LoopOutlinedButton(
                    key: const Key('loop_settings_stage'),
                    width: 113,
                    radius: 8,
                    tone: LoopButtonTone.raised,
                    label: l10n.loopSettingsStage,
                    onTap: onStage,
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
                  top: 28,
                  right: 36,
                  height: 72,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AppText(
                      title,
                      key: const Key('loop_settings_title'),
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 42,
                        letterSpacing: -1.1,
                        height: 1,
                      ),
                    ),
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
