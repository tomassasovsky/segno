import 'package:flutter/material.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';

/// Wraps the app and supplies an on-screen keyboard whenever a text field takes
/// focus on a build that has no physical one.
///
/// The console runs weston's `kiosk-shell`, which — unlike `desktop-shell` —
/// spawns no input panel, and the image ships no IME. So every `TextField` in
/// the app (renaming a track, naming a session, a Wi-Fi password) is dead on
/// that hardware unless the app draws its own keys.
///
/// It watches focus rather than wrapping fields, so no call site changes and
/// every future field is covered for free — and it follows the focused field's
/// own node, so the keyboard goes away when that field does. On a console
/// whose whole UI is the touch screen, one that stays up covers the thing the
/// player is reaching for.
///
/// The keyboard's height is reported back through [MediaQuery]'s
/// `viewInsets.bottom` — the same channel a real soft keyboard uses. Every
/// `Scaffold`, `AlertDialog` and scroll view already knows how to get out of
/// the way of that, so existing layouts avoid the keyboard without being
/// touched.
class OnScreenKeyboardHost extends StatefulWidget {
  /// Creates an [OnScreenKeyboardHost] around [child].
  const OnScreenKeyboardHost({
    required this.child,
    this.enabled = kConsoleMode,
    super.key,
  });

  /// The app below the keyboard.
  final Widget child;

  /// Whether to supply a keyboard at all. Defaults to [kConsoleMode]: desktop
  /// builds have a real keyboard, and drawing a second one would be noise.
  final bool enabled;

  @override
  State<OnScreenKeyboardHost> createState() => _OnScreenKeyboardHostState();
}

class _OnScreenKeyboardHostState extends State<OnScreenKeyboardHost> {
  EditableText? _field;

  /// The focus node of the field the keyboard is typing into, watched so the
  /// keyboard goes away when that field does.
  FocusNode? _watched;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    if (widget.enabled) FocusManager.instance.removeListener(_onFocusChanged);
    _watched?.removeListener(_onFieldFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    final next = _focusedEditable();
    // Focus merely LEAVING is not handled here — see [_onFieldFocusChanged].
    // A key press moves focus off the field for an instant (the keys are
    // ordinary buttons), so a keyboard that closed on every focus loss would
    // destroy its own target between the press and the callback, and every
    // keystroke would land on nothing. The field's own node is watched
    // instead, and asked again once the frame has settled.
    // A null answer is NOT a dismissal. Focus lands on a scope constantly in
    // this app — every dialog and sheet reports one, and a field that has just
    // been tapped is reported through its scope before its own node settles —
    // so "no editable focused right now" and "the player is done typing" are
    // the same event here and cannot be told apart. The field's own node can
    // tell them apart, and that is what drives dismissal.
    if (next == null) return;
    // Watched FIRST, and outside the early return below: the same field can be
    // handed a different node (a parent that swaps them, a State rebuilt under
    // a new key), and a watch left on the old one is a watch on a detached
    // node — it never fires again, and the keyboard could never be dismissed
    // by focus loss for the rest of the session.
    _watch(next);
    // Compared by CONTROLLER, not by widget instance: the EditableText widget
    // is rebuilt constantly, so comparing widgets would rebuild every frame.
    // The controller is what identifies where a keystroke lands.
    if (next.controller == _field?.controller &&
        next.readOnly == _field?.readOnly) {
      return;
    }
    setState(() => _field = next);
  }

  /// Follows [field]'s own focus node, so the keyboard can close when the
  /// field it types into stops being focused.
  void _watch(EditableText field) {
    if (identical(_watched, field.focusNode)) return;
    _watched?.removeListener(_onFieldFocusChanged);
    _watched = field.focusNode..addListener(_onFieldFocusChanged);
  }

  void _onFieldFocusChanged() {
    _dismissAfterFrame();
  }

