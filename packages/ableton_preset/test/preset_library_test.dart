import 'dart:io';

import 'package:ableton_preset/ableton_preset.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'helpers/fixtures.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('preset_library_'));

  tearDown(() {
    // Restore permissions a test took away, so the folder can be removed.
    Process.runSync('chmod', ['-R', 'u+rwx', root.path]);
    root.deleteSync(recursive: true);
  });

  File write(String relative, List<int> bytes) =>
      File(p.joinAll([root.path, ...p.posix.split(relative)]))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

  List<int> drift() => gzipped(devicePreset('Drift', driftParameters()));

  test('lists presets with their device, name and Live folder names', () async {
    write('Instruments/Drift/Bass/Deep.adv', drift());
    write('Instruments/Drift/Pad/Wide.adv', drift());
    write(
      'Instruments/Operator/Keys/Bell.adv',
      gzipped(devicePreset('Operator', [leaf('Volume', 1)])),
    );
    final library = await PresetLibrary.scan(root);
    expect(
      [
        for (final entry in library.entries)
          (entry.device, entry.folderPath.join('/'), entry.name, entry.status),
      ],
      [
        ('Drift', 'Instruments/Drift/Bass', 'Deep', PresetStatus.playable),
        ('Drift', 'Instruments/Drift/Pad', 'Wide', PresetStatus.playable),
        (
          'Operator',
          'Instruments/Operator/Keys',
          'Bell',
          PresetStatus.unsupportedDevice,
        ),
      ],
    );
    final first = library.entries.first;
    expect(first.path, p.join(root.path, 'Instruments/Drift/Bass/Deep.adv'));
    expect(first.preset!.folderPath, ['Instruments', 'Drift', 'Bass']);
    expect(DriftSchema().read(first.preset!).missing, isEmpty);
    expect(first.error, isNull);
  });

  test('groups the readable presets by device in path order', () async {
    write('b/Two.adv', drift());
    write('a/One.adv', drift());
    write('Bell.adv', gzipped(devicePreset('Operator', const [])));
    write('Broken.adv', const [1, 2, 3]);
    final groups = (await PresetLibrary.scan(root)).byDevice;
    expect(groups.keys, ['Operator', 'Drift']);
    expect([for (final entry in groups['Drift']!) entry.name], ['One', 'Two']);
  });

  test('lists a rack as a rack, not playable', () async {
    write(
      'Instruments/Drum Rack/Kit.adg',
      gzipped(rackPreset('DrumGroupDevice')),
    );
    final entry = (await PresetLibrary.scan(root)).entries.single;
    expect(entry.status, PresetStatus.rack);
    expect(entry.device, 'DrumGroupDevice');
    expect(entry.name, 'Kit');
  });

  test('lists a file it cannot read as unreadable, with the reason', () async {
    final bytes = drift();
    write('Cut.adv', bytes.sublist(0, bytes.length ~/ 2));
    write('Old.adv', gzipped(devicePreset('Drift', const [], major: '4')));
    final entries = (await PresetLibrary.scan(root)).entries;
    expect(
      [for (final entry in entries) (entry.name, entry.status, entry.device)],
      [
        ('Cut', PresetStatus.unreadable, null),
        ('Old', PresetStatus.unreadable, null),
      ],
    );
    expect(entries.first.error!.failure, PresetFailure.compression);
    expect(entries.last.error!.failure, PresetFailure.schema);
    expect(entries.first.folderPath, isEmpty);
  });

  test('reads only presets, and skips hidden files and folders', () async {
    write('Drift/Keep.ADV', drift());
    write('Drift/._Keep.adv', const [0, 5, 22, 7]);
    write('.Trash/Gone.adv', drift());
    write('Drift/notes.txt', const [65]);
    write('Drift/Ableton Folder Info/folder.cfg', const [65]);
    final entries = (await PresetLibrary.scan(root)).entries;
    expect([for (final entry in entries) entry.name], ['Keep']);
  });

  test('does not follow links', () async {
    write('Real/Keep.adv', drift());
    Link(p.join(root.path, 'Loop')).createSync(root.path);
    Link(p.join(root.path, 'Copy.adv'))
        .createSync(p.join(root.path, 'Real/Keep.adv'));
    final entries = (await PresetLibrary.scan(root)).entries;
    expect(
      [for (final entry in entries) entry.path],
      [p.join(root.path, 'Real/Keep.adv')],
    );
  });

  test(
    'skips a folder it cannot list and lists a file it cannot open',
    () async {
      write('Locked/Hidden.adv', drift());
      final closed = write('Closed.adv', drift());
      Process.runSync('chmod', ['000', p.join(root.path, 'Locked')]);
      Process.runSync('chmod', ['000', closed.path]);
      final entries = (await PresetLibrary.scan(root)).entries;
      expect(
        [for (final entry in entries) (entry.name, entry.status)],
        [('Closed', PresetStatus.unreadable)],
      );
      expect(entries.single.error!.failure, PresetFailure.file);
    },
    // Permissions do not hold back root (some CI containers), nor Windows.
    skip: Platform.isWindows || _isRoot()
        ? 'permissions are not enforced here'
        : false,
  );

  test('plays only the devices it is given', () async {
    write('Deep.adv', drift());
    final library = await PresetLibrary.scan(root, devices: const {});
    expect(library.entries.single.status, PresetStatus.unsupportedDevice);
  });

  test('lists nothing for a folder that does not exist', () async {
    final library = await PresetLibrary.scan(
      Directory(p.join(root.path, 'none')),
    );
    expect(library.entries, isEmpty);
    expect(library.byDevice, isEmpty);
  });
}

bool _isRoot() =>
    (Process.runSync('id', ['-u']).stdout as String).trim() == '0';
