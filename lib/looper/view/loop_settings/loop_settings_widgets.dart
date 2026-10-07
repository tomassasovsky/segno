import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_edit_scope.dart';
import 'package:segno/theme/theme.dart';

/// A single stop for keyboard and future physical encoder focus. Enter is the
/// encoder press seam; the amber outline is distinct from the blue selection.
class LoopFocusable extends StatelessWidget {
  /// Creates a focus stop around one actionable control.
  const LoopFocusable({
    required this.child,
    required this.onActivate,
    this.enabled = true,
    this.radius = 8,
    this.autofocus = false,
    super.key,
  });

  /// Whether this stop takes focus when its page opens.
  final bool autofocus;

  /// The visual control.
  final Widget child;

  /// Activates this control on Enter or Space.
  final VoidCallback onActivate;

  /// Disabled readouts do not enter focus.
  final bool enabled;

  /// Outline radius.
  final double radius;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: enabled,
    autofocus: autofocus,
    onKeyEvent: (_, event) {
      if (!enabled || event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter ||
          event.logicalKey == LogicalKeyboardKey.space) {
        onActivate();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Builder(
      builder: (context) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: Focus.of(context).hasFocus
                ? context.surface.encoderFocus
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: child,
      ),
    ),
  );
}

/// The pen's choice button: a rounded box that fills when selected.
///
/// Sizes are the pen's, passed by the page that places the button, since the
/// same box is 232 wide on the timing row, 330 on the click rows and 504 on
/// the recording rows.
class LoopChoiceButton extends StatelessWidget {
  /// Creates a [LoopChoiceButton].
  const LoopChoiceButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.width,
    this.height = 96,
    this.icon,
    this.enabled = true,
    this.fontSize = 24,
    super.key,
  });

  /// The choice's name.
  final String label;

  /// Whether this is the current choice.
  final bool selected;

  /// Makes this the choice; ignored while not [enabled].
  final VoidCallback onTap;

  /// The pen's width for this button.
  final double width;

  /// The pen's height for this button.
  final double height;

  /// An optional glyph before the label (the Loop/Once and tempo choices).
  final IconData? icon;

  /// Whether the choice can be taken right now (a lock dims it).
  final bool enabled;

  /// The label size (24 on most rows, 28 on the iconed choices).
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final textColor = selected ? surface.textPrimary : surface.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : surface.disabledOpacity,
        child: LoopFocusable(
          enabled: enabled,
          onActivate: onTap,
          child: Material(
            color: selected ? surface.accentSurface : surface.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: selected ? surface.accent : surface.borderSubtle,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              canRequestFocus: false,
              onTap: enabled ? onTap : null,
              child: SizedBox(
                width: width,
                height: height,
                // A label longer than its box scales down rather than
                // overflowing: the pen's boxes fit the English labels, and a
                // translation may not.
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 36, color: textColor),
                          const SizedBox(width: 24),
                        ],
                        AppText(
                          label,
                          style: TextStyle(
                            color: textColor,
                            fontSize: fontSize,
                            height: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of equal [LoopChoiceButton]s sharing [width] with [gap] between.
class LoopChoiceRow<T> extends StatelessWidget {
  /// Creates a [LoopChoiceRow].
  const LoopChoiceRow({
    required this.values,
    required this.labelOf,
    required this.keyOf,
    required this.selected,
    required this.onSelected,
    required this.width,
    this.height = 96,
    this.gap = 24,
    this.iconOf,
    this.enabled = true,
    this.fontSize = 24,
    super.key,
  });

  /// The choices, in order.
  final List<T> values;

  /// Each choice's name.
  final String Function(T value) labelOf;

  /// Each button's widget key.
  final Key Function(T value) keyOf;

  /// The confirmed choice, or null while its value is unavailable.
  final T? selected;

  /// Called with the tapped choice.
  final ValueChanged<T> onSelected;

  /// The pen's width of the whole row.
  final double width;

  /// The pen's button height.
  final double height;

  /// The pen's gap between buttons.
  final double gap;

  /// An optional glyph per choice.
  final IconData? Function(T value)? iconOf;

  /// Whether the choices can be taken right now.
  final bool enabled;

  /// The label size.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final buttonWidth = (width - gap * (values.length - 1)) / values.length;
    return SizedBox(
      width: width,
      height: height,
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            LoopChoiceButton(
              key: keyOf(values[i]),
              label: labelOf(values[i]),
              selected: values[i] == selected,
              onTap: () => onSelected(values[i]),
              width: buttonWidth,
              height: height,
              icon: iconOf?.call(values[i]),
              enabled: enabled,
              fontSize: fontSize,
            ),
          ],
        ],
      ),
    );
  }
}

