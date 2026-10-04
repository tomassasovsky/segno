import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/app/view/control_settings_notices.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:toastification/toastification.dart';

import '../helpers/toast_test_helpers.dart';

void main() {
  late ControlSettingsNotices notices;
  setUp(() {
    resetAppToastsForTest();
    resetToastificationForTest();
    notices = ControlSettingsNotices();
  });
  tearDown(() => notices.dispose());

  const id = AppToastId.mixSettings;
  testWidgets('$id yields to shutdown and restores unresolved Retry', (
    tester,
  ) async {
    await tester.pumpWidget(_app);
    var retries = 0;
    notices.show(
      ControlSettingsNotice(
        id: id,
        title: (_) => const Text('Needs recovery'),
        retry: () async {
          retries++;
          return true;
        },
        needsRecovery: () => true,
      ),
    );
    await tester.pumpAndSettle();
    expect(debugAppToastActive(id), isTrue);
    notices.setPowerVisible(visible: true);
    await tester.pumpAndSettle();
    expect(debugAppToastActive(id), isFalse);
    notices.setPowerVisible(visible: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(debugAppToastActive(id), isFalse);
  });

  testWidgets('recovery completed by shutdown is not restored', (tester) async {
    await tester.pumpWidget(_app);
    var needsRecovery = true;
    notices
      ..setPowerVisible(visible: true)
      ..show(
        ControlSettingsNotice(
          id: AppToastId.decaySettings,
          title: (_) => const Text('Needs recovery'),
          retry: () async => true,
          needsRecovery: () => needsRecovery,
        ),
      );
    needsRecovery = false;
    notices.setPowerVisible(visible: false);
    await tester.pumpAndSettle();
    expect(debugAppToastActive(AppToastId.decaySettings), isFalse);
  });

  testWidgets('old Retry cannot dismiss a newer failure for the same control', (
    tester,
  ) async {
    await tester.pumpWidget(_app);
    final recovery = Completer<bool>();
    notices.show(
      ControlSettingsNotice(
        id: AppToastId.mixSettings,
        title: (_) => const Text('Old failure'),
        retry: () => recovery.future,
        needsRecovery: () => true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    notices.show(
      ControlSettingsNotice(
        id: AppToastId.mixSettings,
        title: (_) => const Text('New failure'),
        retry: () async => false,
        needsRecovery: () => true,
      ),
    );
    recovery.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('New failure'), findsOneWidget);
    expect(debugAppToastActive(AppToastId.mixSettings), isTrue);
    notices.dispose();
    await tester.pumpAndSettle();
  });
}

const _app = ToastificationWrapper(
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SizedBox.shrink()),
  ),
);
