import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:segno/app/console_audio_devices.dart';

void main() {
  group('pickConsoleAudioDevices', () {
    test('prefers a shared non-default duplex id', () {
      const devices = [
        AudioDevice(
          id: 'hdmi',
          name: 'HDMI',
          isDefault: true,
          isInput: false,
        ),
        AudioDevice(
          id: 'hdmi',
          name: 'HDMI',
          isDefault: true,
          isInput: true,
        ),
        AudioDevice(
          id: 'scarlett',
          name: 'Scarlett 4i4',
          isDefault: false,
          isInput: false,
        ),
        AudioDevice(
          id: 'scarlett',
          name: 'Scarlett 4i4',
          isDefault: false,
          isInput: true,
        ),
      ];
      expect(
        pickConsoleAudioDevices(devices),
        (playbackId: 'scarlett', captureId: 'scarlett'),
      );
    });

    test(
      'falls back to first non-default of each direction when ids differ',
      () {
        const devices = [
          AudioDevice(
            id: 'hw:1,0',
            name: 'Scarlett Out',
            isDefault: false,
            isInput: false,
          ),
          AudioDevice(
            id: 'hw:1,0c',
            name: 'Scarlett In',
            isDefault: false,
            isInput: true,
          ),
        ];
        expect(
          pickConsoleAudioDevices(devices),
          (playbackId: 'hw:1,0', captureId: 'hw:1,0c'),
        );
      },
    );

    test('returns null when only system defaults exist', () {
      const devices = [
        AudioDevice(
          id: 'default',
          name: 'Default',
          isDefault: true,
          isInput: false,
        ),
        AudioDevice(
          id: 'default',
          name: 'Default',
          isDefault: true,
          isInput: true,
        ),
      ];
      expect(pickConsoleAudioDevices(devices), isNull);
    });

    test('returns null on an empty list', () {
      expect(pickConsoleAudioDevices(const []), isNull);
    });

    test('returns null when a direction has no non-default device', () {
      const devices = [
        AudioDevice(
          id: 'scarlett',
          name: 'Scarlett',
          isDefault: false,
          isInput: false,
        ),
        AudioDevice(
          id: 'default',
          name: 'Default In',
          isDefault: true,
          isInput: true,
        ),
      ];
      expect(pickConsoleAudioDevices(devices), isNull);
    });
  });

  group('pinned devices', () {
    const scarlettOut = AudioDevice(
      id: 'scarlett',
      name: 'Scarlett 4i4',
      isDefault: false,
      isInput: false,
    );
    const scarlettIn = AudioDevice(
      id: 'scarlett',
      name: 'Scarlett 4i4',
      isDefault: false,
      isInput: true,
    );
    const pinned = EngineConfig(
      playbackDeviceId: 'scarlett',
      captureDeviceId: 'scarlett',
    );

    test('pinsDevice is true for either id and false for neither', () {
      expect(pinsDevice(pinned), isTrue);
      expect(pinsDevice(const EngineConfig(captureDeviceId: 'x')), isTrue);
      expect(pinsDevice(const EngineConfig()), isFalse);
    });

    test('present only when every pinned direction enumerates', () {
      expect(pinnedDevicesPresent(pinned, [scarlettOut, scarlettIn]), isTrue);
      expect(pinnedDevicesPresent(pinned, [scarlettOut]), isFalse);
      // The same id in the wrong direction does not count.
      expect(pinnedDevicesPresent(pinned, [scarlettIn]), isFalse);
      expect(pinnedDevicesPresent(pinned, const []), isFalse);
    });

    test('an empty id pins nothing, so it is always present', () {
      expect(
        pinnedDevicesPresent(
          const EngineConfig(playbackDeviceId: 'scarlett'),
          [scarlettOut],
        ),
        isTrue,
      );
    });
  });
}
