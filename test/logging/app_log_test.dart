import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segno/logging/app_log.dart';

void main() {
  late Directory dir;

  setUp(() async {
    AppLog.close();
    dir = await Directory.systemTemp.createTemp('segno-app-log-');
    await AppLog.init(directory: dir);
  });

  tearDown(() async {
    AppLog.close();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('info writes a line to segno.log', () {
    AppLog.info('hello breadcrumb');
    final text = File('${dir.path}/segno.log').readAsStringSync();
    expect(text, contains(' I hello breadcrumb'));
  });

  test('error appends error and stack', () {
    AppLog.error(
      'boom',
      error: StateError('nope'),
      stack: StackTrace.fromString('stack-here'),
    );
    final text = File('${dir.path}/segno.log').readAsStringSync();
    expect(text, contains(' E boom'));
    expect(text, contains('Bad state: nope'));
    expect(text, contains('stack-here'));
  });

  test('rotates when the counted size reaches maxBytes', () async {
    final path = '${dir.path}/segno.log';
    // Seed past the threshold BEFORE the handle opens, so the byte counter is
    // seeded from it (the size is counted from the open, never re-stat-ed).
    AppLog.close();
    File(path).writeAsStringSync('x' * AppLog.maxBytes);
    await AppLog.init(directory: dir);

    AppLog.info('trigger-rotate');

    expect(File('${dir.path}/segno.log.1').existsSync(), isTrue);
    final active = File(path).readAsStringSync();
    expect(active, allOf(contains('trigger-rotate'), isNot(contains('xxx'))));
  });

  test('drops the oldest rotated sibling', () async {
    final active = File('${dir.path}/segno.log');
    final one = File('${dir.path}/segno.log.1');
    final two = File('${dir.path}/segno.log.2');
    one.writeAsStringSync('one');
    two.writeAsStringSync('two');
    // Force a rotate on the first write after the handle reopens.
    AppLog.close();
    active.writeAsStringSync('x' * AppLog.maxBytes);
    await AppLog.init(directory: dir);

    AppLog.info('newest');

    expect(two.readAsStringSync(), 'one');
    expect(active.readAsStringSync(), contains('newest'));
  });

  test('init is idempotent', () async {
    AppLog.info('first');
    await AppLog.init(directory: dir);
    AppLog.info('second');
    final text = File('${dir.path}/segno.log').readAsStringSync();
    expect(text, contains('first'));
    expect(text, contains('second'));
  });

  group('the footswitch-press write path', () {
    test('does not fsync for info/warn lines', () {
      for (var i = 0; i < 20; i++) {
        AppLog.info('control: footswitch $i pressed');
        AppLog.warn('control: momentary $i');
      }
      expect(AppLog.debugFlushCount, 0);
      // And the lines are on disk all the same — a plain write already
      // survives a process crash, which is what a breadcrumb needs.
      expect(
        File('${dir.path}/segno.log').readAsStringSync(),
        contains('footswitch 19 pressed'),
      );
    });

    test('fsyncs exactly the error lines', () {
      AppLog.info('before');
      AppLog.error('boom');
      AppLog.info('after');
      AppLog.error('boom again');
      expect(AppLog.debugFlushCount, 2);
    });

    test('does not stat the file per line: the size is counted', () {
      // Another writer grows the file past the rotation threshold. A write
      // path that asked the filesystem for the length would rotate here; one
      // that counts its own bytes does not.
      File('${dir.path}/segno.log').writeAsStringSync(
        'x' * AppLog.maxBytes,
        mode: FileMode.append,
      );

      AppLog.info('still the same file');

      expect(File('${dir.path}/segno.log.1').existsSync(), isFalse);
      expect(
        File('${dir.path}/segno.log').readAsStringSync(),
        contains('still the same file'),
      );
    });

    test('holds one handle across many lines, appending in order', () {
      for (var i = 0; i < 50; i++) {
        AppLog.info('line $i');
      }
      final lines = File('${dir.path}/segno.log').readAsLinesSync();
      expect(lines, hasLength(50));
      expect(lines.first, contains('line 0'));
      expect(lines.last, contains('line 49'));
    });

    test(
      'a failed rotation costs one rotation, not the whole session',
      () async {
        // `segno.log.1` occupied by a non-empty directory: the rename that
        // would make room for it throws. The logfile must survive that — on
        // the appliance it is the only post-mortem there is.
        Directory('${dir.path}/segno.log.1').createSync();
        File('${dir.path}/segno.log.1/blocker').writeAsStringSync('x');
        AppLog.close();
        File('${dir.path}/segno.log').writeAsStringSync('x' * AppLog.maxBytes);
        await AppLog.init(directory: dir);

        AppLog.info('after the failed rotate');
        AppLog.info('and the line after that');

        final text = File('${dir.path}/segno.log').readAsStringSync();
        expect(text, contains('after the failed rotate'));
        expect(text, contains('and the line after that'));
      },
    );

    test(
      'an unopenable logfile degrades instead of aborting the boot',
      () async {
        // `segno.log` occupied by a directory: `openSync` throws. `init` runs
        // at the very front of `runSegno`, so it must not rethrow.
        AppLog.close();
        File('${dir.path}/segno.log').deleteSync();
        Directory('${dir.path}/segno.log').createSync();

        await AppLog.init(directory: dir);

        expect(AppLog.isInitialized, isTrue);
        // And it recovers by itself once the cause is gone.
        expect(() => AppLog.info('dropped'), returnsNormally);
        Directory('${dir.path}/segno.log').deleteSync();

        AppLog.info('recovered');

        expect(
          File('${dir.path}/segno.log').readAsStringSync(),
          contains('recovered'),
        );
      },
    );

    test('close releases the handle and a later init appends', () async {
      AppLog.info('before close');
      AppLog.close();
      expect(AppLog.isInitialized, isFalse);

      // Writes with no handle are dropped rather than reopening the file.
      AppLog.info('while closed');
      expect(
        File('${dir.path}/segno.log').readAsStringSync(),
        isNot(contains('while closed')),
      );

      await AppLog.init(directory: dir);
      AppLog.info('after reopen');
      final text = File('${dir.path}/segno.log').readAsStringSync();
      expect(text, contains('before close'));
      expect(text, contains('after reopen'));
    });
  });
}
