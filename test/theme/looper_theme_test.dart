import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/theme.dart';

void main() {
  group('peakMeterFill', () {
    test('returns 0 for non-positive peaks', () {
      expect(peakMeterFill(0), 0);
      expect(peakMeterFill(-0.5), 0);
    });

    test('maps full scale to 1 and is linear in dB over -60..0', () {
      expect(peakMeterFill(1), 1);
      // -6.02 dBFS sits at 90% of a -60..0 scale; -20 dBFS at 2/3.
      expect(peakMeterFill(0.5), closeTo(0.8997, 1e-3));
      expect(peakMeterFill(0.1), closeTo(2 / 3, 1e-9));
      // At and below the -60 dBFS floor there is no fill.
      expect(peakMeterFill(0.001), closeTo(0, 1e-9));
      expect(peakMeterFill(0.0001), 0);
    });

    test('clamps peaks above 1', () {
      expect(peakMeterFill(2), 1);
    });
  });

  group('LooperTheme', () {
    const theme = LooperTheme(
      tileBackground: Color(0xFF111111),
      tileBorder: Color(0xFF222222),
      waveformColors: {
        LooperMeterState.playing: Color(0xFF4CDA4A),
        LooperMeterState.recording: Color(0xFFFF1744),
      },
      waveformBackground: Color(0xFF000000),
      recordColor: Color(0xFFFF1744),
      recordMeterColors: {
        LooperMeterState.playing: Color(0xFF00FF00),
        LooperMeterState.muted: Color(0xFFFFFFFF),
      },
      muteMeterColors: {
        LooperMeterState.playing: Color(0xFF0000FF),
      },
      toolbarIconColor: Color(0xFFB0B3BC),
    );

    test('meterColor picks the table for the current mode', () {
      // Record mode uses recordMeterColors; mute mode uses muteMeterColors.
      expect(
        theme.meterColor(
          LooperMeterState.playing,
          mode: InteractionMode.record,
        ),
        const Color(0xFF00FF00),
      );
      expect(
        theme.meterColor(LooperMeterState.playing, mode: InteractionMode.mute),
        const Color(0xFF0000FF),
      );
      // A state the active table omits resolves to transparent.
      expect(
        theme.meterColor(
          LooperMeterState.stopped,
          mode: InteractionMode.record,
        ),
        Colors.transparent,
      );
      expect(
        theme.meterColor(LooperMeterState.muted, mode: InteractionMode.mute),
        Colors.transparent,
      );
      // FX mode shares the mute table — it is a mixing view, and the meters
      // mean exactly what they mean there.
      expect(
        theme.meterColor(LooperMeterState.playing, mode: InteractionMode.fx),
        theme.meterColor(LooperMeterState.playing, mode: InteractionMode.mute),
      );
    });

    test('waveformColor picks the color for the meter state', () {
      expect(
        theme.waveformColor(LooperMeterState.playing),
        const Color(0xFF4CDA4A),
      );
      expect(
        theme.waveformColor(LooperMeterState.recording),
        const Color(0xFFFF1744),
      );
      // A state the table omits resolves to transparent, matching the
      // meter/indicator tables rather than silently substituting an accent.
      expect(
        theme.waveformColor(LooperMeterState.muted),
        Colors.transparent,
      );
    });

    test('copyWith overrides only the given fields', () {
      final updated = theme.copyWith(recordColor: const Color(0xFFABCDEF));
      expect(updated.recordColor, const Color(0xFFABCDEF));
      expect(updated.waveformColors, theme.waveformColors);
      expect(updated.recordMeterColors, theme.recordMeterColors);
      expect(updated.muteMeterColors, theme.muteMeterColors);
    });

    test('lerp interpolates toward the other theme', () {
      final other = theme.copyWith(recordColor: const Color(0xFFFFFFFF));
      final mid = theme.lerp(other, 1);
      expect(mid.recordColor, const Color(0xFFFFFFFF));
    });

    test('lerp carries waveformColors toward the other theme', () {
      const white = Color(0xFFFFFFFF);
      final other = theme.copyWith(
        waveformColors: const {
          LooperMeterState.playing: white,
          LooperMeterState.recording: white,
        },
      );
      final end = theme.lerp(other, 1);
      expect(end.waveformColor(LooperMeterState.playing), white);
      expect(end.waveformColor(LooperMeterState.recording), white);
    });

    test('copyWith replaces waveformColors when given', () {
      final updated = theme.copyWith(
        waveformColors: const {LooperMeterState.muted: Color(0xFF010203)},
      );
      expect(
        updated.waveformColor(LooperMeterState.muted),
        const Color(0xFF010203),
      );
      // Replacing the table drops the entries it does not restate — the field
      // is one table, not a per-state merge.
      expect(
        updated.waveformColor(LooperMeterState.playing),
        Colors.transparent,
      );
    });

    test('lerp with a non-LooperTheme returns this', () {
      expect(theme.lerp(null, 0.5), same(theme));
    });
  });

  group('LooperMeterState.of', () {
    test('muted wins over the underlying track state', () {
      expect(
        LooperMeterState.of(TrackState.playing, muted: true),
        LooperMeterState.muted,
      );
      expect(
        LooperMeterState.of(TrackState.recording, muted: true),
        LooperMeterState.muted,
      );
    });

    test('maps each track state when not muted', () {
      expect(
        LooperMeterState.of(TrackState.empty, muted: false),
        LooperMeterState.empty,
      );
      expect(
        LooperMeterState.of(TrackState.recording, muted: false),
        LooperMeterState.recording,
      );
      expect(
        LooperMeterState.of(TrackState.overdubbing, muted: false),
        LooperMeterState.overdubbing,
      );
      expect(
        LooperMeterState.of(TrackState.playing, muted: false),
        LooperMeterState.playing,
      );
      expect(
        LooperMeterState.of(TrackState.stopped, muted: false),
        LooperMeterState.stopped,
      );
    });
  });

  test('AppTheme maps every meter state in both record and mute modes', () {
    final theme = AppTheme.neon.extension<LooperTheme>()!;
    for (final state in LooperMeterState.values) {
      expect(theme.recordMeterColors[state], isNotNull);
      expect(theme.muteMeterColors[state], isNotNull);
    }
    expect(AppTheme.neon.useMaterial3, isTrue);
  });

  test('both palettes map every waveform state', () {
    // Exit criterion for #499 stage 3b: no state may fall back to the
    // accessor's transparent default, in either variant — a waveform that
    // vanishes in one transport state is worse than the single cyan it
    // replaced.
    for (final data in [AppTheme.neon, AppTheme.highContrast]) {
      final theme = data.extension<LooperTheme>()!;
      for (final state in LooperMeterState.values) {
        expect(
          theme.waveformColors[state],
          isNotNull,
          reason: 'waveform state $state is unmapped',
        );
        expect(theme.waveformColor(state), isNot(Colors.transparent));
      }
    }
  });

  test('the waveform speaks the same legend as the meters', () {
    // The point of the change: the waveform is not its own accent, it repeats
    // the stage colours the meters already use. Assert the relationship rather
    // than the hexes, so a palette migration flows through untouched.
    for (final data in [AppTheme.neon, AppTheme.highContrast]) {
      final theme = data.extension<LooperTheme>()!;
      // The signal-bearing states come straight from the meter table. The
      // quiet ones deliberately do not: the meter paints stopped and muted the
      // same plain white and hides `empty` in a dim groove, while the waveform
      // dims that trio apart by alpha (see below).
      for (final state in [
        LooperMeterState.recording,
        LooperMeterState.overdubbing,
        LooperMeterState.playing,
      ]) {
        expect(
          theme.waveformColor(state),
          theme.meterColor(state, mode: InteractionMode.mute),
          reason: '$state must reuse the meter colour, not a waveform-only one',
        );
      }
      // Recording and playing must not collapse into one another, or the
      // legend says nothing.
      expect(
        theme.waveformColor(LooperMeterState.recording),
        isNot(theme.waveformColor(LooperMeterState.playing)),
      );
      // An empty cursor track reads exactly as a stopped one: both mean "not
      // playing", which is the only thing this surface can honestly say about
      // a track while it draws the whole mix. It must NOT borrow the meter's
      // dim empty groove — that would black out the mix whenever the cursor
      // sits on a fresh track.
      expect(
        theme.waveformColor(LooperMeterState.empty),
        theme.waveformColor(LooperMeterState.stopped),
      );
      expect(
        theme.waveformColor(LooperMeterState.empty),
        isNot(
          theme.meterColor(LooperMeterState.empty, mode: InteractionMode.mute),
        ),
      );
    }
  });
}