/// A section heading (the pen's h2).
class LoopSectionLabel extends StatelessWidget {
  /// Creates a [LoopSectionLabel].
  const LoopSectionLabel(this.text, {this.fontSize = 28, super.key});

  /// The heading.
  final String text;

  /// 28 on most rows, 32 on the playback and audio fields.
  final double fontSize;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    style: TextStyle(
      color: context.surface.textPrimary,
      fontSize: fontSize,
      height: 1,
    ),
  );
}

/// Where a scoped field's value comes from.
enum LoopFieldOrigin {
  /// The field follows the default.
  isDefault,

  /// The field carries its own value.
  custom,

  /// The field is the shared default in Multi and cannot be overridden.
  sharedInMulti,
}

/// A scoped field's heading with its origin tag under or beside it.
class LoopFieldLabel extends StatelessWidget {
  /// Creates a [LoopFieldLabel].
  const LoopFieldLabel({
    required this.title,
    this.origin,
    this.fontSize = 28,
    this.originBeside = false,
    super.key,
  });

  /// The field's name.
  final String title;

  /// The origin tag; `null` on the defaults scope, where every field is the
  /// default.
  final LoopFieldOrigin? origin;

  /// The heading size.
  final double fontSize;

  /// Draws the tag beside the heading (the record timing heading) rather
  /// than under it.
  final bool originBeside;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final tag = switch (origin) {
      null => null,
      LoopFieldOrigin.isDefault => l10n.loopOriginDefault,
      LoopFieldOrigin.custom => l10n.loopOriginCustom,
      LoopFieldOrigin.sharedInMulti => l10n.loopSharedInMulti,
    };
    final tagText = tag == null
        ? null
        : AppText(
            tag,
            key: const Key('loop_field_origin'),
            style: TextStyle(
              color: origin == LoopFieldOrigin.custom
                  ? surface.textPrimary
                  : surface.textTertiary,
              fontSize: 20,
              height: 1,
            ),
          );
    final heading = LoopSectionLabel(title, fontSize: fontSize);
    if (tagText == null) return heading;
    if (originBeside) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          heading,
          const SizedBox(width: 24),
          Padding(padding: const EdgeInsets.only(bottom: 2), child: tagText),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading,
        const SizedBox(height: 10),
        tagText,
      ],
    );
  }
}

/// The pen's "Use default" button: 172 x 64, outlined.
class LoopUseDefaultButton extends StatelessWidget {
  /// Creates a [LoopUseDefaultButton].
  const LoopUseDefaultButton({required this.onTap, super.key});

  /// Removes the field's override, or null while its owner is unavailable.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => LoopOutlinedButton(
    width: 172,
    label: context.l10n.loopUseDefault,
    onTap: onTap,
  );
}

/// How a [LoopOutlinedButton] is filled.
enum LoopButtonTone {
  /// Transparent with the strong border (the pen's plain action button).
  outlined,

  /// The raised card fill with the strong border (a secondary action on a
  /// page, such as a disabled Done).
  raised,

  /// The card fill with the subtle border (the time signature chip).
  card,

  /// The accent fill and text (a dialog's confirming action).
  accent,

  /// The settings frame's Back: no fill, the frame's control line, and the
  /// frame's icon colour.
  frame,

