import 'package:material_ui/material_ui.dart';
import 'package:segno/common/console_rename_sheet.dart' show ConsoleEntryField;
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/tempo_entry.dart';
import 'package:segno/looper/model/tempo_state.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/readout_panel/readout_button.dart';

/// The readout's exact-tempo keypad (#1654): the Tempo page's keypad
/// (#1653), its rules, field and numeric pad, laid out for the 7" with the
/// field and Cancel beside the keys rather than above them. 30.00 to 300.00
/// BPM with up to two decimals.
class ReadoutTempoKeypad extends StatefulWidget {
  /// Creates a [ReadoutTempoKeypad].
  const new({
    required this.onSet,
    required this.onCancel,
    super.key,
  });

  /// Called with the typed tempo when Set takes it.
  final ValueChanged<double> onSet;

  /// Called on Cancel, and on Set with nothing typed.
  final VoidCallback onCancel;

  @override
  State<ReadoutTempoKeypad> createState() => _ReadoutTempoKeypadState();
}

class _ReadoutTempoKeypadState extends State<ReadoutTempoKeypad> {
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

  /// Takes the typed tempo, or says why not and stays up. Set with nothing
  /// typed leaves the tempo as it is.
  void _submit() {
    if (_text.isEmpty) {
      widget.onCancel();
      return;
    }
    final bpm = parseTempoEntry(_text);
    if (bpm == null) {
      setState(() => _rejected = true);
      return;
    }
    widget.onSet(bpm);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final (min, max) = kTempoRange;
    final low = min.toStringAsFixed(2);
    final high = max.toStringAsFixed(2);
    final typed = parseTempoEntry(_text);
    final note = TextStyle(
      color: _rejected ? surface.warning : surface.textSecondary,
      fontSize: 13,
      height: 1.25,
    );
    return Container(
      key: const Key('readout_keypad'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surface.card,
        border: Border.all(color: surface.accent),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppText(
                  l10n.loopTempoEntryTitle.toUpperCase(),
                  style: TextStyle(
                    color: surface.textMuted,
                    fontSize: 11,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 8),
                ConsoleEntryField(
                  text: _text,
                  label: l10n.loopTempoEntryField,
                  textKey: const Key('readout_keypad_field'),
                ),
                const SizedBox(height: 8),
                AppText(
                  _rejected
                      ? l10n.loopTempoEntryOutOfRange(low, high)
                      : l10n.loopTempoEntryRange(low, high),
                  key: Key(
                    _rejected ? 'readout_keypad_error' : 'readout_keypad_range',
                  ),
                  style: note,
                ),
                const Spacer(),
                SizedBox(
                  height: OnScreenKeyboard.standardKeyHeight,
                  child: ReadoutButton(
                    key: const Key('readout_keypad_cancel'),
                    label: l10n.cancel,
                    onPressed: widget.onCancel,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: OnScreenKeyboard(
                layout: OnScreenKeyboardLayout.numeric,
                // The Set key names what it will set, as the mockup draws it.
                doneLabel: typed == null
                    ? l10n.loopTempoEntrySet
                    : l10n.readoutKeypadSet(typed.toStringAsFixed(2)),
                onKey: _type,
                onBackspace: _backspace,
                onDone: _submit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
