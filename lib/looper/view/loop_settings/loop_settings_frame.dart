import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
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
                  child: _TopBarButton(
                    key: const Key('loop_settings_back'),
                    width: 64,
                    semanticLabel: l10n.loopSettingsBack,
                    onTap: onBack,
                    child: Icon(
                      LucideIcons.arrowLeft,
                      size: 28,
                      color: surface.textPrimary,
                    ),
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
                  child: _TopBarButton(
                    key: const Key('loop_settings_stage'),
                    width: 113,
                    filled: true,
                    semanticLabel: l10n.loopSettingsStage,
                    onTap: onStage,
                    child: AppText(
                      l10n.loopSettingsStage,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 24,
                        height: 1,
                      ),
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

/// A top-bar button: 64 high, outlined, filled for Stage.
class _TopBarButton extends StatelessWidget {
  const _TopBarButton({
    required this.width,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    this.filled = false,
    super.key,
  });

  final double width;
  final String semanticLabel;
  final VoidCallback onTap;
  final Widget child;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: filled ? surface.cardHigh : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: surface.borderStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: width,
            height: 64,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
