import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'packages/fx_catalogue/assets/manifest.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Whichever of the two runs second checks that the first one's cached read
  // was cleared, so the check holds in any test order.
  Future<String>? previous;

  void readsAfresh() {
    final read = rootBundle.loadString(_key);
    if (previous != null) expect(identical(read, previous), isFalse);
    previous = read;
  }

  group('flutter_test_config', () {
    test('clears rootBundle after a test (first read)', readsAfresh);
    test('clears rootBundle after a test (second read)', readsAfresh);
  });
}
