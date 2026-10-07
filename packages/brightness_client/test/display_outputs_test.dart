import 'dart:io';

import 'package:brightness_client/brightness_client.dart';
import 'package:test/test.dart';

const _ini = '''
[core]
shell=kiosk-shell.so
idle-time=0

[output]
name=HDMI-A-1
mode=1920x1080@60
# The main UI, on the TV.
app-ids=dev.aquiles.segno

[output]
name=HDMI-A-2
mode=current
app-ids=dev.aquiles.segno.waveform, other.app

[libinput]
touchscreen_calibrator=true
''';

void main() {
  test('reads each pinned app-id to its output', () {
    expect(parseWestonAppIdConnectors(_ini), {
      'dev.aquiles.segno': 'HDMI-A-1',
      'dev.aquiles.segno.waveform': 'HDMI-A-2',
      'other.app': 'HDMI-A-2',
    });
  });

  test('an output without app-ids pins nothing', () {
    expect(parseWestonAppIdConnectors('[output]\nname=HDMI-A-1\n'), isEmpty);
  });

  test('an output with an empty name pins nothing', () {
    expect(
      parseWestonAppIdConnectors(
        '[output]\nname=\napp-ids=dev.aquiles.segno\n',
      ),
      isEmpty,
    );
  });

  group('SystemDisplayOutputs', () {
    late Directory root;
    late SystemDisplayOutputs outputs;

    setUp(() {
      root = Directory.systemTemp.createTempSync('display-outputs');
      Directory('${root.path}/drm/card1-HDMI-A-1').createSync(recursive: true);
      File(
        '${root.path}/drm/card1-HDMI-A-1/status',
      ).writeAsStringSync('connected\n');
      Directory('${root.path}/drm/card1-HDMI-A-2').createSync(recursive: true);
      File(
        '${root.path}/drm/card1-HDMI-A-2/status',
      ).writeAsStringSync('disconnected\n');
      File('${root.path}/weston.ini').writeAsStringSync(_ini);
      outputs = SystemDisplayOutputs(
        westonIni: '${root.path}/weston.ini',
        drmRoot: '${root.path}/drm',
      );
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('reads the pins from the compositor configuration', () async {
      expect(
        (await outputs.appIdConnectors())['dev.aquiles.segno.waveform'],
        'HDMI-A-2',
      );
    });

    test('reads presence from the DRM connector status', () async {
      expect(await outputs.isConnected('HDMI-A-1'), isTrue);
      expect(await outputs.isConnected('HDMI-A-2'), isFalse);
      expect(await outputs.isConnected('DSI-1'), isNull);
    });

    test('a missing configuration pins nothing', () async {
      final missing = SystemDisplayOutputs(
        westonIni: '${root.path}/absent.ini',
        drmRoot: '${root.path}/absent',
      );
      expect(await missing.appIdConnectors(), isEmpty);
      expect(await missing.isConnected('HDMI-A-1'), isNull);
    });
  });
}
