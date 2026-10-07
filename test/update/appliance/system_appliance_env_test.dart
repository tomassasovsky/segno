import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/update/appliance/system_appliance_env.dart';

/// Tests for [SystemApplianceEnv]'s helper plumbing. The class is excluded
/// from coverage as an I/O boundary, so these drive a REAL `Process.start` of
/// a shell stub standing in for `segno-update-ctl`.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('segno-env-test'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Writes an executable stub helper and returns its path.
  String stub(String body) {
    final file = File('${dir.path}/helper.sh')..writeAsStringSync(body);
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  group('powerOff', () {
    test('runs the helper poweroff verb', () async {
      final argsFile = '${dir.path}/args.txt';
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "\$1" > "$argsFile"\n'),
      );
      await env.powerOff();
      expect(File(argsFile).readAsStringSync().trim(), 'poweroff');
    });
  });

  group('stage', () {
    test('runs the helper install verb with the version', () async {
      final argsFile = '${dir.path}/args.txt';
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "\$@" > "$argsFile"\n'),
      );
      await env.stage('0.7.0').drain<void>();
      expect(File(argsFile).readAsStringSync().trim(), 'install 0.7.0');
    });

    test('republishes PROGRESS lines as [0, 1]', () async {
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "PROGRESS 0"\necho "PROGRESS 50"\n'),
      );
      expect(await env.stage('0.7.0').toList(), [0.0, 0.5, 1.0]);
    });

    test(
      'cancelling sends the helper SIGTERM and waits for it to exit',
      () async {
        final started = '${dir.path}/started';
        final terminated = '${dir.path}/terminated';
        // Traps TERM like the real helper, and takes a moment over its exit so
        // the test can tell a cancel that waited from one that did not.
        final env = SystemApplianceEnv(
          helperPath: stub(
            '#!/bin/sh\n'
            'trap \'sleep 0.2; echo yes > "$terminated"; exit 143\' TERM\n'
            'echo "PROGRESS 5"\n'
            ': > "$started"\n'
            'while :; do sleep 0.05; done\n',
          ),
        );

        final progress = <double>[];
        final sub = env.stage('0.7.0').listen(progress.add);
        while (!File(started).existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await sub.cancel();

        expect(File(terminated).readAsStringSync().trim(), 'yes');
        // Nothing after the cancel, and never the closing 1.0 of a success.
        expect(progress, isNot(contains(1.0)));
      },
    );

    test('throws with the helper stderr on a non-zero exit', () async {
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "boom" >&2\nexit 1\n'),
      );
      await expectLater(
        env.stage('0.7.0').toList(),
        throwsA(
          isA<ProcessException>().having((e) => e.message, 'message', 'boom'),
        ),
      );
    });
  });

  group('updateAttempt', () {
    test('reads the version the helper prints', () async {
      final env = SystemApplianceEnv(
        helperPath: stub(
          '#!/bin/sh\n[ "\$1" = attempt ] && echo \'{"version":"1.1.0"}\'\n',
        ),
      );
      expect(await env.updateAttempt(), '1.1.0');
    });

    test('is null for {}, a failure or an old helper', () async {
      expect(
        await SystemApplianceEnv(
          helperPath: stub("#!/bin/sh\necho '{}'\n"),
        ).updateAttempt(),
        isNull,
      );
      expect(
        await SystemApplianceEnv(
          helperPath: stub('#!/bin/sh\necho "usage" >&2\nexit 2\n'),
        ).updateAttempt(),
        isNull,
      );
      expect(
        await SystemApplianceEnv(
          helperPath: '${dir.path}/missing',
        ).updateAttempt(),
        isNull,
      );
    });

    test('clearUpdateAttempt runs the clear-attempt verb', () async {
      final argsFile = '${dir.path}/args.txt';
      final env = SystemApplianceEnv(
        helperPath: stub('#!/bin/sh\necho "\$1" > "$argsFile"\n'),
      );
      await env.clearUpdateAttempt();
      expect(File(argsFile).readAsStringSync().trim(), 'clear-attempt');
    });
  });

  group('reconcileStaged', () {
    test('returns the reason the helper cleared the marker for', () async {
      final env = SystemApplianceEnv(
        helperPath: stub(
          '#!/bin/sh\n'
          'echo \'{"cleared":true,"reason":"tryboot-not-taken"}\'\n',
        ),
      );
      expect(await env.reconcileStaged(), 'tryboot-not-taken');
    });

    test('is null when the marker was kept or the helper is missing', () async {
      expect(
        await SystemApplianceEnv(
          helperPath: stub('#!/bin/sh\necho \'{"cleared":false}\'\n'),
        ).reconcileStaged(),
        isNull,
      );
      expect(
        await SystemApplianceEnv(
          helperPath: '${dir.path}/missing',
        ).reconcileStaged(),
        isNull,
      );
    });
  });
}
