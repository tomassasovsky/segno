import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/signal_graph/signal_style.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/visualizer/console_volume_overlay.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/readout_control.dart';

void main() {
  group('ConsoleVolumeOverlay', () {
    // The bench rig the pen draws: two configured inputs, eight live tracks
    // of which four carry custom names (TRACK 5-8 are default identities).
    const readout = PerformanceReadout(
      inputs: [
        ReadoutInput(index: 0, name: 'GUITAR'),
        ReadoutInput(
          index: 1,
          name: 'MIC',
          volume: 0.5,
          listeningTracks: ['VOX', 'TRACK 7'],
        ),
      ],
      tracks: [
        ReadoutTrack(
          name: 'GUITAR',
          state: 'playing',
          volume: 1.26,
          inputNames: ['GUITAR'],
        ),
        ReadoutTrack(name: 'BOOM', state: 'playing'),
        ReadoutTrack(name: 'RC-20', state: 'playing', muted: true),
        ReadoutTrack(name: 'VOX', state: 'playing', chainEnabled: false),
        ReadoutTrack(name: 'TRACK 5', state: 'empty', defaultName: true),
        ReadoutTrack(name: 'TRACK 6', state: 'empty', defaultName: true),
        ReadoutTrack(name: 'TRACK 7', state: 'empty', defaultName: true),
        ReadoutTrack(name: 'TRACK 8', state: 'empty', defaultName: true),
      ],
    );

    late List<ReadoutControl> controls;

    Future<void> pump(
      WidgetTester tester, [
      PerformanceReadout data = readout,
    ]) async {
      controls = <ReadoutControl>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.neon,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ConsoleVolumeOverlay(
              readout: data,
              onControl: (control) => controls.add(control),
              child: const SizedBox.expand(key: Key('readout_face')),
            ),
          ),
        ),
      );
      // Unmount before the harness checks timers: the overlay arms the
      // 8 s revert and the throttle gap, both cancelled by dispose.
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('console_readout_touch')));
      await tester.pump();
    }

    testWidgets('tapping anywhere on the readout opens the volume list', (
      tester,
    ) async {
      await pump(tester);
      // The whole glass is the touch target — the readout face is wrapped,
      // not given a button.
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
      await open(tester);

      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);
      expect(find.text('INPUTS'), findsOneWidget);
      expect(find.text('TRACKS'), findsOneWidget);
      expect(find.text('BACK TO STAGE'), findsOneWidget);
      expect(find.byKey(const Key('readout_face')), findsNothing);
    });

    testWidgets('renders one row per configured input and per live track', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      expect(find.byKey(const Key('volume_row_input_0')), findsOneWidget);
      expect(find.byKey(const Key('volume_row_input_1')), findsOneWidget);
      for (var channel = 0; channel < 8; channel++) {
        expect(
          find.byKey(Key('volume_row_track_$channel')),
          findsOneWidget,
          reason: 'the TRACKS group is the LIVE track count',
        );
      }
    });

    testWidgets(
      'default-named tracks render in the secondary tone, custom in primary',
      (tester) async {
        await pump(tester);
        await open(tester);

        final surface = AppTheme.neon.extension<SurfaceTheme>()!;
        AppText nameOf(String rowKey) => tester.widget<AppText>(
          find
              .descendant(
                of: find.byKey(Key(rowKey)),
                matching: find.byType(AppText),
              )
              .first,
        );
        expect(nameOf('volume_row_track_0').style?.color, surface.textPrimary);
        expect(
          nameOf('volume_row_track_4').style?.color,
          surface.textSecondary,
        );
        // The default identity is the localized default name.
        expect(find.text('TRACK 5'), findsOneWidget);
      },
    );

    testWidgets('volumes render as signed one-decimal dB', (tester) async {
      await pump(tester);
      await open(tester);

      // MIC at gain 0.5 and track GUITAR at 1.26 — the signal_style mapping
      // with the true minus.
      expect(find.text('−6.0 dB'), findsOneWidget);
      expect(find.text('+2.0 dB'), findsOneWidget);
      expect(signalGainReadout(0.5), '−6.0 dB');
    });

    testWidgets('the BACK TO STAGE chip dismisses to the readout', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('volume_overlay_back_to_stage')));
      await tester.pump();
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
    });

    testWidgets('a dead-space tap dismisses to the readout', (tester) async {
      await pump(tester);
      await open(tester);

      // The bottom-left corner: inside the panel's inset, on no row.
      await tester.tapAt(const Offset(5, 595));
      await tester.pump();
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
    });

    testWidgets('8 s of inactivity reverts the list to the readout', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
    });

    testWidgets('interaction resets the inactivity timer', (tester) async {
      await pump(tester);
      await open(tester);

      await tester.pump(const Duration(seconds: 6));
      await tester.tap(find.byKey(const Key('volume_row_track_0')));
      await tester.pump(const Duration(seconds: 6));
      // 12 s since opening, but only 6 since the last touch.
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
    });

    testWidgets('the auto-revert chain steps panel → list → readout', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('volume_row_config_track_0')));
      await tester.pump();
      expect(
        find.byKey(const Key('volume_overlay_track_config')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 9));
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
    });

    testWidgets('the chevron zone opens the input config panel', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('volume_row_config_input_1')));
      await tester.pump();

      expect(
        find.byKey(const Key('volume_overlay_input_config')),
        findsOneWidget,
      );
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('MIC'), findsOneWidget);
      expect(find.text('VOLUME'), findsOneWidget);
      // Read-only listening pills.
      expect(find.text('LISTENING TRACKS'), findsOneWidget);
      expect(find.text('VOX'), findsOneWidget);
      expect(find.text('TRACK 7'), findsOneWidget);
      // The #697 conditioning stage is not wired yet: hidden behind
      // [kReadoutInputConditioning], not drawn dead.
      expect(kReadoutInputConditioning, isFalse);
      expect(find.text('CONDITIONING'), findsNothing);
      expect(find.text('HPF'), findsNothing);

      await tester.tap(find.byKey(const Key('volume_overlay_back')));
      await tester.pump();
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);
    });

    testWidgets('the track config panel shows MUTE, FX CHAIN and the source', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('volume_row_config_track_0')));
      await tester.pump();

      expect(
        find.byKey(const Key('volume_overlay_track_config')),
        findsOneWidget,
      );
      expect(find.text('TRACK'), findsOneWidget);
      expect(find.text('MUTE'), findsOneWidget);
      expect(find.text('FX CHAIN'), findsOneWidget);
      // The read-only input-source pill under its caption.
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('GUITAR'), findsNWidgets(2)); // title + pill

      await tester.tap(find.byKey(const Key('volume_config_mute')));
      expect(controls, hasLength(1));
      expect(controls.last.action, ReadoutControl.trackMuteToggle);
      expect(controls.last.index, 0);

      await tester.tap(find.byKey(const Key('volume_config_fx_chain')));
      expect(controls, hasLength(2));
      expect(controls.last.action, ReadoutControl.trackChainToggle);
      expect(controls.last.index, 0);
    });

    testWidgets('a dead-space tap on a config panel steps back to the list', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);
      await tester.tap(find.byKey(const Key('volume_row_config_track_1')));
      await tester.pump();

      await tester.tapAt(const Offset(5, 595));
      await tester.pump();
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);
    });

    testWidgets('tapping a track row places the fader and sends the volume', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('volume_row_track_0')));
      await tester.pump();

      expect(controls, hasLength(1));
      final sent = controls.single;
      expect(sent.action, ReadoutControl.trackVolume);
      expect(sent.index, 0);
      expect(sent.value, inInclusiveRange(0, kSignalMaxGain));
      // Immediate local feedback: the row already draws the value it sent,
      // before any fresh snapshot arrives from the main window.
      expect(find.text(signalGainReadout(sent.value)), findsWidgets);
    });

    testWidgets('an input row addresses its command by engine input index', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      await tester.tap(find.byKey(const Key('volume_row_input_1')));
      await tester.pump();

      expect(controls, hasLength(1));
      expect(controls.single.action, ReadoutControl.inputVolume);
      expect(controls.single.index, 1);
    });

    testWidgets('drags send continuously but throttled, last value landing', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      final row = tester.getCenter(find.byKey(const Key('volume_row_track_0')));
      final gesture = await tester.startGesture(row);
      // Five updates inside one send window: the first opens the window and
      // sends immediately, the rest coalesce into the trailing flush.
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump();
      }
      await gesture.up();
      expect(controls, hasLength(1));

      // The trailing flush lands the LAST value once the gap elapses —
      // a live mixer commits continuously, but at ~30 Hz, not per event.
      await tester.pump(ConsoleVolumeOverlay.sendGap * 2);
      expect(controls, hasLength(2));
      expect(controls.last.value, greaterThan(controls.first.value));
      expect(controls.last.action, ReadoutControl.trackVolume);
    });

    testWidgets('the config panel fader drags its subject volume', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);
      await tester.tap(find.byKey(const Key('volume_row_config_input_1')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('volume_config_fader')));
      await tester.pump();
      expect(controls, hasLength(1));
      expect(controls.single.action, ReadoutControl.inputVolume);
      expect(controls.single.index, 1);
    });

    testWidgets('a config page whose subject vanished falls back to the list', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);
      await tester.tap(find.byKey(const Key('volume_row_config_input_1')));
      await tester.pump();
      expect(
        find.byKey(const Key('volume_overlay_input_config')),
        findsOneWidget,
      );

      // The device changed: the monitored input is gone from the snapshot.
      // Pumping the same tree shape keeps the overlay's State, so this is a
      // widget update, not a fresh mount.
      await pump(tester, PerformanceReadout(tracks: readout.tracks));
      await tester.pump();
      expect(
        find.byKey(const Key('volume_overlay_input_config')),
        findsNothing,
      );
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);

      // The transition is REAL state, not a drawing fallback: one dead-space
      // tap dismisses to the readout (list behaviour), and does not need the
      // panel's extra step.
      await tester.tapAt(const Offset(5, 595));
      await tester.pump();
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
    });

    testWidgets('the name and value columns are inert — no fader jump, no '
        'fall-through dismissal', (tester) async {
      await pump(tester);
      await open(tester);

      // A tap on the NAME must not commit volume 0 (the drag surface is the
      // capsule only — owner-directed deviation from the drawn whole-row
      // contract, for performance safety)...
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('volume_row_track_1')),
          matching: find.text('BOOM'),
        ),
      );
      await tester.pump();
      // ...and a tap on the dB VALUE must not commit max.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('volume_row_track_0')),
          matching: find.text('+2.0 dB'),
        ),
      );
      await tester.pump();

      expect(controls, isEmpty);
      // Nor may the label taps fall through to the dead-space dismissal.
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);
    });

    testWidgets('a motionless held finger never triggers the revert', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('volume_row_track_0'))),
      );
      // Well past the 8 s window with the finger resting: the revert must
      // not unmount the row under the active gesture.
      await tester.pump(const Duration(seconds: 20));
      expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);

      // Release re-arms the timer; only then does inactivity revert.
      await gesture.up();
      await tester.pump(const Duration(seconds: 9));
      expect(find.byKey(const Key('readout_face')), findsOneWidget);
    });

    testWidgets('unmounting inside the send gap flushes the queued value', (
      tester,
    ) async {
      await pump(tester);
      await open(tester);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('volume_row_track_0'))),
      );
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.up();
      expect(controls, hasLength(1));

      // Window close / hot restart within 33 ms of the last movement: the
      // drag's final position must not die with the trailing timer.
      await tester.pumpWidget(const SizedBox.shrink());
      expect(controls, hasLength(2));
      expect(controls.last.value, greaterThan(controls.first.value));
    });

    testWidgets(
      'a conflicting snapshot cannot snap the fader back inside the hold; '
      'the pushed truth wins after it',
      (tester) async {
        await pump(tester);
        await open(tester);

        await tester.tap(find.byKey(const Key('volume_row_track_0')));
        await tester.pump();
        final sent = controls.single.value;
        final sentText = signalGainReadout(sent);
        expect(find.text(sentText), findsOneWidget);

        // The main window pushes a snapshot still carrying the OLD volume
        // (the command's echo has not landed yet). The fader must hold the
        // local value — a snap-back mid-adjustment reads as a broken fader.
        await pump(
          tester,
          PerformanceReadout(
            tracks: readout.tracks,
            inputs: readout.inputs,
            tempoBpm: 99,
          ),
        );
        await tester.pump();
        expect(find.text(sentText), findsOneWidget);
        expect(find.text('+2.0 dB'), findsNothing);

        // Past localHold (wall clock — the prune stamps with DateTime.now),
        // the next snapshot's word is final: a dropped command must not lie
        // forever.
        await tester.runAsync(
          () => Future<void>.delayed(
            ConsoleVolumeOverlay.localHold + const Duration(milliseconds: 100),
          ),
        );
        await pump(
          tester,
          PerformanceReadout(
            tracks: readout.tracks,
            inputs: readout.inputs,
            tempoBpm: 101,
          ),
        );
        await tester.pump();
        expect(find.text(sentText), findsNothing);
        expect(find.text('+2.0 dB'), findsOneWidget);
      },
    );
  });
}
