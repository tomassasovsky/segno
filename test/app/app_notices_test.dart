import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:midi_device_repository/midi_device_repository.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/notices/notices.dart';

Notice _recovery() => Notice(
  id: AppNoticeId.mixSettings,
  tone: NoticeTone.critical,
  title: (_) => 'Mix settings need a retry',
);

void main() {
  group('retryNoticeAction', () {
    late NoticesCubit notices;

    setUp(() {
      notices = NoticesCubit();
      addTearDown(notices.close);
    });

    test('ends the message when the retry worked', () async {
      notices.raise(_recovery());
      final retry = retryNoticeAction(
        notices,
        AppNoticeId.mixSettings,
        () async => true,
      );
      retry.onPressed();
      await pumpEventQueue();
      expect(notices.state.banners, isEmpty);
    });

    test('keeps it when the retry failed', () async {
      notices.raise(_recovery());
      retryNoticeAction(
        notices,
        AppNoticeId.mixSettings,
        () async => false,
      ).onPressed();
      await pumpEventQueue();
      expect(notices.state.banners, hasLength(1));
    });

    test('of two quick presses, the one that finds the owner ready clears '
        'it', () async {
      notices.raise(_recovery());
      final first = Completer<bool>();
      final second = Completer<bool>();
      retryNoticeAction(
        notices,
        AppNoticeId.mixSettings,
        () => first.future,
      ).onPressed();
      retryNoticeAction(
        notices,
        AppNoticeId.mixSettings,
        () => second.future,
      ).onPressed();
      // The first attempt fails and raises the recovery again.
      first.complete(false);
      notices.raise(_recovery());
      second.complete(true);
      await pumpEventQueue();
      expect(notices.state.banners, isEmpty);
    });
  });

  group('midiIsInterfacesOwn (#860)', () {
    const scarlettMidi = MidiConnection(
      selectedId: 'Scarlett 4i4 USB',
      selectedName: 'Scarlett 4i4 USB MIDI 1',
      connectivity: MidiConnectivity.lost,
      connectivityDeviceName: 'Scarlett 4i4 USB MIDI 1',
    );
    const pedal = MidiConnection(
      selectedId: 'fcb1010',
      selectedName: 'FCB1010',
      connectivity: MidiConnectivity.lost,
      connectivityDeviceName: 'FCB1010',
    );
    const lost = AudioSetupState(
      deviceConnectivity: DeviceConnectivity.lost,
      connectivityDeviceName: 'Scarlett 4i4 USB',
    );

    test("the gone interface's own ports are its", () {
      expect(
        midiIsInterfacesOwn(scarlettMidi, lost, audioJustChanged: false),
        isTrue,
      );
    });

    test('another controller, long after, is its own cause', () {
      expect(
        midiIsInterfacesOwn(pedal, lost, audioJustChanged: false),
        isFalse,
      );
    });

    test('anything within moments of the interface is its', () {
      expect(
        midiIsInterfacesOwn(
          pedal,
          const AudioSetupState(),
          audioJustChanged: true,
        ),
        isTrue,
      );
    });

    test('with the interface present, its ports are their own cause', () {
      expect(
        midiIsInterfacesOwn(
          scarlettMidi,
          const AudioSetupState(connectivityDeviceName: 'Scarlett 4i4 USB'),
          audioJustChanged: false,
        ),
        isFalse,
      );
    });
  });
}
