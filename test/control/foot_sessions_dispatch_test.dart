import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:pedal_repository/testing.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/app/application/owned_value_port.dart';
import 'package:segno/app/fx_chain_persistence.dart';
import 'package:segno/app/mix_settings_coordinator.dart';
import 'package:segno/control/control.dart';
import 'package:segno/control/model/foot_sessions.dart';
import 'package:segno/looper/application/fade_settings.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../helpers/helpers.dart';

class _Rig {
  new() {
    looper = LooperRepository(engine: engine, ticker: ticks.stream)
      ..startEngine(const EngineConfig());
    settings = SettingsRepository(store: store);
    mix = testMixSettings(looper, settings: settings);
    persistence = FxChainPersistence(looper: looper);
    pedal = PedalRepository(link);
    performance = PerformanceRepository(
      guards: GuardRegistry(),
      engine: engine,
      exportsRoot: () async => Directory.systemTemp.path,
    );
    fade = FadeSettings(
      repository: looper,
      settings: settings,
      blocked: () => false,
      sessionBlocked: () => false,
    );
    control = ControlCubit(
      looper: looper,
      pedal: pedal,
      settings: settings,
      performance: performance,
      mixSettings: mix,
      fxPersistence: persistence,
      fadeSettings: fade,
      ownedValues: OwnedValuePort(
        looper: looper,
        clickVolume: FakeClickVolumeControl(),
        clickMode: FakeClickModeControl(),
        recordStart: FakeRecordStartControl(),
        decay: FakeDecayControl(),
        oneShot: FakeOneShotControl(),
        recordLength: FakeRecordLengthControl(),
        recordTiming: FakeRecordTimingControl(),
        fade: fade,
      ),
      takeLocked: () => locked,
      startNewLoop: () => asked.add('new loop'),
      saveSession: () => asked.add('save'),
      openSession: (id) => asked.add('open $id'),
      refreshSessions: () => asked.add('refresh'),
    );
    link.hello();
  }

  final engine = FakeAudioEngine();
  final store = FakeKeyValueStore();
  final ticks = StreamController<void>.broadcast();
  final link = FakePedalLink();
  late final LooperRepository looper;
  late final SettingsRepository settings;
  late final MixSettingsCoordinator mix;
  late final FxChainPersistence persistence;
  late final PedalRepository pedal;
  late final PerformanceRepository performance;
  late final FadeSettings fade;
  late final ControlCubit control;

  /// Takes are locked: a session is opening, or the power dialog is up.
  bool locked = false;

  /// What the session layer was asked for, in order.
  final asked = <String>[];

  FootSessionsSelection get selection => control.state.footSessions;

  Future<void> stomp(
    PedalButton button, {
    Duration hold = Duration.zero,
  }) async {
    link.press(button, down: true);
    await _pump(const Duration(milliseconds: 30) + hold);
    link.press(button, down: false);
    await _pump(const Duration(milliseconds: 30));
  }

  /// A Hold: longer than the long-press threshold (800 ms by default).
  Future<void> hold(PedalButton button) =>
      stomp(button, hold: const Duration(milliseconds: 900));

  bool lit(PedalButton button) =>
      link.lastFrame!.activeButtonMask & (1 << button.index) != 0;

  Future<void> close() async {
    await control.close();
    await fade.close();
    await persistence.close();
    await mix.close();
    await pedal.dispose();
    performance.dispose();
    await looper.dispose();
    await ticks.close();
  }
}

Future<void> _pump([Duration duration = Duration.zero]) =>
    Future<void>.delayed(duration);

FootSessionCatalogue _catalogue(
  List<String> names, {
  String? openId,
  int failureCount = 0,
}) => FootSessionCatalogue(
  sessions: [for (final name in names) FootSessionEntry(id: name, name: name)],
  openId: openId,
  failureCount: failureCount,
);

const _six = ['a', 'b', 'c', 'd', 'e', 'f'];

