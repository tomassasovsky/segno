import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/tempo_state.dart';
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
    builder: (_) => _TempoEntrySheet(current: current),
  );
}

/// [text] with [key] typed after it, or null when the key would make it no
/// tempo: a second point, a third decimal, or a fourth whole digit.
@visibleForTesting
String? typeTempoKey(String text, String key) {
  final next = text + key;
  return _tempoText.hasMatch(next) ? next : null;
}

/// Up to three whole digits and two decimals.
final _tempoText = RegExp(r'^\d{0,3}(\.\d{0,2})?$');

/// A key that types into the tempo: a digit or the point.
final _tempoKey = RegExp(r'^[\d.]$');

/// The tempo [text] names, or null when it is outside [kTempoRange].
@visibleForTesting
double? parseTempoEntry(String text) {
  final bpm = double.tryParse(text);
  if (bpm == null) return null;
  final (min, max) = kTempoRange;
  return bpm >= min && bpm <= max ? bpm : null;
}

class _TempoEntrySheet extends StatefulWidget {
  const _TempoEntrySheet({required this.current});

  final double current;

  @override
  State<_TempoEntrySheet> createState() => _TempoEntrySheetState();
}

class _TempoEntrySheetState extends State<_TempoEntrySheet> {
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
    if (character == null || !_tempoKey.hasMatch(character)) {
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
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        key: const Key('tempo_entry_sheet'),
        decoration: BoxDecoration(
          color: surface.card,
          border: Border.all(color: surface.borderStrong),
        ),
        padding: EdgeInsets.all(spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppText(
                  l10n.loopTempoEntryTitle,
                  style: TextStyle(
                    color: surface.textPrimary,
                    fontSize: 18,
                    height: 1.17,
                    leadingDistribution: TextLeadingDistribution.even,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(width: spacing.md),
                Expanded(
                  child: AppText(
                    '$now · $range',
                    style: TextStyle(
                      color: surface.textMuted,
                      fontSize: 14,
                      height: 1.21,
                      leadingDistribution: TextLeadingDistribution.even,
                    ),
                  ),
                ),
                ConsoleDialogButton(
                  key: const Key('tempo_entry_cancel'),
                  label: l10n.cancel,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            SizedBox(height: spacing.md),
            ConsoleEntryField(
              text: _text,
              label: l10n.loopTempoEntryField,
              textKey: const Key('tempo_entry_field'),
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
                  fontSize: 14,
                  height: 1.21,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ],
            SizedBox(height: spacing.md),
            OnScreenKeyboard(
              layout: OnScreenKeyboardLayout.numeric,
              doneLabel: l10n.loopTempoEntrySet,
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
