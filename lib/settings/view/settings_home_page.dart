import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/appliance/power_off/power_host.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/settings/settings_destination.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/appliance/appliance_env.dart';

/// Settings: the ten places it leads, each a tile with its Segno menu
/// picture, drawn as pen `05 Loop setup / 01 Settings` (`v7Ekz`) draws them.
///
/// The ten are direct destinations, not groups: a tile opens its page, and
/// that page's Back comes back here with the tile still focused.
class SettingsHomePage extends StatelessWidget {
  /// Creates a [SettingsHomePage].
  ///
  /// [powerAvailable] decides whether the title bar carries Power; it
  /// defaults to whether this is the console, the one place a power-off can
  /// actually halt anything.
  const SettingsHomePage({this.powerAvailable, super.key});

  /// Whether Power is shown; null asks the platform.
  final bool? powerAvailable;

  /// The tiles' left edges in the frame's main area: the pen's menu sits at
  /// x 100 and steps by a 325 px tile and a 24 px gap (rounded as the pen
  /// rounds them).
  static const List<double> columns = [100, 449, 798, 1146, 1495];

  /// The two rows' top edges in the frame's main area: the menu's y 120 plus
  /// each row's 152 and 420.
  static const List<double> rows = [272, 540];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final power = powerAvailable ?? isAppliance();
    return Scaffold(
      body: LoopSettingsFrame(
        crumb: l10n.loopSettingsCrumb,
        title: l10n.stageSettings,
        titleLeft: 100,
        onBack: () => Navigator.maybePop(context),
        onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
        actions: power
            ? LoopOutlinedButton(
                key: const Key('settings_power'),
                width: 64,
                borderColor: context.surface.menuPowerLine,
                icon: LucideIcons.power,
                semanticLabel: l10n.settingsPower,
                onTap: () => requestPower(context),
              )
            : null,
        children: [
          for (final destination in SettingsDestination.values)
            Positioned(
              left: columns[destination.index % columns.length],
              top: rows[destination.index ~/ columns.length],
              child: SettingsTile(
                destination: destination,
                autofocus: destination.index == 0,
              ),
            ),
        ],
      ),
    );
  }
}

/// One Settings destination: its picture over its name, on the art's own
/// ground.
class SettingsTile extends StatelessWidget {
  /// Creates a [SettingsTile] for [destination].
  const SettingsTile({
    required this.destination,
    this.autofocus = false,
    super.key,
  });

  /// Where the tile leads.
  final SettingsDestination destination;

  /// Whether the tile takes focus when the page opens.
  final bool autofocus;

  /// The tile's size, from the pen.
  static const Size size = Size(325, 244);

  /// The picture's size, from the pen.
  static const double artSize = 128;

  /// The picture's offset inside the tile.
  static const Offset artOffset = Offset(98, 32);

  /// The name's top inside the tile.
  static const double nameTop = 174;

  /// The tile's corner radius.
  static const double radius = 8;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final label = destination.label(context.l10n);
    // Decoded at the size it is drawn, not at the 480 px the art ships at.
    final artPixels = (artSize * MediaQuery.devicePixelRatioOf(context))
        .round();
    void open() => unawaited(destination.open());
    // Merged, so the focus stop, the tap and the name are one button.
    return MergeSemantics(
      key: Key('settings_tile_${destination.key}'),
      child: Semantics(
        button: true,
        label: label,
        // The Loop settings focus stop: the encoder's 3 px amber drawn inside
        // the tile, in front of it, as the pen's `e7kzxk` draws it.
        child: LoopFocusable(
          autofocus: autofocus,
          onActivate: open,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: open,
            child: Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: surface.menuArtGround,
                borderRadius: BorderRadius.circular(radius),
              ),
              // In front, as the pen strokes it inside the tile: a border in
              // the decoration would inset the picture and the name by its
              // width.
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: surface.menuArtLine),
              ),
              child: ExcludeSemantics(
                child: Stack(
                  children: [
                    Positioned(
                      left: artOffset.dx,
                      top: artOffset.dy,
                      width: artSize,
                      height: artSize,
                      child: Image.asset(
                        destination.artAsset,
                        key: Key('settings_tile_art_${destination.key}'),
                        fit: BoxFit.contain,
                        cacheWidth: artPixels,
                        cacheHeight: artPixels,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: nameTop,
                      child: AppText(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: surface.textPrimary,
                          fontSize: 32,
                          height: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
