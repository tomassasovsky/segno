import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/wifi/view/network_dialogs.dart';

/// WPA2's own floor. Checked here, where it can be corrected, rather than
/// handed to the supplicant and returned seconds later as a generic
/// association failure that names nothing.
const int kWpa2PassphraseMinLength = 8;

/// WPA2's ceiling for a passphrase.
const int kWpa2PassphraseMaxLength = 63;

/// Asks for [ssid]'s password (pen 29/02); resolves to it, or null if
/// cancelled. [error] is the line under the field when the sheet reopens
/// after a refusal (pen 29/04, "Incorrect password. Try again.").
///
/// The console has **one keyboard**, and it is built into this sheet. The
/// app-wide on-screen keyboard host is driven by *field focus*, so a sheet
/// holding a real [TextField] would summon a second keyboard panel under it.
/// The password lives only in this sheet's state: Cancel, Connect and leaving
/// all drop it.
Future<String?> showNetworkPasswordSheet(
  BuildContext context, {
  required String ssid,
  String? error,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  barrierColor: context.surface.scrim,
  builder: (_) => _PasswordSheet(ssid: ssid, error: error),
);

class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet({required this.ssid, this.error});

  final String ssid;
  final String? error;

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  String _password = '';
  bool _visible = false;
  bool _tooShort = false;
  late String? _error = widget.error;

  void _type(String key) {
    if (_password.length + key.length > kWpa2PassphraseMaxLength) return;
    setState(() {
      _password += key;
      _tooShort = false;
      _error = null;
    });
  }

  void _backspace() {
    if (_password.isEmpty) return;
    setState(() {
      _password = _password.substring(0, _password.length - 1);
      _tooShort = false;
    });
  }

  void _submit() {
    if (_password.length < kWpa2PassphraseMinLength) {
      setState(() => _tooShort = true);
      return;
    }
    Navigator.of(context).pop(_password);
  }

  /// Physical keys too — for desktop builds, and for a console with a USB
  /// keyboard attached. The on-screen keys are the console's only guaranteed
  /// input, not its only possible one.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null || character.isEmpty) return KeyEventResult.ignored;
    if (character.codeUnitAt(0) < 0x20) return KeyEventResult.ignored;
    _type(character);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final message = _tooShort
        ? l10n.wifiPassphraseTooShort(kWpa2PassphraseMinLength)
        : _error;
    final shown = _visible ? _password : '•' * _password.length;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: NetworkDialogFrame(
        key: const Key('network_password_sheet'),
        width: 1120,
        padding: const EdgeInsets.fromLTRB(44, 36, 44, 36),
        label: widget.ssid,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: NetworkDialogTitle(widget.ssid)),
                const SizedBox(width: 24),
                LoopOutlinedButton(
                  key: const Key('network_password_cancel'),
                  width: 160,
                  label: l10n.cancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 24),
            AppText(
              l10n.networkPasswordLabel,
              style: TextStyle(
                color: surface.textSecondary,
                fontSize: 22,
                height: 1,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    label: l10n.networkPasswordLabel,
                    value: l10n.networkPasswordLength(_password.length),
                    excludeSemantics: true,
                    child: Container(
                      key: const Key('network_password_field'),
                      height: 72,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: surface.background,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: message != null
                              ? surface.warning
                              : surface.accent,
                        ),
                      ),
                      child: Row(
                        children: [
                          Flexible(
                            child: AppText(
                              _password.isEmpty
                                  ? l10n.networkPasswordPlaceholder
                                  : shown,
                              key: const Key('network_password_value'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _password.isEmpty
                                    ? surface.textTertiary
                                    : surface.textPrimary,
                                fontFamily: _password.isEmpty
                                    ? null
                                    : SurfaceTheme.monoFont,
                                fontSize: 26,
                                height: 1,
                              ),
                            ),
                          ),
                          if (_password.isNotEmpty) ...[
                            const SizedBox(width: 2),
                            Container(
                              width: 2,
                              height: 30,
                              color: surface.accent,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                LoopOutlinedButton(
                  key: const Key('network_password_visibility'),
                  width: 112,
                  height: 72,
                  label: _visible
                      ? l10n.networkPasswordHide
                      : l10n.networkPasswordShow,
                  onTap: () => setState(() => _visible = !_visible),
                ),
              ],
            ),
            SizedBox(
              height: 52,
              child: Align(
                alignment: Alignment.centerLeft,
                child: message == null
                    ? null
                    : Semantics(
                        liveRegion: true,
                        child: AppText(
                          message,
                          key: const Key('network_password_message'),
                          style: TextStyle(
                            color: surface.warning,
                            fontSize: 22,
                            height: 1,
                          ),
                        ),
                      ),
              ),
            ),
            OnScreenKeyboard(
              layout: OnScreenKeyboardLayout.text,
              showNumberRow: true,
              doneLabel: l10n.networkConnect,
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
