import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/looper/cubit/settings_tray_cubit.dart';
import 'package:segno/looper/view/tray/tray_brightness_slider.dart';

/// Brightness face: the screen's own control, and nothing else.
///
/// What is left of the `home` face this replaces. That face was a grid of
/// shortcuts beside this slider, and every shortcut on it outlived its
/// purpose: Signal became a rail domain (#533), then WiFi and Bluetooth
/// became the Network domain (#498), leaving Settings — a full-screen route
/// still reachable by key, right-click and the macOS menu bar, and whose six
/// sections are each a rail domain now. A rail entry called "Controls"
/// leading to two shortcuts and a slider is what the pen's rail does not
/// have, and this is what it has instead.
class TrayBrightness extends StatelessWidget {
  /// Creates a [TrayBrightness].
  const TrayBrightness({super.key});

  /// Width of the slider column. The same 72 it had beside the grid — a
  /// console control aimed at with a thumb, not a desktop scrollbar.
  static const double _width = 72;

  /// How tall it is allowed to get. Unbounded, the slider would stretch to
  /// the whole pane and read as a wall rather than a control.
  static const double _maxHeight = 280;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SettingsTrayCubit>().state;
    final cubit = context.read<SettingsTrayCubit>();
    return Center(
      child: SizedBox(
        width: _width,
        height: _maxHeight,
        child: TrayBrightnessSlider(
          value: state.brightness,
          onChanged: (value) => unawaited(cubit.setBrightness(value)),
        ),
      ),
    );
  }
}
