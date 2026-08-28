import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/visualizer/console_readout_view.dart';
import 'package:segno/visualizer/console_volume_overlay.dart';
import 'package:segno/visualizer/performance_readout.dart';
import 'package:segno/visualizer/performance_readout_view.dart';
import 'package:segno/visualizer/readout_control.dart';
import 'package:segno/visualizer/waveform_window.dart';
import 'package:segno/visualizer/waveform_window_args.dart';
import 'package:segno/window/window_chrome.dart';

void main() {
  group('waveformWindowPlacement', () {
    const args = WaveformWindowArgs(); // defaults: 120, 120, 960x320

    test('a single (primary-only) display → the windowed fallback', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (
            id: 'primary',
            position: Offset.zero,
            size: Size(1920, 1080),
            scale: 1,
          ),
        ],
        primaryId: 'primary',
        primaryScale: 1,
        args: args,
      );

      expect(placement.fullscreen, isFalse);
      expect(placement.position, const Offset(120, 120));
      expect(placement.size, const Size(960, 320));
    });

    test('a secondary display at the same DPI → full-bleed on it', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (
            id: 'primary',
            position: Offset.zero,
            size: Size(1920, 1080),
            scale: 1,
          ),
          (
            id: 'second',
            position: Offset(1920, 0),
            size: Size(2560, 1440),
            scale: 1,
          ),
        ],
        primaryId: 'primary',
        primaryScale: 1,
        args: args,
      );

      expect(placement.fullscreen, isTrue);
      expect(placement.position, const Offset(1920, 0));
      expect(placement.size, const Size(2560, 1440));
    });

    test('picks the first non-primary display when there are several', () {
      final placement = waveformWindowPlacement(
        screens: const [
          (id: 'a', position: Offset.zero, size: Size(1920, 1080), scale: 1),
          (id: 'b', position: Offset(1920, 0), size: Size(1280, 720), scale: 1),
          (id: 'c', position: Offset(3200, 0), size: Size(1280, 720), scale: 1),
        ],
        primaryId: 'b',
        primaryScale: 1,
        args: args,
      );

      // 'a' is the first that is not the primary ('b').
      expect(placement.fullscreen, isTrue);
      expect(placement.position, Offset.zero);
      expect(placement.size, const Size(1920, 1080));
    });

    test(
      'a higher-DPI secondary is rescaled into the primary window space',
      () {
        // A 4K (3840x2160) secondary at 175% sits physically to the right of a
        // 100% primary. `screen_retriever` reports it in *its own* logical
        // units (physical / 1.75): origin x=1463, size 2194x1234. The placement
        // must convert back to the primary window's space (physical, since the
        // primary is 100%): origin x=2560, size 3840x2160 — the true monitor
        // bounds. This is the multi-DPI case the plain pass-through got wrong.
        final placement = waveformWindowPlacement(
          screens: const [
            (
              id: 'primary',
              position: Offset.zero,
              size: Size(2560, 1440),
              scale: 1,
            ),
            (
              id: 'second',
              position: Offset(1463, 0),
              size: Size(2194, 1234),
              scale: 1.75,
            ),
          ],
          primaryId: 'primary',
          primaryScale: 1,
          args: args,
        );

        expect(placement.fullscreen, isTrue);
        expect(placement.position.dx, closeTo(2560, 1));
        expect(placement.position.dy, 0);
        expect(placement.size.width, closeTo(3840, 1));
        expect(placement.size.height, closeTo(2160, 1));
      },
    );

    test('rescales relative to the primary DPI, not absolutely', () {
      // Both displays at 150%: the secondary's own-logical bounds are already
      // in the primary's logical space, so `scale / primaryScale == 1` leaves
      // them untouched (no spurious 1.5x blow-up).
      final placement = waveformWindowPlacement(
        screens: const [
          (
            id: 'primary',
            position: Offset.zero,
            size: Size(1280, 720),
            scale: 1.5,
          ),
          (
            id: 'second',
            position: Offset(1280, 0),
            size: Size(1280, 720),
            scale: 1.5,
          ),
        ],
        primaryId: 'primary',
        primaryScale: 1.5,
        args: args,
      );

      expect(placement.fullscreen, isTrue);
      expect(placement.position, const Offset(1280, 0));
      expect(placement.size, const Size(1280, 720));
    });

    test('all-empty ids (Linux) → the windowed fallback, deliberately', () {
      // screen_retriever_linux hardcodes every display's id to "", so the
      // id-difference match can never fire on Linux — and it must not be
      // "fixed" by guessing from geometry. On the appliance weston's
      // kiosk-shell fullscreens the window and routes it to the output pinned
      // to its app-id (weston.ini `app-ids=`), overriding this placement
      // entirely; on a non-kiosk desktop GDK's "primary" is just monitor 0
      // (arbitrary under Wayland), so a geometry guess could full-bleed the
      // readout over the main display. Windowed is the safe answer both ways.
      final placement = waveformWindowPlacement(
        screens: const [
          (id: '', position: Offset.zero, size: Size(1920, 1080), scale: 1),
          (
            id: '',
            position: Offset(1920, 0),
            size: Size(1024, 600),
            scale: 1,
          ),
        ],
        primaryId: '',
        primaryScale: 1,
        args: args,
      );

      expect(placement.fullscreen, isFalse);
      expect(placement.position, const Offset(120, 120));
      expect(placement.size, const Size(960, 320));
    });
  });

  group('WaveformWindowApp', () {
    Future<void> pump(WidgetTester tester, {required bool consoleMode}) async {
      final frame = ValueNotifier<WaveformFrame>(
        (samples: Float32List(0), progress: 0, selectedTrack: ''),
      );
      final readout = ValueNotifier<PerformanceReadout>(
        const PerformanceReadout(tempoBpm: 120),
      );
      addTearDown(frame.dispose);
      addTearDown(readout.dispose);
      await tester.pumpWidget(
        WaveformWindowApp(
          frame: frame,
          readout: readout,
          title: 'Segno — Output',
          consoleMode: consoleMode,
        ),
      );
      // Unmount before the harness checks timers: the chrome shell arms
      // cursor/chrome idle timers its dispose cancels.
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    }

    testWidgets('the console build fills the panel with the pen readout', (
      tester,
    ) async {
      await pump(tester, consoleMode: true);
      expect(find.byType(ConsoleReadoutView), findsOneWidget);
      expect(find.byType(PerformanceReadoutView), findsNothing);
      // Full-bleed: the console view spans the shell, no windowed inset.
      final shell = tester.getSize(find.byType(SegnoWindowChromeShell));
      final view = tester.getSize(find.byType(ConsoleReadoutView));
      expect(view.width, shell.width);
    });

    testWidgets('the desktop build keeps the windowed readout view', (
      tester,
    ) async {
      await pump(tester, consoleMode: false);
      expect(find.byType(PerformanceReadoutView), findsOneWidget);
      expect(find.byType(ConsoleReadoutView), findsNothing);
      // No overlay on the desktop face: the volume overlay is console-only,
      // like the readout face it covers (#698).
      expect(find.byType(ConsoleVolumeOverlay), findsNothing);
    });

    testWidgets(
      'the MIX pill opens the volume overlay and its commands reach '
      'onControl',
      (tester) async {
        final frame = ValueNotifier<WaveformFrame>(
          (samples: Float32List(0), progress: 0, selectedTrack: ''),
        );
        final readout = ValueNotifier<PerformanceReadout>(
          const PerformanceReadout(
            tracks: [ReadoutTrack(name: 'GUITAR', state: 'playing')],
          ),
        );
        addTearDown(frame.dispose);
        addTearDown(readout.dispose);
        final controls = <ReadoutControl>[];
        await tester.pumpWidget(
          WaveformWindowApp(
            frame: frame,
            readout: readout,
            title: 'Segno — Output',
            onControl: controls.add,
          ),
        );
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

        // The MIX pill is the only way in (#707): a tap on the readout's
        // dead glass does nothing...
        await tester.tapAt(tester.getCenter(find.byType(ConsoleReadoutView)));
        await tester.pump();
        expect(find.byKey(const Key('volume_overlay_list')), findsNothing);
        expect(find.byType(ConsoleReadoutView), findsOneWidget);

        // ...the pill opens the overlay.
        await tester.tap(find.byKey(const Key('console_readout_mix')));
        await tester.pump();
        expect(find.byKey(const Key('volume_overlay_list')), findsOneWidget);

        // A row tap flows out through the window's control callback — the
        // seam the entrypoint wires to the channel.
        await tester.tap(find.byKey(const Key('volume_row_track_0')));
        expect(controls, hasLength(1));
        expect(controls.single.action, ReadoutControl.trackVolume);

        // Step home so the revert timer is cancelled before teardown.
        await tester.tap(find.byKey(const Key('volume_overlay_back_to_stage')));
        await tester.pump();
        expect(find.byType(ConsoleReadoutView), findsOneWidget);
      },
    );

    testWidgets('gives the readout a Material ancestor on both faces', (
      tester,
    ) async {
      // SegnoWindowChromeShell only mounts its own Scaffold on the Windows
      // title-bar path, so the sub-window must supply the Material ancestor
      // itself — without it the readout renders in the unthemed fallback
      // style (yellow double-underlined text), as seen live on the 7".
      await pump(tester, consoleMode: false);
      expect(
        find.ancestor(
          of: find.byType(PerformanceReadoutView),
          matching: find.byType(Material),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);

      await pump(tester, consoleMode: true);
      expect(
        find.ancestor(
          of: find.byType(ConsoleReadoutView),
          matching: find.byType(Material),
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
