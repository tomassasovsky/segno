import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// A mapping endpoint's Loop/Once value, separate from its source behavior.
///
/// Choices change only the editor draft. Escape restores the value held when
/// editing this endpoint began, just as the numeric endpoint slider does.
class PlaybackEndpointChoice extends StatefulWidget {
  /// Creates a compact Loop/Once endpoint choice.
  const PlaybackEndpointChoice({
    required this.value,
    required this.width,
    required this.enabled,
    required this.keyPrefix,
    required this.onChanged,
    this.caption,
    super.key,
  });

  /// The current normalized draft endpoint.
  final double value;

  /// Width of the editor slot.
  final double width;

  /// Whether the target currently resolves.
  final bool enabled;

  /// Stable test and focus identity for this endpoint.
  final String keyPrefix;

  /// Writes a normalized Loop (0) or Once (1) draft endpoint.
  final ValueChanged<double> onChanged;

  /// Optional MIDI range caption; other editors already draw a caption.
  final String? caption;

  @override
  State<PlaybackEndpointChoice> createState() => _PlaybackEndpointChoiceState();
}

class _PlaybackEndpointChoiceState extends State<PlaybackEndpointChoice> {
  final _focusNode = FocusNode();
  double? _opening;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _choose(bool once) {
    if (!widget.enabled) return;
    _opening ??= widget.value;
    _focusNode.requestFocus();
    widget.onChanged(once ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused) {
        _opening ??= widget.value;
      } else {
        _opening = null;
      }
    },
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.escape ||
          _opening == null) {
        return KeyEventResult.ignored;
      }
      widget.onChanged(_opening!);
      _opening = null;
      node.unfocus();
      return KeyEventResult.handled;
    },
    child: SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.caption case final caption?) ...[
            AppText(
              caption,
              style: TextStyle(
                color: context.surface.textSecondary,
                fontSize: 21,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              LoopChoiceButton(
                key: Key('${widget.keyPrefix}_loop'),
                width: (widget.width - 8) / 2,
                height: 54,
                label: context.l10n.loopPlaybackLoop,
                selected: widget.value < 0.5,
                enabled: widget.enabled,
                onTap: () => _choose(false),
              ),
              const SizedBox(width: 8),
              LoopChoiceButton(
                key: Key('${widget.keyPrefix}_once'),
                width: (widget.width - 8) / 2,
                height: 54,
                label: context.l10n.loopPlaybackOnce,
                selected: widget.value >= 0.5,
                enabled: widget.enabled,
                onTap: () => _choose(true),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
