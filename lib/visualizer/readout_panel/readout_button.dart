import 'dart:async';

import 'package:flutter/material.dart';
import 'package:segno/theme/theme.dart';

/// The smallest side of anything pressable on the readout (#1654): the 7"
/// panel at 640x375 logical px is touched standing, often mid-song.
const double kReadoutMinTarget = 48;

/// How a [ReadoutButton] is drawn.
enum ReadoutButtonStyle {
  /// A choice or a step: the card fill, the accent edge while selected.
  plain,

  /// The one big action of its card (Tap): the accent edge and label.
  outlined,

  /// The panel's way out (Done): filled with the accent.
  filled,
}

/// A button on the readout's Loop panel: acts on release, like every
/// console button, and shows a lock by dimming rather than by hiding.
class ReadoutButton extends StatelessWidget {
  /// Creates a [ReadoutButton].
  const ReadoutButton({
    required this.onPressed,
    this.label,
    this.icon,
    this.semanticLabel,
    this.selected = false,
    this.enabled = true,
    this.style = ReadoutButtonStyle.plain,
    this.fontSize = 16,
    super.key,
  }) : assert(label != null || icon != null, 'a button shows something');

  /// What it does.
  final VoidCallback onPressed;

  /// Its text.
  final String? label;

  /// Its glyph, in place of or before [label].
  final IconData? icon;

  /// What a screen reader says, when [label] alone does not say it.
  final String? semanticLabel;

  /// Whether this is the current choice.
  final bool selected;

  /// Whether it can be pressed now; a lock dims it.
  final bool enabled;

  /// How it is drawn.
  final ReadoutButtonStyle style;

  /// The label's size.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: ReadoutButtonFace(
        label: label,
        icon: icon,
        selected: selected,
        enabled: enabled,
        style: style,
        fontSize: fontSize,
        onTap: enabled ? onPressed : null,
      ),
    );
  }
}

/// A button that acts the moment it is touched, not on release: Tap tempo,
/// where the release would add the finger's dwell to the beat, and the
/// tempo steps, which with [repeat] keep stepping while held.
class ReadoutPressButton extends StatefulWidget {
  /// Creates a [ReadoutPressButton].
  const ReadoutPressButton({
    required this.label,
    required this.onPressed,
    this.semanticLabel,
    this.enabled = true,
    this.repeat = false,
    this.style = ReadoutButtonStyle.plain,
    this.fontSize = 16,
    super.key,
  });

  /// How long a hold waits before it repeats.
  static const Duration repeatDelay = Duration(milliseconds: 400);

  /// How often a hold repeats.
  static const Duration repeatEvery = Duration(milliseconds: 100);

  /// Its text.
  final String label;

  /// What it does, on touch and on each repeat.
  final VoidCallback onPressed;

  /// What a screen reader says, when [label] alone does not say it.
  final String? semanticLabel;

  /// Whether it can be pressed now; a lock dims it.
  final bool enabled;

  /// Whether a hold repeats [onPressed].
  final bool repeat;

  /// How it is drawn.
  final ReadoutButtonStyle style;

  /// The label's size.
  final double fontSize;

  @override
  State<ReadoutPressButton> createState() => _ReadoutPressButtonState();
}

class _ReadoutPressButtonState extends State<ReadoutPressButton> {
  Timer? _hold;
  bool _down = false;

  void _press(PointerDownEvent _) {
    if (!widget.enabled) return;
    setState(() => _down = true);
    widget.onPressed();
    if (!widget.repeat) return;
    _hold?.cancel();
    _hold = Timer(ReadoutPressButton.repeatDelay, () {
      _hold = Timer.periodic(ReadoutPressButton.repeatEvery, (_) {
        if (mounted && widget.enabled) widget.onPressed();
      });
    });
  }

  void _release([PointerEvent? _]) {
    _hold?.cancel();
    _hold = null;
    if (_down && mounted) setState(() => _down = false);
  }

  @override
  void didUpdateWidget(ReadoutPressButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A lock that lands mid-hold ends the hold.
    if (!widget.enabled) _release();
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel ?? widget.label,
      excludeSemantics: true,
      onTap: widget.enabled ? widget.onPressed : null,
      child: Listener(
        onPointerDown: _press,
        onPointerUp: _release,
        onPointerCancel: _release,
        child: ReadoutButtonFace(
          label: widget.label,
          selected: _down,
          enabled: widget.enabled,
          style: widget.style,
          fontSize: widget.fontSize,
        ),
      ),
    );
  }
}

/// How every readout button looks; [onTap] null draws it without a tap of
/// its own (a [ReadoutPressButton] takes its touches itself).
class ReadoutButtonFace extends StatelessWidget {
  /// Creates a [ReadoutButtonFace].
  const ReadoutButtonFace({
    required this.selected,
    required this.enabled,
    required this.style,
    required this.fontSize,
    this.label,
    this.icon,
    this.onTap,
    super.key,
  });

  /// Its text.
  final String? label;

  /// Its glyph.
  final IconData? icon;

  /// The current choice, or held down.
  final bool selected;

  /// Pressable now.
  final bool enabled;

  /// How it is drawn.
  final ReadoutButtonStyle style;

  /// The label's size.
  final double fontSize;

  /// Called on release; null for none.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final (fill, edge, ink) = switch (style) {
      ReadoutButtonStyle.filled => (
        surface.accent,
        surface.accent,
        surface.onAccent,
      ),
      ReadoutButtonStyle.outlined => (
        selected ? surface.accentSurface : surface.card,
        surface.accent,
        surface.accent,
      ),
      ReadoutButtonStyle.plain => (
        selected ? surface.accentSurface : surface.card,
        selected ? surface.accent : surface.borderSubtle,
        selected ? surface.textPrimary : surface.textSecondary,
      ),
    };
    final text = label;
    final glyph = icon;
    return Opacity(
      opacity: enabled ? 1 : surface.disabledOpacity,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: kReadoutMinTarget,
          minHeight: kReadoutMinTarget,
        ),
        child: Material(
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: edge,
              width: style == ReadoutButtonStyle.outlined ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (glyph != null)
                      Icon(glyph, size: fontSize + 4, color: ink),
                    if (glyph != null && text != null) const SizedBox(width: 6),
                    if (text != null)
                      Flexible(
                        child: AppText(
                          text,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: ink,
                            fontSize: fontSize,
                            height: 1.15,
                            fontWeight: style == ReadoutButtonStyle.plain
                                ? FontWeight.w500
                                : FontWeight.w700,
                          ),
                        ),
                      ),
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
