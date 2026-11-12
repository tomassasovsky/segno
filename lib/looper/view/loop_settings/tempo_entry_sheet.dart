import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/tempo_entry.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Asks for an exact tempo on the console's numeric keypad (#1653): BPM in
/// [kTempoRange] with up to two decimals. Resolves to the tempo, or null when
/// it was cancelled or nothing was typed.
///
/// The same sheet as `showConsoleRenameSheet`, with the keypad layout of
/// the console's one keyboard built in: the app-wide keyboard host is driven
/// by field focus, and this sheet holds no field.
Future<double?> showTempoEntrySheet(
  BuildContext context, {
  required double current,
}) {
  final surface = context.surface;
  return showModalBottomSheet<double>(
    context: context,
    barrierColor: surface.scrim.withValues(alpha: 0.62),
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    // Material caps a bottom sheet at 640px wide; the rename sheet's
    // override, so the keypad spans the console like every other keyboard.
    constraints: const BoxConstraints(),
    isScrollControlled: true,
    // Full size it is about 690 high: on a window shorter than that (a
    // desktop build) it scrolls rather than overflowing.
    builder: (_) =>
        SingleChildScrollView(child: _TempoEntrySheet(current: current)),
  );
}

class _TempoEntrySheet extends StatefulWidget {
  const new({required this.current});

  final double current;

  @override
  State<_TempoEntrySheet> createState() => _TempoEntrySheetState();
}

class _TempoEntrySheetState extends State<_TempoEntrySheet> {
  /// The typed tempo's size, above the sheet's 24 px notes.
  static const double _fieldSize = 32;

  /// The keys: 80 high with 28 px labels, the page's choice text.
  static const double _keyHeight = 80;
  static const double _keyLabelSize = 28;

  String _text = '';

  /// Whether the last Set was outside the range; typing clears it.
  bool _rejected = false;

  void _type(String key) {
    final next = typeTempoKey(_text, key);
    if (next == null) return;
    setState(() {
      _text = next;
      _rejected = false;
    });
  }

  void _backspace() {
    if (_text.isEmpty) return;
    setState(() {
      _text = _text.substring(0, _text.length - 1);
      _rejected = false;
    });
  }

  /// Takes the typed tempo, or says why not and keeps the sheet up. Set on
  /// an empty field leaves the tempo as it is.
  void _submit() {
    if (_text.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final bpm = parseTempoEntry(_text);
    if (bpm == null) {
      setState(() => _rejected = true);
      return;
    }
    Navigator.of(context).pop(bpm);
  }

  /// Physical keys too: a desktop build, or a console with a USB keyboard.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null || !isTempoKey(character)) {
      return KeyEventResult.ignored;
    }
    _type(character);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final spacing = context.spacing;
    final (min, max) = kTempoRange;
    final range = l10n.loopTempoEntryRange(
      min.toStringAsFixed(2),
      max.toStringAsFixed(2),
    );
    final now = widget.current > 0
        ? l10n.loopTempoEntryNow(widget.current.toStringAsFixed(2))
        : l10n.loopTempoUnset;
    // Full size, as the page under it (#1672): the page's 32 inset, its
    // 28 px heading and 24 px notes, a 64 high Cancel, and 80 high keys.
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        key: const Key('tempo_entry_sheet'),
        decoration: BoxDecoration(
          color: surface.card,
          border: Border.all(color: surface.borderStrong),
        ),
        padding: EdgeInsets.all(spacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                LoopSectionLabel(l10n.loopTempoEntryTitle),
                SizedBox(width: spacing.xl),
                Expanded(child: LoopNote('$now · $range')),
                SizedBox(width: spacing.xl),
                LoopOutlinedButton(
                  key: const Key('tempo_entry_cancel'),
                  width: 172,
                  fitLabel: true,
                  label: l10n.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            SizedBox(height: spacing.lg),
            ConsoleEntryField(
              text: _text,
              label: l10n.loopTempoEntryField,
              textKey: const Key('tempo_entry_field'),
              fontSize: _fieldSize,
            ),
            if (_rejected) ...[
              SizedBox(height: spacing.sm),
              AppText(
                l10n.loopTempoEntryOutOfRange(
                  min.toStringAsFixed(2),
                  max.toStringAsFixed(2),
                ),
                key: const Key('tempo_entry_error'),
                style: TextStyle(
                  color: surface.warning,
                  fontSize: 24,
                  height: 1.2,
                ),
              ),
            ],
            SizedBox(height: spacing.lg),
            OnScreenKeyboard(
              layout: OnScreenKeyboardLayout.numeric,
              doneLabel: l10n.loopTempoEntrySet,
              keyHeight: _keyHeight,
              labelSize: _keyLabelSize,
              onKey: _type,
              onBackspace: _backspace,
              onDone: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