  /// The settings frame's Stage: the frame's control fill and line, its
  /// label in the frame's text colour and typeface.
  frameRaised,
}

/// The pen's 64-high action button in its four fills: a label with an
/// optional trailing glyph, or a glyph alone.
class LoopOutlinedButton extends StatelessWidget {
  /// Creates a [LoopOutlinedButton].
  const LoopOutlinedButton({
    required this.width,
    required this.onTap,
    this.label,
    this.icon,
    this.leadingIcon,
    this.trailingIcon,
    this.semanticLabel,
    this.semanticValue,
    this.tone = LoopButtonTone.outlined,
    this.height = 64,
    this.fontSize = 24,
    this.radius = 7,
    this.borderColor,
    super.key,
  });

  /// The line around the button, when its pen node draws one other than
  /// its tone's.
  final Color? borderColor;

  /// The pen's width.
  final double width;

  /// The action.
  final VoidCallback? onTap;

  /// The button text, when it has one.
  final String? label;

  /// The button glyph, when it shows one instead of a label.
  final IconData? icon;

  /// A glyph BEFORE the label, for a button that is named and marked at
  /// once (the Effects page's Add effects). Unlike [icon], which replaces the
  /// label outright.
  final IconData? leadingIcon;

  /// A glyph after the label.
  final IconData? trailingIcon;

  /// The accessible name when the button shows only a glyph, or when the
  /// label is a value rather than a name.
  final String? semanticLabel;

  /// The accessible value, for a button whose label is the value it opens.
  final String? semanticValue;

  /// The fill.
  final LoopButtonTone tone;

  /// The pen's height.
  final double height;

  /// The label size.
  final double fontSize;

  /// The pen's corner radius.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final fill = switch (tone) {
      LoopButtonTone.outlined => Colors.transparent,
      LoopButtonTone.raised => surface.cardHigh,
      LoopButtonTone.card => surface.card,
      LoopButtonTone.accent => surface.accent,
      LoopButtonTone.frame => Colors.transparent,
      LoopButtonTone.frameRaised => surface.frameControlFill,
    };
    final border =
        borderColor ??
        switch (tone) {
          LoopButtonTone.card => surface.borderSubtle,
          LoopButtonTone.accent => surface.accent,
          LoopButtonTone.frame ||
          LoopButtonTone.frameRaised => surface.frameControlLine,
          _ => surface.borderStrong,
        };
    final foreground = switch (tone) {
      LoopButtonTone.accent => surface.onAccent,
      LoopButtonTone.frame => surface.frameIcon,
      LoopButtonTone.frameRaised => surface.frameText,
      _ => surface.textPrimary,
    };
    // The pen draws every accent action's label bold (`Done`, `Open session`,
    // `Start new loop`, `Use as backing`); the other fills stay regular.
    final text = TextStyle(
      color: foreground,
      fontFamily: tone == LoopButtonTone.frameRaised
          ? SurfaceTheme.frameFont
          : null,
      // The pen sets the frame's label untracked; the theme's labels carry
      // 0.25.
      letterSpacing: tone == LoopButtonTone.frameRaised ? 0 : null,
      fontSize: fontSize,
      fontWeight: tone == LoopButtonTone.accent ? FontWeight.w700 : null,
      height: 1,
    );
    // A button with nothing to do READS as having nothing to do. A control
    // that looks live and is inert is the working-but-silent control the
    // accepted design says to explain rather than present.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel ?? label,
      value: semanticValue,
      child: LoopFocusable(
        enabled: onTap != null,
        radius: radius,
        onActivate: onTap ?? () {},
        child: Material(
          color: fill,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: SizedBox(
              width: width,
              height: height,
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 28, color: foreground)
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (leadingIcon != null) ...[
                                Icon(leadingIcon, size: 28, color: foreground),
                                const SizedBox(width: 12),
                              ],
                              AppText(label ?? '', style: text),
                              if (trailingIcon != null) ...[
                                const SizedBox(width: 12),
                                Icon(trailingIcon, size: 28, color: foreground),
                              ],
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A scoped field's origin tag: `null` on the defaults scope, where every
/// field is the default; on a track scope the shared default in Multi, the
/// track's own value, or the default it follows.
LoopFieldOrigin? scopedOrigin({
  required bool scoped,
  required bool custom,
  bool shared = false,
}) {
  if (!scoped) return null;
  if (shared) return LoopFieldOrigin.sharedInMulti;
  return custom ? LoopFieldOrigin.custom : LoopFieldOrigin.isDefault;
}

/// The one-sentence note under a field (the pen's length-note).
class LoopNote extends StatelessWidget {
  /// Creates a [LoopNote].
  const LoopNote(this.text, {this.tone = LoopNoteTone.plain, super.key});

  /// The sentence.
  final String text;

  /// How the sentence reads.
  final LoopNoteTone tone;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return AppText(
      text,
      style: TextStyle(
        color: switch (tone) {
          LoopNoteTone.plain => surface.textSecondary,
          LoopNoteTone.error => surface.rec,
        },
        fontSize: 24,
        height: 1.2,
      ),
    );
  }
}

/// What a [LoopNote] is saying.
enum LoopNoteTone {
  /// A statement about the control beside it.
  plain,

  /// Something is wrong with the rig, and the sentence says what to do.
  error,
}

/// The lock banner a capture puts over a page whose settings it freezes:
/// 68 high, a warning edge on the left, one sentence.
class LoopLockBanner extends StatelessWidget {
  /// Creates a [LoopLockBanner].
  const LoopLockBanner({required this.text, required this.width, super.key});

  /// The reason.
  final String text;

  /// The pen's width.
  final double width;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      key: const Key('loop_lock_banner'),
      width: width,
      height: 68,
      padding: const EdgeInsets.only(left: 27),
      decoration: BoxDecoration(
        color: surface.warning.withValues(alpha: 0.14),
        border: Border(left: BorderSide(color: surface.warning, width: 3)),
      ),
      alignment: Alignment.centerLeft,
      child: AppText(
        text,
        style: TextStyle(
          color: surface.textPrimary,
          fontSize: 24,
          height: 1,
        ),
      ),
    );
  }
}