void main() {
  /// A rig on the Sessions face, entered from [from], with [names] saved and
  /// [openId] open.
  Future<_Rig> enter({
    List<String> names = _six,
    String? openId = 'a',
    InteractionMode from = InteractionMode.record,
  }) async {
    final rig = _Rig();
    await rig.control.load();
    await _pump();
    rig.control.setSessionCatalogue(_catalogue(names, openId: openId));
    if (from != InteractionMode.record) rig.control.setMode(from);
    rig.control.setMode(InteractionMode.sessions);
    await _pump();
    return rig;
  }

  test('entering asks for the catalogue again and starts on the page of the '
      'open session', () async {
    final rig = await enter(openId: 'f');
    try {
      expect(rig.asked, ['refresh']);
      expect(rig.selection.page, 1);
      // f is the second session of the second page.
      expect(rig.lit(PedalButton.track2), isTrue);
      expect(rig.lit(PedalButton.track1), isFalse);
      expect(rig.lit(PedalButton.bank), isTrue);
      expect(rig.lit(PedalButton.mode), isTrue);
    } finally {
      await rig.close();
    }
  });

  test('a tap on a track switch shows its session and opens '
      'nothing', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      await rig.stomp(PedalButton.track3);
      expect(rig.selection.previewId, 'c');
      expect(rig.selection.openingId, isNull);
      await rig.stomp(PedalButton.track2);
      expect(rig.selection.previewId, 'b');
      expect(rig.asked, isEmpty);
      expect(rig.control.state.mode, InteractionMode.sessions);
    } finally {
      await rig.close();
    }
  });

  test('the session is shown from the moment the switch goes down, and a '
      'release before the long-press threshold opens nothing', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      rig.link.press(PedalButton.track3, down: true);
      await _pump(const Duration(milliseconds: 30));
      // Shown at once, so a hold fills under the name of what it opens.
      expect(rig.selection.previewId, 'c');
      await _pump(const Duration(milliseconds: 300));
      rig.link.press(PedalButton.track3, down: false);
      await _pump(const Duration(milliseconds: 30));
      expect(rig.asked, isEmpty);
      expect(rig.selection.previewId, 'c');
      expect(rig.selection.openingId, isNull);
    } finally {
      await rig.close();
    }
  });

  test('turning the page drops the preview', () async {
    final rig = await enter();
    try {
      await rig.stomp(PedalButton.track2);
      expect(rig.selection.previewId, 'b');
      await rig.stomp(PedalButton.bank);
      expect(rig.selection.previewId, isNull);
    } finally {
      await rig.close();
    }
  });

  test('a held track switch asks to open the session in its position, once, '
      'and waits for it', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      await rig.hold(PedalButton.track3);
      expect(rig.asked, ['open c']);
      expect(rig.selection.openingId, 'c');
      // The panel shows what is being opened.
      expect(rig.selection.previewId, 'c');
      expect(rig.control.state.mode, InteractionMode.sessions);

      // Nothing else is asked while that Open is in flight.
      await rig.hold(PedalButton.track2);
      await rig.stomp(PedalButton.undo);
      await rig.stomp(PedalButton.bank);
      await rig.stomp(
        PedalButton.clear,
        hold: const Duration(milliseconds: 900),
      );
      expect(rig.asked, ['open c']);
      expect(rig.selection.page, 0);
    } finally {
      await rig.close();
    }
  });

  test('the face closes when the session it asked for is the open one, and '
      'goes back to the mode it was entered from', () async {
    final rig = await enter(from: InteractionMode.custom);
    try {
      await rig.hold(PedalButton.track2);
      expect(rig.selection.openingId, 'b');
      // The session layer reports its progress: still the old session.
      rig.control.setSessionCatalogue(_catalogue(_six, openId: 'a'));
      await _pump();
      expect(rig.control.state.mode, InteractionMode.sessions);

      rig.control.setSessionCatalogue(_catalogue(_six, openId: 'b'));
      await _pump();
      expect(rig.control.state.mode, InteractionMode.custom);
      expect(rig.selection.openingId, isNull);
    } finally {
      await rig.close();
    }
  });

  test(
    'an Open that fails gives the switches back and keeps the face up',
    () async {
      final rig = await enter();
      try {
        rig.asked.clear();
        await rig.hold(PedalButton.track2);
        rig.control.setSessionCatalogue(
          _catalogue(_six, openId: 'a', failureCount: 1),
        );
        await _pump();
        expect(rig.control.state.mode, InteractionMode.sessions);
        expect(rig.selection.openingId, isNull);
        // Its switch is dark again: the Open did not happen.
        expect(rig.lit(PedalButton.track2), isFalse);

        await rig.hold(PedalButton.track4);
        expect(rig.asked, ['open b', 'open d']);
      } finally {
        await rig.close();
      }
    },
  );

  test('the switch under the open session previews it, and neither a tap '
      'nor a hold opens it or closes the face', () async {
    final rig = await enter(from: InteractionMode.mute);
    try {
      rig.asked.clear();
      await rig.stomp(PedalButton.track1);
      expect(rig.selection.previewId, 'a');
      await rig.hold(PedalButton.track1);
      expect(rig.asked, isEmpty);
      expect(rig.selection.openingId, isNull);
      expect(rig.control.state.mode, InteractionMode.sessions);
    } finally {
      await rig.close();
    }
  });

  group('the fill of a hold to open', () {
    PedalStateFrame frame(_Rig rig) => rig.link.lastFrame!;

    test('runs left to right on the held switch, in the frame, and ends as '
        'a lit switch when the hold fires', () async {
      final rig = await enter();
      try {
        expect(frame(rig).queuedButton, isNull);
        rig.link.press(PedalButton.track3, down: true);
        await _pump(const Duration(milliseconds: 60));
        // The board fills a lit switch in its colour.
        expect(frame(rig).queuedButton, PedalButton.track3);
        expect(rig.lit(PedalButton.track3), isTrue);
        final early = frame(rig).queuedProgress;
        expect(early, lessThan(64));

        await _pump(const Duration(milliseconds: 400));
        expect(frame(rig).queuedButton, PedalButton.track3);
        expect(frame(rig).queuedProgress, greaterThan(early));
        expect(rig.asked, isNot(contains('open c')));

        // Past the threshold the hold has fired: no fill, the whole switch.
        await _pump(const Duration(milliseconds: 500));
        expect(rig.asked, contains('open c'));
        expect(frame(rig).queuedButton, isNull);
        expect(rig.lit(PedalButton.track3), isTrue);

        // It stays lit after the release, until the Open settles.
        rig.link.press(PedalButton.track3, down: false);
        await _pump(const Duration(milliseconds: 30));
        expect(frame(rig).queuedButton, isNull);
        expect(rig.lit(PedalButton.track3), isTrue);
      } finally {
        await rig.close();
      }
    });

    test('ends with a dark switch on a release before the threshold', () async {
      final rig = await enter();
      try {
        rig.link.press(PedalButton.track3, down: true);
        await _pump(const Duration(milliseconds: 200));
        expect(frame(rig).queuedButton, PedalButton.track3);
        rig.link.press(PedalButton.track3, down: false);
        await _pump(const Duration(milliseconds: 30));
        expect(frame(rig).queuedButton, isNull);
        expect(frame(rig).queuedProgress, 0);
        expect(rig.lit(PedalButton.track3), isFalse);
      } finally {
        await rig.close();
      }
    });

    test('never starts on the open session, an empty position or a locked '
        'take', () async {
      final rig = await enter(names: const ['a', 'b']);
      try {
        for (final button in [PedalButton.track1, PedalButton.track3]) {
          rig.link.press(button, down: true);
          await _pump(const Duration(milliseconds: 60));
          expect(frame(rig).queuedButton, isNull, reason: button.name);
          rig.link.press(button, down: false);
          await _pump(const Duration(milliseconds: 30));
        }
        rig.locked = true;
        rig.link.press(PedalButton.track2, down: true);
        await _pump(const Duration(milliseconds: 60));
        expect(frame(rig).queuedButton, isNull);
        rig.link.press(PedalButton.track2, down: false);
        await _pump(const Duration(milliseconds: 30));
      } finally {
        await rig.close();
      }
    });

    test('a second switch going down while one is held opens neither, and '
        'does not take the readout', () async {
      final rig = await enter();
      try {
        rig.asked.clear();
        rig.link.press(PedalButton.track2, down: true);
        await _pump(const Duration(milliseconds: 100));
        expect(frame(rig).queuedButton, PedalButton.track2);
        rig.link.press(PedalButton.track3, down: true);
        await _pump(const Duration(milliseconds: 30));
        // The first hold is over, and the second never started one.
        expect(frame(rig).queuedButton, isNull);

        await _pump(const Duration(milliseconds: 900));
        expect(rig.asked, isEmpty);
        rig.link.press(PedalButton.track2, down: false);
        rig.link.press(PedalButton.track3, down: false);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.asked, isEmpty);
        // The first switch's session stays shown; the second's never was.
        expect(rig.selection.previewId, 'b');
        expect(rig.selection.openingId, isNull);
      } finally {
        await rig.close();
      }
    });

    test('opens nothing when the switch stands for another session by the '
        'time the hold fires', () async {
      final rig = await enter();
      try {
        rig.asked.clear();
        rig.link.press(PedalButton.track2, down: true);
        await _pump(const Duration(milliseconds: 200));
        // The fresh catalogue lands during the hold: switch 2 is now `bb`.
        rig.control.setSessionCatalogue(
          _catalogue(const ['a', 'aa', 'bb', 'c'], openId: 'a'),
        );
        await _pump(const Duration(milliseconds: 800));
        rig.link.press(PedalButton.track2, down: false);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.asked, isEmpty);
        expect(rig.selection.openingId, isNull);
      } finally {
        await rig.close();
      }
    });

    test('stops when the page turns under the held switch, and nothing '
        'opens', () async {
      final rig = await enter();
      try {
        rig.asked.clear();
        rig.link.press(PedalButton.track2, down: true);
        await _pump(const Duration(milliseconds: 150));
        expect(frame(rig).queuedButton, PedalButton.track2);
        // Bank with the other foot: switch 2 now stands for another session.
        await rig.stomp(PedalButton.bank);
        expect(rig.selection.page, 1);
        await _pump(const Duration(milliseconds: 60));
        expect(frame(rig).queuedButton, isNull);
        await _pump(const Duration(milliseconds: 800));
        expect(rig.asked, isEmpty);
        rig.link.press(PedalButton.track2, down: false);
        await _pump(const Duration(milliseconds: 30));
        expect(rig.selection.openingId, isNull);
      } finally {
        await rig.close();
      }
    });

    test('stops when takes lock while the hold is pending', () async {
      final rig = await enter();
      try {
        rig.asked.clear();
        rig.link.press(PedalButton.track3, down: true);
        await _pump(const Duration(milliseconds: 200));
        expect(frame(rig).queuedButton, PedalButton.track3);
        rig.locked = true;
        await _pump(const Duration(milliseconds: 100));
        expect(frame(rig).queuedButton, isNull);
        await _pump(const Duration(milliseconds: 700));
        expect(rig.asked, isEmpty);
        rig.link.press(PedalButton.track3, down: false);
        await _pump(const Duration(milliseconds: 30));
      } finally {
        await rig.close();
      }
    });
  });

  test('an empty position does nothing', () async {
    final rig = await enter(names: const ['a', 'b']);
    try {
      rig.asked.clear();
      await rig.stomp(PedalButton.track3);
      await rig.stomp(PedalButton.bank);
      expect(rig.asked, isEmpty);
      expect(rig.control.state.mode, InteractionMode.sessions);
      expect(rig.selection.page, 0);
    } finally {
      await rig.close();
    }
  });

  test('Bank shows the next four and wraps to the first', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      await rig.stomp(PedalButton.bank);
      expect(rig.selection.page, 1);
      expect(rig.lit(PedalButton.bank), isTrue);
      await rig.hold(PedalButton.track1);
      expect(rig.asked, ['open e']);

      final again = await enter();
      try {
        await again.stomp(PedalButton.bank);
        await again.stomp(PedalButton.bank);
        expect(again.selection.page, 0);
        expect(again.lit(PedalButton.bank), isFalse);
      } finally {
        await again.close();
      }
    } finally {
      await rig.close();
    }
  });

  group('folders', () {
    FootSessionCatalogue folders({String? openId = 'b2'}) =>
        FootSessionCatalogue(
          sessions: const [
            FootSessionEntry(id: 'loose', name: 'loose'),
            FootSessionEntry(id: 'b1', name: 'b1', folder: 'Friday set'),
            FootSessionEntry(id: 'b2', name: 'b2', folder: 'Friday set'),
            FootSessionEntry(id: 'a1', name: 'a1', folder: 'Archive'),
          ],
          openId: openId,
        );

    Future<_Rig> enterFolders({String? openId = 'b2'}) async {
      final rig = _Rig();
      await rig.control.load();
      await _pump();
      rig.control
        ..setSessionCatalogue(folders(openId: openId))
        ..setMode(InteractionMode.sessions);
      await _pump();
      rig.asked.clear();
      return rig;
    }

    test('the face opens on the folder of the open session', () async {
      final rig = await enterFolders();
      try {
        expect(rig.selection.folder, 'Friday set');
        expect(rig.lit(PedalButton.track2), isTrue);
        await rig.hold(PedalButton.track1);
        expect(rig.asked, ['open b1']);
      } finally {
        await rig.close();
      }
    });

    test(
      'with no open session it opens on the sessions outside a folder',
      () async {
        final rig = await enterFolders(openId: null);
        try {
          expect(rig.selection.folder, isNull);
          await rig.hold(PedalButton.track1);
          expect(rig.asked, ['open loose']);
        } finally {
          await rig.close();
        }
      },
    );

    test(
      'a held Bank shows the next folder and does not also turn the page',
      () async {
        final rig = await enterFolders();
        try {
          await rig.stomp(
            PedalButton.bank,
            hold: const Duration(milliseconds: 900),
          );
          // Archive, Friday set, then the sessions outside a folder.
          expect(rig.selection.folder, isNull);
          expect(rig.selection.page, 0);
          expect(rig.asked, isEmpty);

          // Past the last folder it wraps to the first.
          await rig.stomp(
            PedalButton.bank,
            hold: const Duration(milliseconds: 900),
          );
          expect(rig.selection.folder, 'Archive');
          await rig.hold(PedalButton.track1);
          expect(rig.asked, ['open a1']);
        } finally {
          await rig.close();
        }
      },
    );

    test(
      'a press of Bank with one page and other folders changes nothing',
      () async {
        final rig = await enterFolders();
        try {
          await rig.stomp(PedalButton.bank);
          expect(rig.selection.folder, 'Friday set');
          expect(rig.selection.page, 0);
          expect(rig.asked, isEmpty);
        } finally {
          await rig.close();
        }
      },
    );
  });

  test(
    'with folders, a press of Bank still turns the page, on its release',
    () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await _pump();
        rig.control
          ..setSessionCatalogue(
            FootSessionCatalogue(
              sessions: [
                for (final name in _six)
                  FootSessionEntry(id: name, name: name, folder: 'Set'),
                const FootSessionEntry(id: 'loose', name: 'loose'),
              ],
              openId: 'a',
            ),
          )
          ..setMode(InteractionMode.sessions);
        await _pump();
        await rig.stomp(PedalButton.bank);
        expect(rig.selection.folder, 'Set');
        expect(rig.selection.page, 1);
      } finally {
        await rig.close();
      }
    },
  );

  test(
    'a failed Open is marked on its session until another is asked',
    () async {
      final rig = await enter();
      try {
        await rig.hold(PedalButton.track2);
        rig.control.setSessionCatalogue(
          _catalogue(_six, openId: 'a', failureCount: 1),
        );
        await _pump();
        expect(rig.selection.failedId, 'b');
        expect(rig.selection.openingId, isNull);

        await rig.hold(PedalButton.track3);
        expect(rig.selection.failedId, isNull);
        expect(rig.selection.openingId, 'c');
      } finally {
        await rig.close();
      }
    },
  );

  test('Undo saves and closes the face', () async {
    final rig = await enter(from: InteractionMode.custom);
    try {
      rig.asked.clear();
      await rig.stomp(PedalButton.undo);
      expect(rig.asked, ['save']);
      expect(rig.control.state.mode, InteractionMode.custom);
    } finally {
      await rig.close();
    }
  });

  test('a press of Clear does nothing; a held Clear starts a new loop and '
      'closes the face', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      await rig.stomp(PedalButton.clear);
      expect(rig.asked, isEmpty);
      expect(rig.control.state.mode, InteractionMode.sessions);

      await rig.stomp(
        PedalButton.clear,
        hold: const Duration(milliseconds: 900),
      );
      expect(rig.asked, ['new loop']);
      expect(rig.control.state.mode, InteractionMode.record);
    } finally {
      await rig.close();
    }
  });

  test('a Custom switch assigned Sessions opens the face, and MODE goes '
      'back to Custom', () async {
    const sessions = ModeAction(InteractionMode.sessions);
    final rig = _Rig();
    try {
      await rig.control.load();
      await _pump();
      await rig.control.setPedalSetup(
        const PedalSetup().withCustom(
          PedalButton.track1,
          bank: 0,
          pair: const ControlGesturePair(press: sessions),
        ),
      );
      rig.control
        ..setMode(InteractionMode.custom)
        ..activateFootCustomPedal(PedalButton.track1);
      await _pump();
      expect(rig.control.state.mode, InteractionMode.sessions);

      rig.control.activateFootSessionsPedal(PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.custom);
    } finally {
      await rig.close();
    }
  });

  test('MODE goes back and asks for nothing', () async {
    final rig = await enter(from: InteractionMode.custom);
    try {
      rig.asked.clear();
      await rig.stomp(PedalButton.mode);
      expect(rig.asked, isEmpty);
      expect(rig.control.state.mode, InteractionMode.custom);
    } finally {
      await rig.close();
    }
  });

  test('entered from a mode whose entry changes the rig, the face goes back '
      'to Tracks', () async {
    final rig = await enter(from: InteractionMode.fx);
    try {
      await rig.stomp(PedalButton.mode);
      expect(rig.control.state.mode, InteractionMode.record);
    } finally {
      await rig.close();
    }
  });

  test('Rec / Play and Stop keep the transport', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      final before = rig.engine.recordCalls;
      await rig.stomp(PedalButton.recPlay);
      expect(rig.engine.recordCalls, before + 1);
      expect(rig.asked, isEmpty);
      expect(rig.control.state.mode, InteractionMode.sessions);
    } finally {
      await rig.close();
    }
  });

  test('nothing is asked while takes are locked', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      rig.locked = true;
      await rig.stomp(PedalButton.track2);
      await rig.hold(PedalButton.track2);
      expect(rig.selection.previewId, isNull);
      await rig.stomp(PedalButton.undo);
      await rig.stomp(
        PedalButton.clear,
        hold: const Duration(milliseconds: 900),
      );
      expect(rig.asked, isEmpty);
      expect(rig.control.state.mode, InteractionMode.sessions);
    } finally {
      await rig.close();
    }
  });

  test(
    'a catalogue handed over off the face is kept for the next entry',
    () async {
      final rig = _Rig();
      try {
        await rig.control.load();
        await _pump();
        rig.control.setSessionCatalogue(
          _catalogue(const ['x', 'y'], openId: 'y'),
        );
        expect(rig.control.state.mode, InteractionMode.record);
        rig.control.setMode(InteractionMode.sessions);
        await _pump();
        expect(rig.lit(PedalButton.track2), isTrue);
      } finally {
        await rig.close();
      }
    },
  );

  test('the semantic activation runs the same roles: a tap previews, and '
      'New loop and an Open take their Hold', () async {
    final rig = await enter();
    try {
      rig.asked.clear();
      rig.control.activateFootSessionsPedal(PedalButton.clear);
      expect(rig.asked, isEmpty);
      rig.control.activateFootSessionsPedal(PedalButton.track2);
      expect(rig.asked, isEmpty);
      expect(rig.selection.previewId, 'b');
      // The open session has nothing to open.
      rig.control.activateFootSessionsPedal(PedalButton.track1, hold: true);
      expect(rig.asked, isEmpty);
      rig.control.activateFootSessionsPedal(PedalButton.track2, hold: true);
      expect(rig.asked, ['open b']);
    } finally {
      await rig.close();
    }
  });

  test('the semantic Hold of Bank shows the next folder', () async {
    final rig = _Rig();
    try {
      await rig.control.load();
      await _pump();
      rig.control
        ..setSessionCatalogue(
          const FootSessionCatalogue(
            sessions: [
              FootSessionEntry(id: 'a', name: 'a', folder: 'One'),
              FootSessionEntry(id: 'b', name: 'b', folder: 'Two'),
            ],
            openId: 'a',
          ),
        )
        ..setMode(InteractionMode.sessions)
        ..activateFootSessionsPedal(PedalButton.bank, hold: true);
      expect(rig.selection.folder, 'Two');
    } finally {
      await rig.close();
    }
  });
}
