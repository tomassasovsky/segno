import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';

/// The full-width editor for one plugin parameter, raised from the bottom edge
/// over a scrim when a tile is tapped (`DS / 06 FX parameter — spec`).
///
/// The tile grid is the overview; this is the same design at the other zoom
/// level. Its whole reason for existing is **travel**: a 78px tile gave a knob
/// ~36px to cover a parameter's full range, and the rejected alternatives
/// (vertical faders at 44px, mini bars at 76px) lost on that same axis. The
/// track here spans the panel, so a drag resolves the range far more finely
/// than any in-grid control could.
///
/// The extra tap is affordable *here specifically* because this is a looper
/// with a foot pedal: live mid-take control belongs to the pedal, so the
/// screen's job is setup and overview rather than performance.
class FxParamEditor extends StatefulWidget {
  /// Creates an [FxParamEditor].
  const FxParamEditor({
    required this.spec,
    required this.value,
    required this.source,
    required this.onChanged,
    required this.onClose,
    this.formatValue,
    this.isGone,
    super.key,
  });

  /// The parameter being edited.
  final PluginParamInfo spec;

  /// The plain value the sheet opens with. Cancel restores exactly this.
  final double value;

  /// Breadcrumb under the name — "Dirty rhythm · track 3 · lane A · VST3".
  final String source;

  /// Called as the value moves, and with the opening value again on cancel, so
  /// the audio follows the drag live rather than jumping on commit.
  final ValueChanged<double> onChanged;

  /// The plugin's own rendering of a plain value, or null for a numeric one.
  final String? Function(double value)? formatValue;

  /// Whether the entry this sheet edits has left the chain. Checked as the
  /// value moves: a sheet over an entry that no longer exists writes nothing
  /// and cancels to nothing, which is worse than being closed.
  final bool Function()? isGone;

  /// Closes the editor. The card owns whether it is showing, so the editor
  /// asks rather than popping — there is no route to pop.
  final VoidCallback onClose;

  /// Opens the sheet for [spec] and resolves once it closes.
  ///
  /// Returns the committed plain value, or null if the sheet closed without
  /// committing — which is NOT the same as cancelling. Only the Cancel button
  /// restores: it calls [onChanged] with the opening value on the way out.
  /// Tapping the scrim or dragging the sheet down keeps whatever the drag
  /// last wrote, because every drag has already written it. That is the
  /// behaviour a live parameter wants — the sound you are hearing when you
  /// dismiss is the sound you keep — and Cancel is the way back.
  @override
  State<FxParamEditor> createState() => _FxParamEditorState();
}

class _FxParamEditorState extends State<FxParamEditor> {
  /// The value the sheet opened with — what Cancel restores.
  late final double _opening = widget.value;
  late double _value = widget.value;

  double get _span => widget.spec.max - widget.spec.min;

  double get _fraction =>
      _span == 0 ? 0 : ((_value - widget.spec.min) / _span).clamp(0.0, 1.0);

  /// The plain value at `0..1` position [fraction], snapped to the parameter's
  /// steps when it has them — a stepped parameter must not land between its
  /// own steps just because a finger did.
  double _plainAt(double fraction) {
    final clamped = fraction.clamp(0.0, 1.0);
    if (widget.spec.stepCount > 0) {
      final step = (clamped * widget.spec.stepCount).round();
      return widget.spec.min + _span * step / widget.spec.stepCount;
    }
    return widget.spec.min + _span * clamped;
  }

  void _setFromFraction(double fraction) {
    if (widget.isGone?.call() ?? false) {
      widget.onClose();
      return;
    }
    final next = _plainAt(fraction);
    if (next == _value) return;
    setState(() => _value = next);
    widget.onChanged(next);
  }

  /// Whether the plugin names every step, few enough to list.
  bool get _named =>
      widget.spec.valueTexts.length == widget.spec.stepCount + 1 &&
      widget.spec.stepCount >= 1;

  double _plainForStep(int step) =>
      widget.spec.min + _span * step / widget.spec.stepCount;

  int get _step {
    if (_span == 0) return 0;
    final norm = ((_value - widget.spec.min) / _span).clamp(0.0, 1.0);
    return (norm * widget.spec.stepCount).round();
  }

  void _pick(int step) {
    if (widget.isGone?.call() ?? false) {
      widget.onClose();
      return;
    }
    final next = _plainForStep(step);
    if (next == _value) return;
    setState(() => _value = next);
    widget.onChanged(next);
  }

