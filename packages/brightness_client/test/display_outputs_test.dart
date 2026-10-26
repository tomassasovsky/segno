import 'dart:io';

import 'package:brightness_client/brightness_client.dart';
import 'package:test/test.dart';
import 'package:toml/toml.dart';

const _toml = '''
# ivi-homescreen configuration.
[global]
disable_cursor = true

[[view]]
bundle = '/opt/segno'
fullscreen = true

  [view.args]
  dart = ['--segno-screen=main']
  engine = ['--enable-impeller=false']

  [view.backend]
  type = 'drm-kms-egl'

  [view.output]
  drm_connector = 'HDMI-A-1'

[[view]]
bundle = '/opt/segno'
pixel_ratio = 1.6

  [view.args]
  dart = ["--segno-screen=readout"]

  [view.output]
  drm_connector = "HDMI-A-2"
  touch_device = 'USB2IIC_CTP_CONTROL'
''';

void main() {
  test("reads each view's screen to its connector", () {
    expect(parseHomescreenScreenConnectors(_toml), {
      'main': 'HDMI-A-1',
      'readout': 'HDMI-A-2',
    });
  });

  test('a view without a screen or a connector pins nothing', () {
    expect(
      parseHomescreenScreenConnectors(
        "[[view]]\n  [view.output]\n  drm_connector = 'HDMI-A-1'\n",
      ),
      isEmpty,
    );
    expect(
      parseHomescreenScreenConnectors(
        "[[view]]\n  [view.args]\n  dart = ['--segno-screen=main']\n",
      ),
      isEmpty,
    );
  });

  test('an empty connector pins nothing', () {
    expect(
      parseHomescreenScreenConnectors(
        "[[view]]\n  [view.args]\n  dart = ['--segno-screen=main']\n"
        "  [view.output]\n  drm_connector = ''\n",
      ),
      isEmpty,
    );
  });

  test('a key outside any view belongs to no screen', () {
    expect(
      parseHomescreenScreenConnectors(
        "[global]\ndrm_connector = 'HDMI-A-1'\n"
        "dart = ['--segno-screen=main']\n",
      ),
      isEmpty,
    );
  });

  test('reads any TOML spelling of the same keys', () {
    expect(
      parseHomescreenScreenConnectors('''
[[ view ]]  # the main screen
args.dart = [
  '--segno-screen=main',
]
output.drm_connector = 'HDMI-A-1'
'''),
      {'main': 'HDMI-A-1'},
    );
  });

  test('a file that is not TOML throws', () {
    expect(
      () => parseHomescreenScreenConnectors('[[view]\n'),
      throwsA(isA<TomlParserException>()),
    );
  });

  test('reads the configuration the image ships', () {
    final shipped = File(
      '../../deploy/yocto/meta-segno/recipes-segno/segno-bundle/files/'
      'homescreen.toml',
    );
    // The console's cabling: the 15.6in main panel on HDMI1, the 7in on HDMI0.
    expect(parseHomescreenScreenConnectors(shipped.readAsStringSync()), {
      'main': 'HDMI-A-2',
      'readout': 'HDMI-A-1',
    });
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
      File('${root.path}/homescreen.toml').writeAsStringSync(_toml);
      outputs = SystemDisplayOutputs(
        homescreenConfig: '${root.path}/homescreen.toml',
        drmRoot: '${root.path}/drm',
      );
    });

    tearDown(() => root.deleteSync(recursive: true));

    test("reads the connectors from the embedder's configuration", () async {
      expect((await outputs.screenConnectors())['readout'], 'HDMI-A-2');
    });

    test('reads presence from the DRM connector status', () async {
      expect(await outputs.isConnected('HDMI-A-1'), isTrue);
      expect(await outputs.isConnected('HDMI-A-2'), isFalse);
      expect(await outputs.isConnected('DSI-1'), isNull);
    });

    test('a missing configuration pins nothing', () async {
      final missing = SystemDisplayOutputs(
        homescreenConfig: '${root.path}/absent.toml',
        drmRoot: '${root.path}/absent',
      );
      expect(await missing.screenConnectors(), isEmpty);
      expect(await missing.isConnected('HDMI-A-1'), isNull);
    });

    test('a configuration that is not TOML pins nothing', () async {
      File('${root.path}/homescreen.toml').writeAsStringSync('[[view]\n');
      expect(await outputs.screenConnectors(), isEmpty);
    });
  });
}
