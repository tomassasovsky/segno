import 'package:flutter/material.dart';
import 'package:settings_repository/settings_repository.dart';

/// The dimmest a panel can be SET to (`0..1`): 20%, the accepted range's
/// floor. The settings store holds the same number.
const double kMinDisplayBrightness = SettingsRepository.minDisplayBrightness;

/// Where a panel's brightness starts, and what a double tap on its slider
/// puts it back to: 80%.
const double kDefaultDisplayBrightness =
    SettingsRepository.defaultDisplayBrightness;

/// What dimming while idle leaves of a panel's set brightness: 30%.
const double kIdleDimFactor = 0.3;

/// The dimmest a panel ever SHOWS (`0..1`): 10%, the idle dim's floor.
///
/// Software dim multiplies RGB, and `0` is a black screen nobody could find a
/// control on to recover. Keep a visible minimum.
const double kMinShownBrightness = 0.1;

/// Clamps a set [brightness] into `[kMinDisplayBrightness, 1.0]`.
double clampDisplayBrightness(double brightness) =>
    brightness.clamp(kMinDisplayBrightness, 1.0);

/// What a panel set to [brightness] shows: the setting itself, or, while
/// [dimmed], [kIdleDimFactor] of it with a [kMinShownBrightness] floor.
double shownBrightness(double brightness, {required bool dimmed}) => dimmed
    ? (brightness * kIdleDimFactor).clamp(kMinShownBrightness, 1.0)
    : brightness;

/// Multiplies RGB by [brightness] (`kMinShownBrightness..1`). Identity at
/// `1.0`.
ColorFilter softwareBrightnessFilter(double brightness) {
  final b = brightness.clamp(kMinShownBrightness, 1.0);
  return ColorFilter.matrix(<double>[
    b,
    0,
    0,
    0,
    0,
    0,
    b,
    0,
    0,
    0,
    0,
    0,
    b,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}

/// Applies [softwareBrightnessFilter] when [brightness] is below full.
///
/// The filter comes and goes as the level crosses full (a panel set to 100%
/// that idle-dims, then wakes), and [child] keeps its state through it: it is
/// reparented under a global key rather than rebuilt, so the app below (the
/// navigator and every open page) is never remounted by a brightness change.
class SoftwareBrightness extends StatefulWidget {
  /// Creates a [SoftwareBrightness] wrapper.
  const SoftwareBrightness({
    required this.brightness,
    required this.child,
    super.key,
  });

  /// Dim level in `kMinShownBrightness..1` (`1` = no filter).
  final double brightness;

  /// Subtree to dim.
  final Widget child;

  @override
  State<SoftwareBrightness> createState() => _SoftwareBrightnessState();
}

class _SoftwareBrightnessState extends State<SoftwareBrightness> {
  final GlobalKey _child = GlobalKey(debugLabel: 'SoftwareBrightness');

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _child, child: widget.child);
    if (widget.brightness >= 1.0) return child;
    return ColorFiltered(
      colorFilter: softwareBrightnessFilter(widget.brightness),
      child: child,
    );
  }
}