  /// Closes the keyboard unless the field it types into still has focus once
  /// the frame has settled.
  void _dismissAfterFrame() {
    if (_watched?.hasFocus ?? false) return;
    // Asked AGAIN after the frame, deliberately, and this is the one thing
    // here no test can reach: under `flutter_test` the keys never steal focus
    // (the panel's `Focus` refuses it and the framework coalesces focus
    // changes within a frame), so a bounce produces no callback at all and an
    // immediate dismissal would pass every check in this suite.
    //
    // On the console it is the case the sticky field existed for: the report
    // this replaces says a key press can move focus off the field for an
    // instant. Closing on that first notification would take the keyboard away
    // under the player's own keystroke — a worse bug than the one being fixed,
    // and one that would only show up on the hardware. The frame boundary
    // costs nothing and settles the question.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_watched?.hasFocus ?? false) return;
      _dismiss();
    });
  }

  /// Drops the field the keyboard was typing into, closing it.
  void _dismiss() {
    _watched?.removeListener(_onFieldFocusChanged);
    _watched = null;
    if (_field != null) setState(() => _field = null);
  }

  /// The [EditableText] the primary focus sits inside, or `null` when focus is
  /// somewhere that does not take text.
  ///
  /// Walks UP. A `TextField` gives its focus node to a `Focus` widget that
  /// `EditableText` builds BELOW itself, so the focused context is a
  /// descendant of the field, never the field and never above it (verified
  /// against the framework rather than assumed).
  ///
  /// Upwards-only also keeps the answer honest: once focus returns to a scope,
  /// nothing above it is an `EditableText`, so this reports "no field" rather
  /// than latching onto some unrelated one elsewhere in the tree — and "no
  /// field" is what asks the keyboard to close.
  EditableText? _focusedEditable() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context is! Element || !context.mounted) return null;

    final self = context.widget;
    if (self is EditableText) return self;

    EditableText? found;
    context.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = element.widget as EditableText;
        return false;
      }
      return true;
    });
    return found;
  }

  bool get _readOnly => _field?.readOnly ?? false;

  TextEditingController? get _controller =>
      _readOnly ? null : _field?.controller;

  /// Replaces the current selection with [text].
  ///
  /// Goes through the controller rather than synthesising key events so the
  /// field's own `inputFormatters` and `onChanged` still run — a numeric field
  /// must reject letters the same way it would from a USB keyboard.
  void _insert(String text) {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    final selection = value.selection;
    // A field that has never been touched reports an invalid selection;
    // appending is the only sane reading of "type here" in that state.
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  void _backspace() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    final selection = value.selection;
    final end = selection.isValid ? selection.end : value.text.length;
    final start = selection.isValid && !selection.isCollapsed
        ? selection.start
        : end - 1;
    if (end <= 0 || start < 0) return;
    controller.value = value.copyWith(
      text: value.text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
      composing: TextRange.empty,
    );
  }

  void _done() {
    // Unfocus first so the field's own submit/validation paths (which hang off
    // losing focus) run, then drop the reference — rather than waiting for the
    // unfocus to come back around, which would close the keyboard a frame
    // later and for a reason the player did not give.
    FocusManager.instance.primaryFocus?.unfocus();
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final field = _field;
    final open = widget.enabled && field != null && !_readOnly;
    if (!open) return widget.child;

    final layout = layoutForInputType(field.keyboardType);
    // Five rows of 54px keys plus 3px padding either side, plus the panel's
    // own 6px inset. Sized from the keys rather than guessed, so a key-height
    // change cannot silently overflow the panel.
    final rows = layout == OnScreenKeyboardLayout.numeric ? 5 : 4;
    final height = rows * (OnScreenKeyboard.keyHeight + 6) + 12;
    final media = MediaQuery.of(context);

    return Column(
      children: [
        Expanded(
          child: MediaQuery(
            // Report the keyboard the way the platform would, so every
            // Scaffold/dialog/scroll view already in the app moves out of its
            // way with no change at the call site.
            data: media.copyWith(
              viewInsets: media.viewInsets.copyWith(bottom: height),
            ),
            child: widget.child,
          ),
        ),
        // The keyboard must never take focus. A real soft keyboard is an OS
        // panel and cannot; these are ordinary buttons and will, which pulls
        // focus off the field between the press and the callback — so the
        // keystroke arrives with nothing to type into.
        //
        // TextFieldTapRegion additionally stops the tap reading as "outside
        // the field", which is what would otherwise dismiss the editing
        // session on the first key.
        TextFieldTapRegion(
          child: Focus(
            canRequestFocus: false,
            descendantsAreFocusable: false,
            skipTraversal: true,
            child: Material(
              key: const Key('onScreenKeyboard'),
              elevation: 8,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: height,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: OnScreenKeyboard(
                      layout: layout,
                      onKey: _insert,
                      onBackspace: _backspace,
                      onDone: _done,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