/// The scoped editors' Tracks / Defaults / 1-8 selector, 1720 wide: the
/// "Tracks" heading, Defaults, one button per track, and the selected track's
/// name at the right.
class LoopScopeSelector extends StatelessWidget {
  /// Creates a [LoopScopeSelector].
  const LoopScopeSelector({
    required this.trackNames,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  /// The tracks' names, in channel order.
  final List<String> trackNames;

  /// The selected channel, or `null` for the defaults.
  final int? selected;

  /// Called with the tapped channel, or `null` for the defaults.
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    final name = selected == null || selected! >= trackNames.length
        ? null
        : trackNames[selected!];
    return SizedBox(
      width: 1720,
      height: 64,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 16,
            child: LoopSectionLabel(l10n.loopScopeTracks),
          ),
          Positioned(
            left: 328,
            top: 0,
            child: LoopChoiceButton(
              key: const Key('loop_scope_defaults'),
              label: l10n.loopScopeDefaults,
              selected: selected == null,
              onTap: () {
                LoopEditScope.maybeOf(context)?.cancel();
                onSelected(null);
              },
              width: 144,
              height: 64,
            ),
          ),
          for (var i = 0; i < trackNames.length; i++)
            Positioned(
              left: 328 + 156 + 76.0 * i,
              top: 0,
              child: Semantics(
                label: l10n.loopScopeTrack(i + 1),
                child: LoopChoiceButton(
                  key: Key('loop_scope_track_$i'),
                  label: '${i + 1}',
                  selected: selected == i,
                  onTap: () {
                    LoopEditScope.maybeOf(context)?.cancel();
                    onSelected(i);
                  },
                  width: 64,
                  height: 64,
                ),
              ),
            ),
          if (name != null)
            Positioned(
              right: 0,
              top: 18,
              width: 400,
              child: AppText(
                name,
                key: const Key('loop_scope_track_name'),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: surface.textSecondary,
                  fontSize: 24,
                  height: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The bars stepper: touch minus/plus commit immediately. Focus the count,
/// press Enter to draft, turn with arrows, press Enter to commit or Back to
/// restore its opening value and ownership.
class LoopStepper extends StatefulWidget {
  /// Creates a [LoopStepper].
  const LoopStepper({
    required this.value,
    required this.unit,
    required this.onDecrement,
    required this.onIncrement,
    required this.onCommit,
    required this.decrementLabel,
    required this.incrementLabel,
    this.enabled = true,
    super.key,
  });

  /// The current committed count.
  final int value;

  /// Its unit, under the count.
  final String unit;

  /// Touch minus.
  final VoidCallback? onDecrement;

  /// Touch plus.
  final VoidCallback? onIncrement;

  /// Commits a keyboard draft.
  final ValueChanged<int> onCommit;

  /// The minus button's accessible name.
  final String decrementLabel;

  /// The plus button's accessible name.
  final String incrementLabel;

  /// Whether the stepper can be used right now.
  final bool enabled;

  @override
  State<LoopStepper> createState() => _LoopStepperState();
}

class _LoopStepperState extends State<LoopStepper> {
  int? _draft;
  LoopEditCoordinator? _coordinator;

  void _cancel() {
    if (_draft == null) return;
    _coordinator?.finish(_cancel);
    setState(() => _draft = null);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      if (_draft == null) {
        _coordinator = LoopEditScope.maybeOf(context);
        _coordinator?.begin(_cancel);
        setState(() => _draft = widget.value);
      } else {
        final value = _draft!;
        _coordinator?.finish(_cancel);
        setState(() => _draft = null);
        widget.onCommit(value);
      }
      return KeyEventResult.handled;
    }
    if (_draft == null) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    final delta = switch (key) {
      LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.arrowUp => 1,
      LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowDown => -1,
      _ => 0,
    };
    if (delta == 0) return KeyEventResult.ignored;
    setState(() => _draft = (_draft! + delta).clamp(1, 64));
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _coordinator?.finish(_cancel);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: widget.enabled ? 1 : surface.disabledOpacity,
      child: SizedBox(
        width: 396,
        height: 112,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 24,
              child: LoopOutlinedButton(
                key: const Key('loop_stepper_minus'),
                width: 64,
                icon: LucideIcons.minus,
                semanticLabel: widget.decrementLabel,
                onTap: widget.enabled ? widget.onDecrement : null,
              ),
            ),
            Positioned(
              left: 88,
              top: 0,
              width: 220,
              height: 112,
              child: Focus(
                canRequestFocus: widget.enabled,
                onKeyEvent: _handleKey,
                onFocusChange: (focused) {
                  if (!focused && _draft != null) _cancel();
                },
                child: Builder(
                  builder: (context) => Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Focus.of(context).hasFocus
                            ? surface.encoderFocus
                            : Colors.transparent,
                        width: 3,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        AppText(
                          '${_draft ?? widget.value}',
                          key: const Key('loop_stepper_value'),
                          style: TextStyle(
                            color: surface.textPrimary,
                            fontSize: 68,
                            fontFamily: SurfaceTheme.monoFont,
                            height: 1,
                          ),
                        ),
                        const SizedBox(width: 15),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: AppText(
                            widget.unit,
                            style: TextStyle(
                              color: surface.textSecondary,
                              fontSize: 24,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 332,
              top: 24,
              child: LoopOutlinedButton(
                key: const Key('loop_stepper_plus'),
                width: 64,
                icon: LucideIcons.plus,
                semanticLabel: widget.incrementLabel,
                onTap: widget.enabled ? widget.onIncrement : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pen's 56 px slider. Touch commits on release; Enter begins a
/// keyboard/encoder draft, arrows preview it, Enter commits, and Back cancels.
class LoopSlider extends StatefulWidget {
  /// Creates a [LoopSlider].
  const LoopSlider({
    required this.value,
    required this.onChanged,
    required this.width,
    required this.semanticLabel,
    this.onChangeEnd,
    this.onDoubleTap,
    this.onEditCancel,
    this.semanticValueBuilder,
    this.keyboardStep = 0.01,
    this.max = 1,
    this.enabled = true,
    super.key,
  });

  /// Position in `0..1`.
  final double value;

  /// The highest position the slider can reach, in `0..1`. A touch, a drag and
  /// a keyboard step all stop here, and a [value] above it is drawn here.
  final double max;

  /// Previews a position without persisting it.
  final ValueChanged<double> onChanged;

  /// Commits a touch or keyboard edit.
  final ValueChanged<double>? onChangeEnd;

  /// Restores the meaningful default or inheritance.
  final VoidCallback? onDoubleTap;

  /// Restores the opening value after an unfinished keyboard edit.
  final ValueChanged<double>? onEditCancel;

  /// One encoder detent expressed as a fraction of this slider's range.
  final double keyboardStep;

  /// Whether this control is available.
  final bool enabled;

  /// The pen's width.
  final double width;

  /// The accessible name.
  final String semanticLabel;

  /// The announced value when the slider represents units other than percent.
  /// When absent, existing Loop settings retain their normalized readout.
  final String Function(double value)? semanticValueBuilder;

  @override
  State<LoopSlider> createState() => _LoopSliderState();
}

class _LoopSliderState extends State<LoopSlider> {
  double? _touchPreview;
  double? _keyboardDraft;
  double? _opening;
  LoopEditCoordinator? _coordinator;

  double _fraction(double dx) => (dx / widget.width).clamp(0.0, widget.max);

  void _beginEdit() {
    if (!widget.enabled) return;
    _coordinator = LoopEditScope.maybeOf(context);
    _coordinator?.begin(_cancelEdit);
    setState(() {
      _opening = widget.value;
      _keyboardDraft = widget.value;
    });
  }

  void _finishEdit() {
    final draft = _keyboardDraft;
    if (draft == null) return;
    _coordinator?.finish(_cancelEdit);
    setState(() {
      _keyboardDraft = null;
      _opening = null;
    });
    widget.onChanged(draft);
    widget.onChangeEnd?.call(draft);
  }

  void _cancelEdit() {
    final opening = _opening;
    if (opening == null) return;
    _coordinator?.finish(_cancelEdit);
    setState(() {
      _keyboardDraft = null;
      _opening = null;
    });
    widget.onEditCancel?.call(opening);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _keyboardDraft == null ? _beginEdit() : _finishEdit();
      return KeyEventResult.handled;
    }
    if (_keyboardDraft == null) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    final delta = switch (key) {
      LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.arrowUp => 1,
      LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowDown => -1,
      _ => 0,
    };
    if (delta == 0) return KeyEventResult.ignored;
    final next = (_keyboardDraft! + delta * widget.keyboardStep).clamp(
      0.0,
      widget.max,
    );
    setState(() => _keyboardDraft = next);
    widget.onChanged(next);
    return KeyEventResult.handled;
  }

  /// A screen reader's increase or decrease: one keyboard step, committed at
  /// once, since an assistive adjustment has no draft to confirm.
  void _semanticStep(int direction) {
    if (!widget.enabled) return;
    if (_keyboardDraft != null) _cancelEdit();
    final next = (widget.value + direction * widget.keyboardStep).clamp(
      0.0,
      widget.max,
    );
    widget.onChanged(next);
    widget.onChangeEnd?.call(next);
  }

  void _touchSet(double dx) {
    if (!widget.enabled) return;
    if (_keyboardDraft != null) _cancelEdit();
    final value = _fraction(dx);
    _touchPreview = value;
    widget.onChanged(value);
  }

  void _touchCommit(double value) {
    if (!widget.enabled) return;
    _touchPreview = null;
    widget.onChangeEnd?.call(value);
  }

  String _semanticValue(double value) =>
      widget.semanticValueBuilder?.call(value) ?? '${(value * 100).round()}';

  @override
  void dispose() {
    _coordinator?.finish(_cancelEdit);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final width = widget.width;
    final enabled = widget.enabled;
    final clamped = (_keyboardDraft ?? _touchPreview ?? widget.value).clamp(
      0.0,
      widget.max,
    );
    return Focus(
      canRequestFocus: enabled,
      onKeyEvent: _handleKey,
      onFocusChange: (focused) {
        if (!focused && _keyboardDraft != null) _cancelEdit();
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            slider: true,
            label: widget.semanticLabel,
            value: _semanticValue(clamped),
            increasedValue: _semanticValue(
              (clamped + widget.keyboardStep).clamp(0.0, widget.max),
            ),
            decreasedValue: _semanticValue(
              (clamped - widget.keyboardStep).clamp(0.0, widget.max),
            ),
            enabled: enabled,
            onIncrease: enabled && clamped < widget.max
                ? () => _semanticStep(1)
                : null,
            onDecrease: enabled && clamped > 0 ? () => _semanticStep(-1) : null,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: enabled
                  ? (details) {
                      _touchSet(details.localPosition.dx);
                      _touchCommit(_fraction(details.localPosition.dx));
                    }
                  : null,
              // Gesture arena arbitration withholds the single-tap write
              // until a double tap is ruled out. A reset never sends an
              // intermediate tempo/decay value to the engine or store.
              onDoubleTap: enabled ? widget.onDoubleTap : null,
              onHorizontalDragStart: enabled
                  ? (details) => _touchSet(details.localPosition.dx)
                  : null,
              onHorizontalDragUpdate: enabled
                  ? (details) => _touchSet(details.localPosition.dx)
                  : null,
              onHorizontalDragEnd: enabled
                  ? (_) => _touchCommit(_touchPreview ?? widget.value)
                  : null,
              onHorizontalDragCancel: enabled
                  ? () {
                      _touchPreview = null;
                      widget.onEditCancel?.call(widget.value);
                    }
                  : null,
              child: Opacity(
                opacity: enabled ? 1 : surface.disabledOpacity,
                child: Container(
                  width: width,
                  height: 56,
                  decoration: BoxDecoration(
                    color: surface.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: focused
                          ? surface.encoderFocus
                          : surface.borderHairline,
                      width: focused ? 3 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: (width - 2) * clamped,
                        child: ColoredBox(color: surface.controlStrong),
                      ),
                      Positioned(
                        left: (width - 2) * clamped,
                        top: 0,
                        bottom: 0,
                        width: 2,
                        child: ColoredBox(color: surface.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One row of the Loop settings hub: the submenu's name, its current value
/// and a chevron. 1848 x 100.
class LoopHubRow extends StatelessWidget {
  /// Creates a [LoopHubRow].
  const LoopHubRow({
    required this.title,
    required this.summary,
    required this.onTap,
    super.key,
  });

  /// The submenu.
  final String title;

  /// Its current choice, at the right.
  final String summary;

  /// Opens the submenu.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      label: title,
      value: summary,
      child: LoopFocusable(
        onActivate: onTap,
        child: Material(
          color: surface.cardHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: surface.borderSubtle),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            canRequestFocus: false,
            onTap: onTap,
            child: SizedBox(
              width: 1848,
              height: 100,
              child: Stack(
                children: [
                  Positioned(
                    left: 33,
                    top: 32,
                    child: AppText(
                      title,
                      style: TextStyle(
                        color: surface.textPrimary,
                        fontSize: 32,
                        height: 1,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 85,
                    top: 36,
                    width: 700,
                    child: AppText(
                      summary,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: surface.textSecondary,
                        fontSize: 24,
                        height: 1,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 1787,
                    top: 36,
                    child: Icon(
                      LucideIcons.chevronRight,
                      size: 28,
                      color: surface.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
