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
}
