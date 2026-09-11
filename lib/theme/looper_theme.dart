import 'dart:math' show ln10, log;

import 'package:flutter/material.dart';
import 'package:looper_repository/looper_repository.dart' show TrackState;
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/theme/surface_theme.dart';

/// The bottom of the shared meter scale, in dBFS: a peak at or below this
/// draws no fill.
const double kMeterFloorDb = -60;

/// Maps engine peak amplitude (`0..1`) to meter fill (`0..1`), linear in
/// decibels over [kMeterFloorDb]..0 dBFS.
///
/// dB-linear so the fill lines up with the shared dBFS scale drawn beside the
/// track columns (the accepted stage): a -18 dBFS peak sits 70% of the way
/// up, exactly where the scale says -18. Full scale maps to 100%; silence and
/// anything under the floor to 0.
double peakMeterFill(double peak) {
  if (peak <= 0) return 0;
  final db = 20 * log(peak.clamp(0.0, 1.0)) / ln10;
  return ((db - kMeterFloorDb) / -kMeterFloorDb).clamp(0.0, 1.0);
}

/// The distinct appearances a track meter (peak bar) can take: the track's
/// [TrackState] plus a `muted` case that overlays any state — collapsed into
/// one enum so the per-mode meter tables key off a single concept.
enum LooperMeterState {
  /// No audio recorded.
  empty,

  /// Capturing the first pass.
  recording,

  /// Summing input into the existing loop.
  overdubbing,

  /// Looping playback.
  playing,

  /// Playback halted; buffer retained.
  stopped,

  /// Muted (overlays any state).
  muted;

  /// The meter appearance for a track in [state] that may be [muted]. Muted
  /// wins over the underlying state.
  factory LooperMeterState.of(TrackState state, {required bool muted}) {
    if (muted) return LooperMeterState.muted;
    return switch (state) {
      TrackState.empty => LooperMeterState.empty,
      TrackState.recording => LooperMeterState.recording,
      TrackState.overdubbing => LooperMeterState.overdubbing,
      TrackState.playing => LooperMeterState.playing,
      TrackState.stopped => LooperMeterState.stopped,
    };
  }
}

/// Segno-specific design tokens layered on top of [ThemeData] via a
/// [ThemeExtension], so the looper grid and visualizer pick up per-mode colors
/// (per-track accents, waveform stroke, tile surfaces) without hard-coding them
/// in widgets.
@immutable
class LooperTheme extends ThemeExtension<LooperTheme> {
  /// Creates a [LooperTheme].
  const LooperTheme({
    required this.tileBackground,
    required this.tileBorder,
    required this.waveformColors,
    required this.waveformBackground,
    required this.recordColor,
    required this.recordMeterColors,
    required this.muteMeterColors,
    required this.toolbarIconColor,
  });

  /// Background of a track tile.
  final Color tileBackground;

  /// Border/divider color on a track tile.
  final Color tileBorder;

  /// Waveform stroke/fill colors by [LooperMeterState].
  ///
  /// The waveform is part of the same transport legend as the track meter and
  /// the pedal LEDs, so it keys off the same state vocabulary rather than
  /// carrying one fixed accent: the surface says what the track is *doing*, not
  /// merely that it is a waveform.
  final Map<LooperMeterState, Color> waveformColors;

  /// Background behind the waveform. A neutral that re-tints with the palette
  /// ramp — not part of the state legend above.
  final Color waveformBackground;

  /// The STAGE record red (DS `signal-rec`): the transport's beat-indicator
  /// dots and a track's pending-arm badge, the two surfaces that still read
  /// it.
  ///
  /// It no longer dresses the mode indicator, which this doc used to name:
  /// that chip and the stage status bar's pill both take the softer UI-chrome
  /// red from [SurfaceTheme.modePair] (#737, #768). The two reds are distinct
  /// by design — see [SurfaceTheme.rec].
  final Color recordColor;

  /// Track-meter (peak bar) colors by [LooperMeterState] in record mode.
  final Map<LooperMeterState, Color> recordMeterColors;

  /// Track-meter (peak bar) colors by [LooperMeterState] in mute mode.
  final Map<LooperMeterState, Color> muteMeterColors;

  /// Icon color for the toolbar's unarmed/neutral icon buttons (Play/Stop
  /// All, Clear All, Fullscreen, Signal, Settings, Session, and the
  /// unarmed performance-record button).
  final Color toolbarIconColor;

  /// The meter color for [state] in the current mode ([mode] selects the
  /// mute or record table). Transparent if the table omits it.
  ///
  /// FX and custom modes share the MUTE table: like mute mode they are
  /// mixing views (no track arms to record from either), and giving them
  /// palettes of their own would say something about the meters that neither
  /// mode changes.
  Color meterColor(LooperMeterState state, {required InteractionMode mode}) =>
      switch (mode) {
        InteractionMode.mute ||
        InteractionMode.fx ||
        InteractionMode.custom => muteMeterColors,
        InteractionMode.record => recordMeterColors,
      }[state] ??
      Colors.transparent;

  /// The waveform color for [state]. Transparent if the table omits it.
  ///
  /// Unlike the meters there is no per-mode split: the waveform draws the
  /// mixed output, and no interaction mode changes what that means.
  Color waveformColor(LooperMeterState state) =>
      waveformColors[state] ?? Colors.transparent;

  @override
  LooperTheme copyWith({
    Color? tileBackground,
    Color? tileBorder,
    Map<LooperMeterState, Color>? waveformColors,
    Color? waveformBackground,
    Color? recordColor,
    Map<LooperMeterState, Color>? recordMeterColors,
    Map<LooperMeterState, Color>? muteMeterColors,
    Color? toolbarIconColor,
  }) => LooperTheme(
    tileBackground: tileBackground ?? this.tileBackground,
    tileBorder: tileBorder ?? this.tileBorder,
    waveformColors: waveformColors ?? this.waveformColors,
    waveformBackground: waveformBackground ?? this.waveformBackground,
    recordColor: recordColor ?? this.recordColor,
    recordMeterColors: recordMeterColors ?? this.recordMeterColors,
    muteMeterColors: muteMeterColors ?? this.muteMeterColors,
    toolbarIconColor: toolbarIconColor ?? this.toolbarIconColor,
  );

  static Map<K, Color> _lerpColorMap<K>(
    Map<K, Color> a,
    Map<K, Color> b,
    double t,
  ) => {
    for (final entry in a.entries)
      entry.key: Color.lerp(entry.value, b[entry.key], t) ?? entry.value,
  };

  @override
  LooperTheme lerp(ThemeExtension<LooperTheme>? other, double t) {
    if (other is! LooperTheme) return this;
    return LooperTheme(
      tileBackground:
          Color.lerp(tileBackground, other.tileBackground, t) ?? tileBackground,
      tileBorder: Color.lerp(tileBorder, other.tileBorder, t) ?? tileBorder,
      waveformColors: _lerpColorMap(waveformColors, other.waveformColors, t),
      waveformBackground:
          Color.lerp(waveformBackground, other.waveformBackground, t) ??
          waveformBackground,
      recordColor: Color.lerp(recordColor, other.recordColor, t) ?? recordColor,
      recordMeterColors: _lerpColorMap(
        recordMeterColors,
        other.recordMeterColors,
        t,
      ),
      muteMeterColors: _lerpColorMap(
        muteMeterColors,
        other.muteMeterColors,
        t,
      ),
      toolbarIconColor:
          Color.lerp(toolbarIconColor, other.toolbarIconColor, t) ??
          toolbarIconColor,
    );
  }
}
