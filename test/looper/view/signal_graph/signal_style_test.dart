import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';

void main() {
  group('signalGainReadout', () {
    // Public and shared by two surfaces since #533 — the knob on the surface
    // being replaced and the Signal panel's level row — so its branches are
    // pinned here rather than only through whichever widget happens to call it.
    test('unity is 0.0 dB, not 1.0', () {
      expect(signalGainReadout(1), '0.0 dB');
    });

    test('the ceiling is +6.0 dB', () {
      expect(signalGainReadout(2), '+6.0 dB');
    });

    test('attenuation carries a real minus, not a hyphen', () {
      final quiet = signalGainReadout(0.5);
      expect(quiet, '−6.0 dB');
      expect(quiet.startsWith('−'), isTrue);
    });

    test('silence is −∞ rather than a very large number', () {
      expect(signalGainReadout(0), '−∞');
      expect(signalGainReadout(0.0005), '−∞');
    });

    test('the epsilon around unity reads flat', () {
      expect(signalGainReadout(1.001), '0.0 dB');
      expect(signalGainReadout(0.999), '0.0 dB');
    });
  });
}
