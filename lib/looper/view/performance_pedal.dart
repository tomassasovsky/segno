import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/view/pedal_setup/pedal_hardware_face.dart';
import 'package:segno/theme/theme.dart';

/// One footswitch on a full-screen performance surface (Mixer, Fade,
/// Reverse).
///
/// Admits pointer and keyboard contacts into the shared Control ledger with
/// a fresh token per contact; only that contact may release or cancel it.
/// Semantic activation runs the role directly for assistive technology.
class PerformancePedal extends StatefulWidget {
  /// Creates one pedal; [keyPrefix] keys its contact target per surface.
  const PerformancePedal({
    required this.keyPrefix,
    required this.button,
    required this.label,
    required this.title,
    required this.detail,
    required this.hint,
    required this.enabled,
    required this.selected,
    required this.onPressed,
    required this.onReleased,
    required this.onCancelled,
    required this.onActivate,
    this.onHold,
    this.level,
    this.detailIcon,
    this.detailHighlighted = false,
    this.holdPending = false,
    this.holdThreshold = const Duration(milliseconds: 800),
    super.key,
  });

  /// Key prefix for the contact target, followed by the button name.
  final String keyPrefix;

  /// Physical role this pedal mirrors.
  final PedalButton button;

  /// Hardware face legend.
  final String label;

  /// Primary caption.
  final String title;

  /// Secondary state line; empty hides it.
  final String detail;

  /// Hold hint; empty hides it.
  final String hint;

  /// Whether contacts are admitted.
  final bool enabled;

  /// Whether the selection bar is lit.
  final bool selected;

  /// Semantic tap.
  final VoidCallback onActivate;

  /// Semantic long press, when the role has a hold.
  final VoidCallback? onHold;

  /// Optional 0–1 level bar under the title; null hides it.
  final double? level;

  /// Optional glyph leading [detail].
  final IconData? detailIcon;

  /// Whether [detail] reads in the primary text colour, for a state that
  /// departs from the default (a reversed track).
  final bool detailHighlighted;

  /// Whether this pedal's Hold is armed and still pending: draws the pen's
  /// Pending Hold cue (#1229, `PRSrG`), a bar under the face filling over
  /// [holdThreshold] from the moment this turns true, and a brightened
  /// [hint].
  final bool holdPending;

  /// How long the pending hold takes to fire.
  final Duration holdThreshold;

  /// Admits a timed contact identified by its token.
  final void Function(PedalButton button, Object contact) onPressed;

  /// Completes the admitted contact.
  final void Function(PedalButton button, Object contact) onReleased;

  /// Abandons the admitted contact without its short action.
  final void Function(PedalButton button, Object contact) onCancelled;

  @override
  State<PerformancePedal> createState() => _PerformancePedalState();
}

