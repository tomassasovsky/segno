import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/window/window_chrome.dart';

void main() {
  group('segnoUsesCursorAutoHide', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('matches segnoUsesFlutterTitleBar on Windows (custom chrome)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(segnoUsesCursorAutoHide, isTrue);
      expect(segnoUsesCursorAutoHide, equals(segnoUsesFlutterTitleBar));
    });

    test('matches segnoUsesFlutterTitleBar on macOS (no custom chrome)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(segnoUsesCursorAutoHide, isFalse);
      expect(segnoUsesCursorAutoHide, equals(segnoUsesFlutterTitleBar));
    });

    test('on for the Linux console build', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(segnoUsesCursorAutoHide, isTrue);
    });
  });

  group('shouldFullscreenMainWindow', () {
    test('single display → windowed (no auto-fullscreen)', () {
      expect(shouldFullscreenMainWindow(1), isFalse);
    });

    test('two displays → full-screen the console', () {
      expect(shouldFullscreenMainWindow(2), isTrue);
    });

    test('three or more displays → still full-screen', () {
      expect(shouldFullscreenMainWindow(3), isTrue);
    });

    test('zero displays (headless / unknown) → windowed, never crash', () {
      expect(shouldFullscreenMainWindow(0), isFalse);
    });
  });
}
