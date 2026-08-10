import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard.dart';
import 'package:segno/common/on_screen_keyboard/on_screen_keyboard_host.dart';

import '../helpers/helpers.dart';

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

    Future<void> pumpField(
      WidgetTester tester, {
      bool enabled = true,
      TextInputType? keyboardType,
      bool readOnly = false,
    }) => tester.pumpApp(
      OnScreenKeyboardHost(
        enabled: enabled,
        child: Scaffold(
          body: TextField(
            controller: controller,
            keyboardType: keyboardType,
            readOnly: readOnly,
          ),
        ),
      ),
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
      // taking focus. If it ever stopped working the field would lose focus on
      // the first keystroke, which is the thing dismissal now watches for.
      await pumpField(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tapKey(tester, 'h');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onScreenKeyboard')), findsOneWidget);
      expect(controller.text, 'h');
    });

    testWidgets('a field handed a different focus node is still watched', (
      tester,
    ) async {
      // The same field under a new node — a parent that swaps them, a State
      // rebuilt under a new key. A watch left on the old node is a watch on a
      // DETACHED node: it never fires again, and the keyboard could not be
      // dismissed by focus loss for the rest of the session.
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      var useFirst = true;
      late StateSetter setSwap;
      await tester.pumpApp(
        OnScreenKeyboardHost(
          enabled: true,
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setSwap = setState;
                return TextField(
                  controller: controller,
                  focusNode: useFirst ? first : second,
                );
              },
            ),
          ),
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
      await tester.pumpApp(
        OnScreenKeyboardHost(
          enabled: true,
          child: Scaffold(
            body: TextField(controller: controller, focusNode: node),
          ),
        ),
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
      // reaches the dismissal path at all — which is the point: a bounce is
      // not something the keyboard should have to survive twice. The
      // appliance's own bounce (a key press stealing focus for an instant) is
      // what the post-frame recheck in the host is for, and no test here can
      // produce one.
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpApp(
        OnScreenKeyboardHost(
          enabled: true,
          child: Scaffold(
            body: TextField(controller: controller, focusNode: node),
          ),
        ),
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
      await tester.pumpApp(
        OnScreenKeyboardHost(
          enabled: true,
          child: Scaffold(
            body: Column(
              children: [
                TextField(controller: controller, focusNode: first),
                TextField(controller: other, focusNode: second),
              ],
            ),
          ),
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
      await tester.pumpApp(
        OnScreenKeyboardHost(
          enabled: true,
          child: Scaffold(
            body: TextField(controller: controller, focusNode: node),
          ),
        ),
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
      await tester.pumpApp(
        OnScreenKeyboardHost(
          enabled: true,
          child: Builder(
            builder: (context) {
              inset = MediaQuery.of(context).viewInsets.bottom;
              return Material(child: TextField(controller: controller));
            },
          ),
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
      await tester.pumpApp(
        OnScreenKeyboardHost(
          enabled: true,
          child: Scaffold(
            body: Column(
              children: [
                const Spacer(),
                TextField(controller: controller),
              ],
            ),
          ),
        ),
      );
      final before = tester.getBottomLeft(find.byType(TextField)).dy;

      await tester.tap(find.byType(TextField));
      await tester.pump();

      expect(tester.getBottomLeft(find.byType(TextField)).dy, lessThan(before));
    });
  });
}