  /// The control the parameter actually wants.
  ///
  /// A bar is right for something continuous and wrong for everything else.
  /// Dragging a two-position switch along a slider, or hunting a named mode
  /// by fraction, is worse than the switch and the menu this editor replaced
  /// — moving them into the card was meant to change WHERE they live, not to
  /// flatten three kinds of control into one.
  Widget _control() {
    if (_named && widget.spec.stepCount <= 24) {
      return _StepList(
        key: const Key('fxParamEditor_steps'),
        labels: widget.spec.valueTexts,
        selected: _step,
        onPick: _pick,
      );
    }
    if (widget.spec.stepCount == 1) {
      return _StepList(
        key: const Key('fxParamEditor_steps'),
        labels: const ['Off', 'On'],
        selected: _step,
        onPick: _pick,
      );
    }
    return _FxParamTrack(
      key: const Key('fxParamEditor_track'),
      fraction: _fraction,
      onMoved: _setFromFraction,
      semanticLabel: widget.spec.name,
      step: widget.spec.stepCount > 0 ? 1 / widget.spec.stepCount : 0.05,
    );
  }

  /// Puts the value back where it was and closes. Inline there is nothing to
  /// dismiss, so Cancel means REVERT — the only thing it can usefully mean.
  void _cancel() {
    widget.onChanged(_opening);
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final fromPlugin = widget.formatValue?.call(_value);
    final hasText = fromPlugin != null && fromPlugin.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface.cardHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Builder(
        builder: (context) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.spec.name,
                key: const Key('fxParamEditor_name'),
                style: signalLabel(
                  color: surface.textPrimary,
                  size: 20,
                  weight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.source,
                style: signalLabel(color: surface.textMuted, size: 14),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    hasText
                        ? fromPlugin
                        : _value.toStringAsFixed(
                            widget.spec.stepCount > 0 ? 0 : 2,
                          ),
                    key: const Key('fxParamEditor_value'),
                    style: signalMono(color: surface.textPrimary, size: 34),
                  ),
                  if (!hasText && widget.spec.unit.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      widget.spec.unit,
                      style: signalMono(color: surface.textMuted, size: 16),
                    ),
                  ],
                  const Spacer(),
                  TextButton(
                    key: const Key('fxParamEditor_reset'),
                    onPressed: () => _setFromFraction(
                      _span == 0
                          ? 0
                          : (widget.spec.def - widget.spec.min) / _span,
                    ),
                    child: Text(l10n.fxParamResetLabel),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _control(),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('fxParamEditor_cancel'),
                    onPressed: _cancel,
                    child: Text(l10n.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('fxParamEditor_set'),
                    onPressed: widget.onClose,
                    child: Text(l10n.fxParamSetLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 64px drag track. A press anywhere on it moves the value there — the
/// whole bar is the handle, which is the point of the sheet.
class _FxParamTrack extends StatelessWidget {
  const _FxParamTrack({
    required this.fraction,
    required this.onMoved,
    required this.semanticLabel,
    required this.step,
    super.key,
  });

  final double fraction;
  final ValueChanged<double> onMoved;
  final String semanticLabel;

  /// One nudge, as a fraction of the track.
  final double step;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return LayoutBuilder(
      builder: (context, constraints) {
        String percent(double v) => '${(v.clamp(0.0, 1.0) * 100).round()}%';
        void moveTo(Offset local) => onMoved(
          local.dx / constraints.maxWidth.clamp(1.0, double.infinity),
        );

        return Semantics(
          // Its own node, so a reader lands on the bar rather than on the
          // whole sheet — without this the nearest node above it is the
          // Dialog, which is also what a test finds when it asks for it.
          key: const Key('fxParamEditor_slider'),
          container: true,
          slider: true,
          label: semanticLabel,
          value: percent(fraction),
          // Flutter asserts that a node offering increase/decrease names the
          // value on either side of the nudge.
          increasedValue:
              '${(((fraction + step).clamp(0.0, 1.0)) * 100).round()}%',
          decreasedValue:
              '${(((fraction - step).clamp(0.0, 1.0)) * 100).round()}%',
          // A node that says "adjustable" and offers no way to adjust is
          // WCAG 2.1.1. One step of a stepped parameter, or 5% of a
          // continuous one — the same grain the keyboard gets elsewhere.
          onIncrease: () => onMoved(fraction + step),
          onDecrease: () => onMoved(fraction - step),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => moveTo(d.localPosition),
            onHorizontalDragUpdate: (d) => moveTo(d.localPosition),
            child: SizedBox(
              height: 64,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: surface.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: surface.accentSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The named steps of a parameter, one row each.
///
/// A list rather than a dropdown: the dropdown was stock Material and read as
/// borrowed next to the rest of the console, and it hid the choices until you
/// opened it. There are at most 25 by the time this is used, and they are the
/// whole reason the editor is open.
class _StepList extends StatelessWidget {
  const _StepList({
    required this.labels,
    required this.selected,
    required this.onPick,
    super.key,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (step, label) in labels.indexed)
          ConsoleRow(
            key: Key('fxParamEditor_step_$step'),
            title: label,
            showDisclosure: false,
            showDivider: step != labels.length - 1,
            mark: step == selected
                ? Icon(Icons.check, size: 16, color: surface.accent)
                : null,
            onTap: () => onPick(step),
          ),
      ],
    );
  }
}
