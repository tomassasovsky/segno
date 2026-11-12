import 'package:material_ui/material_ui.dart';

/// Fade + subtle scale-up (96% → 100%) transition shared by
/// [FadeScalePageTransitionsBuilder] (the app-wide theme default) and
/// [desktopPageRoute] (Segno's own asymmetric desktop timing).
class FadeScaleTransition extends StatelessWidget {
  /// Fades and scales [child] in as [animation] runs.
  const new({required this.animation, required this.child, super.key});

  /// The route's animation, 0 to 1 as it opens.
  final Animation<double> animation;

  /// The page.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// A plain fade + subtle scale-up route transition, wired into
/// `AppTheme`'s `pageTransitionsTheme` as the default for every
/// `MaterialPageRoute` push app-wide. Tried Material's "container transform"
/// (`OpenContainer`, from `package:animations`) for the Settings-tray Signal
/// tile first, which morphs the *tapped tile itself* into the destination,
/// but a small unrelated icon visibly stretching into a full page doesn't
/// read as sensible motion the way it does for e.g. a photo thumbnail
/// growing into its detail view. This gives every route the "page opens and
/// fills the screen" feel without that, via plain `Tween`/`CurvedAnimation`
/// — no extra package.
class FadeScalePageTransitionsBuilder extends PageTransitionsBuilder {
  /// Creates a [FadeScalePageTransitionsBuilder].
  const new();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeScaleTransition(animation: animation, child: child);
}

/// Pushes [builder] with the same fade + scale-up transition as
/// [FadeScalePageTransitionsBuilder], but at Segno's own desktop timing
/// (200ms open / 150ms close) rather than `MaterialPageRoute`'s fixed
/// 300ms — `pageTransitionsTheme` can swap a route's transition *look*
/// app-wide, but it can't touch a route's duration, so matching the
/// desktop-tuned timing exactly needs its own route class.
PageRouteBuilder<T> desktopPageRoute<T>(
  WidgetBuilder builder, {
  RouteSettings? settings,
}) => PageRouteBuilder<T>(
  settings: settings,
  transitionDuration: const Duration(milliseconds: 200),
  reverseTransitionDuration: const Duration(milliseconds: 150),
  pageBuilder: (context, animation, secondaryAnimation) => builder(context),
  transitionsBuilder: (context, animation, secondaryAnimation, child) =>
      FadeScaleTransition(animation: animation, child: child),
);
