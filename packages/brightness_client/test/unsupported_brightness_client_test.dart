import 'package:brightness_client/brightness_client.dart';
import 'package:test/test.dart';

void main() {
  test('unsupported client reports false', () async {
    const client = UnsupportedBrightnessClient();
    expect(await client.isSupported('HDMI-A-1'), isFalse);
    await client.set('HDMI-A-1', 0.5);
  });

  test('unknown outputs pin nothing and know no presence', () async {
    const outputs = UnknownDisplayOutputs();
    expect(await outputs.appIdConnectors(), isEmpty);
    expect(await outputs.isConnected('HDMI-A-1'), isNull);
  });
}