class _PerformancePedalState extends State<PerformancePedal>
    with SingleTickerProviderStateMixin {
  ({Object source, Object token})? _contact;

  /// Times the Pending Hold cue from this widget's own ticker, never a wall
  /// clock: the cubit publishes only that the hold is pending.
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: widget.holdThreshold,
  );

  @override
  void initState() {
    super.initState();
    if (widget.holdPending) _hold.forward();
  }

  void _press(Object source) {
    if (_contact != null || !widget.enabled) return;
    final token = Object();
    _contact = (source: source, token: token);
    widget.onPressed(widget.button, token);
  }

  void _release(Object source) {
    final contact = _contact;
    if (contact == null || contact.source != source) return;
    _contact = null;
    widget.onReleased(widget.button, contact.token);
  }

  void _cancel([Object? source]) {
    final contact = _contact;
    if (contact == null || (source != null && contact.source != source)) return;
    _contact = null;
    widget.onCancelled(widget.button, contact.token);
  }

  @override
  void didUpdateWidget(PerformancePedal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _cancel();
    _hold.duration = widget.holdThreshold;
    if (widget.holdPending && !oldWidget.holdPending) {
      _hold.forward(from: 0);
    } else if (!widget.holdPending && oldWidget.holdPending) {
      _hold
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _cancel();
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      selected: widget.selected,
      label: widget.title,
      value: widget.detail,
      hint: widget.hint,
      onTap: widget.enabled ? widget.onActivate : null,
      onLongPress: widget.enabled ? widget.onHold : null,
      child: Focus(
        canRequestFocus: widget.enabled,
        onFocusChange: (focused) {
          if (!focused) _cancel();
        },
        onKeyEvent: (_, event) {
          if (!widget.enabled ||
              (event.logicalKey != LogicalKeyboardKey.enter &&
                  event.logicalKey != LogicalKeyboardKey.space)) {
            return KeyEventResult.ignored;
          }
          if (event is KeyDownEvent) _press(event.logicalKey);
          if (event is KeyUpEvent) _release(event.logicalKey);
          return KeyEventResult.handled;
        },
        child: Builder(
          builder: (context) => Listener(
            key: Key('${widget.keyPrefix}_${widget.button.name}'),
            onPointerDown: widget.enabled
                ? (event) {
                    if (event.buttons == kPrimaryButton) {
                      _press(event.pointer);
                    }
                  }
                : null,
            onPointerUp: widget.enabled
                ? (event) => _release(event.pointer)
                : null,
            onPointerCancel: (event) => _cancel(event.pointer),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  width: 3,
                  color: Focus.of(context).hasFocus
                      ? surface.warning
                      : Colors.transparent,
                ),
              ),
              child: Opacity(
                opacity: widget.enabled ? 1 : surface.disabledOpacity,
                child: Column(
                  children: [
                    Container(
                      width: 112,
                      height: 12,
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? surface.textPrimary
                            : surface.controlStrong,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: 156,
                      child: PedalHardwareFace(
                        label: widget.label,
                        selected: false,
                      ),
                    ),
                    // The pen's 16 px between face and caption carries the
                    // 3 px Pending Hold bar 5 px under the face (`IBL3g`),
                    // laid out always so the cue never reflows the pedal.
                    const SizedBox(height: 5),
                    _HoldProgress(
                      key: Key(
                        '${widget.keyPrefix}_${widget.button.name}_hold',
                      ),
                      pending: widget.holdPending,
                      progress: _hold,
                    ),
                    const SizedBox(height: 8),
                    AppText(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 24),
                    ),
                    if (widget.level case final level?) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: 134,
                        child: LinearProgressIndicator(
                          value: level.clamp(0, 1),
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                          color: surface.textPrimary,
                          backgroundColor: surface.controlStrong,
                        ),
                      ),
                    ],
                    if (widget.detail.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 32,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _PedalDetail(
                            text: widget.detail,
                            icon: widget.detailIcon,
                            color: widget.detailHighlighted
                                ? surface.textPrimary
                                : surface.textSecondary,
                          ),
                        ),
                      ),
                    ],
                    if (widget.hint.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 56,
                        child: AppText(
                          widget.hint,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            color: widget.holdPending
                                ? surface.holdPendingText
                                : surface.textSecondary,
                          ),
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

/// The 3 px Pending Hold bar: a [SurfaceTheme.holdTrack] track and a
/// [SurfaceTheme.holdProgress] fill at [progress], invisible while no hold
/// is pending.
class _HoldProgress extends StatelessWidget {
  const _HoldProgress({
    required this.pending,
    required this.progress,
    super.key,
  });

  /// Pedal face width; the bar spans it.
  static const double width = 156;

  /// Bar height (pen `IBL3g`).
  static const double height = 3;

  final bool pending;
  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Opacity(
      opacity: pending ? 1 : 0,
      child: SizedBox(
        width: width,
        height: height,
        child: ColoredBox(
          color: surface.holdTrack,
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: AnimatedBuilder(
              animation: progress,
              builder: (context, _) => FractionallySizedBox(
                widthFactor: progress.value,
                heightFactor: 1,
                child: ColoredBox(color: surface.holdProgress),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The pedal's state line, with its optional leading glyph.
class _PedalDetail extends StatelessWidget {
  const _PedalDetail({
    required this.text,
    required this.icon,
    required this.color,
  });

  final String text;
  final IconData? icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = AppText(text, style: TextStyle(fontSize: 24, color: color));
    final icon = this.icon;
    if (icon == null) return label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 32, color: color),
        const SizedBox(width: 10),
        label,
      ],
    );
  }
}
