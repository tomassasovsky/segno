import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard_host.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

void main() {
  group('layoutForInputType', () {
    test('numeric fields get the pad', () {
      expect(
        layoutForInputType(TextInputType.number),
        OnScreenKeyboardLayout.numeric,
      );
      expect(
        layoutForInputType(TextInputType.phone),
        OnScreenKeyboardLayout.numeric,
      );
    });

    test('text, email and null get qwerty', () {
      expect(
        layoutForInputType(TextInputType.text),
        OnScreenKeyboardLayout.text,
      );
      expect(
        layoutForInputType(TextInputType.emailAddress),
        OnScreenKeyboardLayout.text,
      );
      expect(layoutForInputType(null), OnScreenKeyboardLayout.text);
    });

    test('a password field gets qwerty, not the pad', () {
      // Passwords are ordinary text behind the masking; a numeric pad would
      // make most Wi-Fi keys untypable.
      expect(
        layoutForInputType(TextInputType.visiblePassword),
        OnScreenKeyboardLayout.text,
      );
    });
  });

  group('OnScreenKeyboardHost', () {
    late TextEditingController controller;

    setUp(() => controller = TextEditingController());
    tearDown(() => controller.dispose());

    /// Mounts [body] under a host wired the way the app wires it: in
    /// `MaterialApp.builder`, ABOVE the `Navigator`.
    ///
    /// It matters. Below the Navigator (which is what `pumpApp` does with a
    /// plain `home:`) the host's open/close swaps the widget at that slot, and
    /// with no `GlobalKey` beneath it the whole subtree is re-inflated — which
    /// disposes the field's own `FocusNode` and detaches it. The app never
    /// sees that because the Navigator's key reparents instead. Any test about
    /// FOCUS has to use this shape or it is measuring the harness.
    Future<void> pumpAsApp(
      WidgetTester tester,
      Widget body, {
      bool enabled = true,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.neon,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => OnScreenKeyboardHost(
          enabled: enabled,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: body),
      ),
    );

    Future<void> pumpField(
      WidgetTester tester, {
      bool enabled = true,
      TextInputType? keyboardType,
      bool readOnly = false,
    }) => pumpAsApp(
      tester,
      TextField(
        controller: controller,
        keyboardType: keyboardType,
        readOnly: readOnly,
      ),
      enabled: enabled,
    );

    Future<void> tapKey(WidgetTester tester, String label) async {
      await tester.tap(find.text(label).first);
      await tester.pump();
    }

    testWidgets('stays hidden until a field takes focus', (tester) async {
      await pumpField(tester);

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);
    });

    testWidgets('never appears on desktop', (tester) async {
      // Desktop has a real keyboard; a second one is noise.
      await pumpField(tester, enabled: false);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('typing reaches the focused controller', (tester) async {
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tapKey(tester, 'h');
      await tapKey(tester, 'i');

      expect(controller.text, 'hi');
    });

    testWidgets('shift is one-shot', (tester) async {
      // Holding a modifier is not an option with a guitar in your hands.
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Shift'));
      await tester.pump();
      await tapKey(tester, 'A');
      await tapKey(tester, 'b');

      expect(controller.text, 'Ab');
    });

    testWidgets('backspace deletes the character before the caret', (
      tester,
    ) async {
      controller.text = 'abc';
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 3);

      await tester.tap(find.bySemanticsLabel('Delete'));
      await tester.pump();

      expect(controller.text, 'ab');
    });

    testWidgets('backspace on an empty field does not throw', (tester) async {
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Delete'));
      await tester.pump();

      expect(controller.text, isEmpty);
    });

    testWidgets('typing replaces a selection rather than appending', (
      tester,
    ) async {
      controller.text = 'abc';
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      // Set AFTER focusing: tapping the field places the caret and would
      // discard a selection established beforehand.
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 3,
      );

      await tapKey(tester, 'z');

      expect(controller.text, 'z');
    });

    testWidgets('the keys do not take focus away from the field', (
      tester,
    ) async {
      // The keys are ordinary buttons; the panel's `Focus` is what stops them
      // taking focus. If that ever stopped working the field would lose focus
      // on the first keystroke — which is now the thing that closes the
      // keyboard, so this is load-bearing rather than incidental.
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpAsApp(
        tester,
        TextField(controller: controller, focusNode: node),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(node.hasFocus, isTrue);

      await tapKey(tester, 'h');
      await tester.pumpAndSettle();

      expect(node.hasFocus, isTrue);
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);
      expect(controller.text, 'h');
    });

    testWidgets('a field with no focus node of its own dismisses too', (
      tester,
    ) async {
      // Five of the seven fields in the app pass no `focusNode` — the Wi-Fi
      // password among them. They are the ones this exists for, and every
      // other dismissal test here hands one in.
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('a field destroyed while focused takes the keyboard with it', (
      tester,
    ) async {
      // Nothing notifies here: a disposed node is detached before it can. The
      // only signal is the focus manager reporting that nothing takes text.
      var showField = true;
      late StateSetter setShown;
      await pumpAsApp(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            setShown = setState;
            return showField
                ? TextField(controller: controller)
                : const SizedBox.shrink();
          },
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      setShown(() => showField = false);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('a field handed a different focus node still dismisses', (
      tester,
    ) async {
      // The same field under a new node — a parent that swaps them, a State
      // rebuilt under a new key. Anything that tracked the FIRST node would
      // be tracking a detached one after the swap, and a detached node never
      // notifies again.
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      var useFirst = true;
      late StateSetter setSwap;
      await pumpAsApp(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            setSwap = setState;
            return TextField(
              controller: controller,
              focusNode: useFirst ? first : second,
            );
          },
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      setSwap(() => useFirst = false);
      await tester.pump();
      second.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      second.unfocus();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('the field losing focus dismisses it', (tester) async {
      // The console is all touch screen: a keyboard that will not go away
      // covers the thing the player is reaching for.
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpAsApp(
        tester,
        TextField(controller: controller, focusNode: node),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      node.unfocus();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('focus that leaves and returns within a frame is not a '
        'departure', (tester) async {
      // The framework coalesces focus changes inside a frame, so this never
      // reaches the dismissal path at all — which is worth pinning: it is why
      // the appliance's own bounce (a key press stealing focus for an
      // instant) cannot be reproduced here, and why the post-frame recheck in
      // the host is argued rather than tested.
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpAsApp(
        tester,
        TextField(controller: controller, focusNode: node),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();

      node
        ..unfocus()
        ..requestFocus();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);
    });

    testWidgets('focus moving to another field keeps a keyboard up', (
      tester,
    ) async {
      final other = TextEditingController();
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(other.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await pumpAsApp(
        tester,
        Column(
          children: [
            TextField(controller: controller, focusNode: first),
            TextField(controller: other, focusNode: second),
          ],
        ),
      );
      await tester.tap(find.byType(TextField).first);
      await tester.pump();

      // Moving between two fields is one editing session as far as the player
      // is concerned; the keyboard must not blink out and back.
      second.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      await tapKey(tester, 'h');
      expect(other.text, 'h');
      expect(controller.text, isEmpty);
    });

    testWidgets('a dismissed keyboard comes back for the next field', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await pumpAsApp(
        tester,
        TextField(controller: controller, focusNode: node),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      node.unfocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);

      // The dismissal drops the watched node; re-focusing has to re-arm it, or
      // the keyboard comes back once and never closes again.
      node.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      node.unfocus();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('done dismisses the keyboard', (tester) async {
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);

      await tapKey(tester, 'done');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('a numeric field gets the pad, with no letters', (
      tester,
    ) async {
      await pumpField(tester, keyboardType: TextInputType.number);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(find.text('7'), findsOneWidget);
      expect(find.text('q'), findsNothing);
    });

    testWidgets('a read-only field gets no keyboard', (tester) async {
      // It can hold focus for selection, but typing into it is not a thing.
      await pumpField(tester, readOnly: true);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(find.byKey(const Key('onScreenKeyboard')), findsNothing);
    });

    testWidgets('reports its height as a view inset', (tester) async {
      // Read ABOVE any Scaffold: a Scaffold consumes the bottom inset — that
      // is precisely how it avoids the keyboard — so measuring inside its body
      // would read zero even when everything is working.
      late double inset;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => OnScreenKeyboardHost(
            enabled: true,
            child: Builder(
              builder: (context) {
                inset = MediaQuery.of(context).viewInsets.bottom;
                return child ?? const SizedBox.shrink();
              },
            ),
          ),
          home: Material(child: TextField(controller: controller)),
        ),
      );
      expect(inset, 0);

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(inset, greaterThan(0));
    });

    testWidgets('an existing Scaffold layout moves out of the way', (
      tester,
    ) async {
      // The point of reporting through viewInsets: every layout already in the
      // app avoids the keyboard with no change at its call site.
      await pumpAsApp(
        tester,
        Column(
          children: [
            const Spacer(),
            TextField(controller: controller),
          ],
        ),
      );
      final before = tester.getBottomLeft(find.byType(TextField)).dy;

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(tester.getBottomLeft(find.byType(TextField)).dy, lessThan(before));
    });
  });
}
