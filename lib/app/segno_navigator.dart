import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/control/view/midi_controls/midi_controls_page.dart';
import 'package:segno/control/view/pedal_setup/external_pedal_page.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_page.dart';
import 'package:segno/library/view/library_page.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_page.dart';
import 'package:segno/looper/view/fx/fx_page.dart';
import 'package:segno/looper/view/fx/fx_pedal_assignments_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_hub.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_page.dart';
import 'package:segno/settings/settings.dart';
import 'package:segno/theme/page_transitions.dart';

/// The root navigator key, so settings can be opened from outside the widget
/// tree (e.g. the macOS system menu bar) as well as from in-app gestures.
final GlobalKey<NavigatorState> segnoNavigatorKey = GlobalKey<NavigatorState>();

/// Route name for the Settings page (the ten destinations).
const String segnoSettingsRouteName = 'segno/settings';

/// Route name for the Loop settings pages.
const String segnoLoopSettingsRouteName = 'segno/loop-settings';

/// Route name for the Audio routing pages.
const String segnoAudioRoutingRouteName = 'segno/audio-routing';

/// Route name for the Effects page.
const String segnoFxRouteName = 'segno/fx';

/// Route name for the FX page's pedal assignments.
const String segnoFxPedalAssignmentsRouteName = 'segno/fx/pedal-assignments';

/// Route name for the Pedals setup page.
const String segnoPedalSetupRouteName = 'segno/pedal-setup';

/// The route name of the External pedals subview.
const String segnoExternalPedalsRouteName = 'segno/external-pedals';

/// Route name for MIDI controls and Learn.
const String segnoMidiControlsRouteName = 'segno/midi-controls';

/// Route name for the Library.
const String segnoLibraryRouteName = 'segno/library';

/// Pushes the Library route onto the root navigator, once.
Future<void> openLibrary() => _pushOnce(
  segnoLibraryRouteName,
  () =>
      (_) => const LibraryPage(),
);

/// Route name for the Device settings page.
const String segnoDeviceSettingsRouteName = 'segno/settings/device';

/// Route name for the Network settings page.
const String segnoNetworkSettingsRouteName = 'segno/settings/network';

/// Route name for the Displays settings page.
const String segnoDisplaySettingsRouteName = 'segno/settings/displays';

/// Route name for the Storage settings page.
const String segnoStorageSettingsRouteName = 'segno/settings/storage';

/// Route name for the Updates settings page.
const String segnoUpdateSettingsRouteName = 'segno/settings/updates';

/// Route name for the About page, opened from Updates.
const String segnoAboutSettingsRouteName = 'segno/settings/about';

/// Route name for the Controller firmware page, opened from About.
const String segnoControllerFirmwareRouteName =
    'segno/settings/about/controller';

/// The names of the routes [_pushOnce] currently has on the stack.
final Set<String> _openRoutes = {};

Future<FxCatalogue>? _fxCatalogue;

/// The factory catalogue, loaded once and kept.
///
/// Read lazily on the first open rather than at startup: it is 6 MB of assets
/// that only the Effects surfaces want, and a rig that never opens them should
/// not pay for it on the way to the stage.
Future<FxCatalogue> segnoFxCatalogue() =>
    _fxCatalogue ??= const FxCatalogueLoader().load();

/// Replaces the loaded catalogue, for a test or a screenshot that supplies its
/// own instead of an asset bundle.
@visibleForTesting
void setSegnoFxCatalogueForTest(FxCatalogue? catalogue) =>
    _fxCatalogue = catalogue == null ? null : Future.value(catalogue);

/// Pushes the Effects route onto the root navigator, pointed at
/// [destination]; guarded against stacking duplicates like the routes below.
Future<void> openFx({FxDestination? destination, VoidCallback? onStage}) =>
    _pushOnce(segnoFxRouteName, () async {
      final catalogue = await segnoFxCatalogue();
      return (_) => FxPage(
        initial: destination,
        catalogue: catalogue,
        onStage: onStage,
      );
    });

/// Pushes the page [page] builds onto the root navigator under [name], once:
/// a second call while that route is on the stack does nothing, so rapid
/// triggers (a tap, a key and a menu item in one frame) cannot stack
/// duplicates. [page] may load what the page needs first; the guard is held
/// from the call, so a load in flight also counts as open.
Future<void> _pushOnce(
  String name,
  FutureOr<WidgetBuilder> Function() page,
) async {
  final navigator = segnoNavigatorKey.currentState;
  if (navigator == null || !_openRoutes.add(name)) return;
  try {
    final builder = await page();
    if (segnoNavigatorKey.currentState == null) return;
    await navigator.push(
      desktopPageRoute<void>(builder, settings: RouteSettings(name: name)),
    );
  } finally {
    _openRoutes.remove(name);
  }
}

/// Pushes the FX page's pedal assignments: which effect chain each footswitch
/// drives in FX mode, per bank.
Future<void> openFxPedalAssignments() => _pushOnce(
  segnoFxPedalAssignmentsRouteName,
  () =>
      (_) => const FxPedalAssignmentsPage(),
);

/// Pushes the Audio routing route (the accepted input and output setup
/// tasks) onto the root navigator, opened on [initial]; guarded against
/// stacking duplicates like [openLoopSettings].
Future<void> openAudioRouting({
  AudioRoutingTab initial = AudioRoutingTab.setup,
}) => _pushOnce(
  segnoAudioRoutingRouteName,
  () =>
      (_) => AudioRoutingPage(initial: initial),
);

/// Pushes the Pedals setup route (the accepted Layout A) onto the root
/// navigator; guarded against stacking duplicates like [openLoopSettings].
Future<void> openPedalSetup({VoidCallback? onStage}) => _pushOnce(
  segnoPedalSetupRouteName,
  () =>
      (_) => PedalSetupPage(onStage: onStage),
);

/// Pushes the External pedals subview on top of the Pedals route; guarded
/// against stacking duplicates like [openPedalSetup].
///
/// Its own route rather than a context of the Pedals screen: it has its own
/// draft and its own Save, and Back has to mean "leave this subview and
/// discard what it holds" rather than "leave Pedals".
Future<void> openExternalPedals() => _pushOnce(
  segnoExternalPedalsRouteName,
  () =>
      (_) => const ExternalPedalPage(),
);

/// Opens the shared MIDI assignment editor without stacking duplicate routes.
Future<void> openMidiControls({VoidCallback? onStage}) => _pushOnce(
  segnoMidiControlsRouteName,
  () =>
      (_) => MidiControlsPage(onStage: onStage),
);

/// Pushes the Loop settings route (the accepted hub and its submenus) onto
/// the root navigator, opened at [initial]; guarded against stacking
/// duplicates like [openSegnoSettings].
Future<void> openLoopSettings({
  LoopSettingsPageId initial = LoopSettingsPageId.hub,
  VoidCallback? onStage,
}) => _pushOnce(
  segnoLoopSettingsRouteName,
  () =>
      (_) => LoopSettingsPage(initial: initial, onStage: onStage),
);

/// Pushes the Device settings page: the audio interface, its rate, buffer and
/// latency, and what recording keeps in memory.
///
/// Where every "the audio stopped" notice leads, because it is the page whose
/// device chooser can start the engine again.
Future<void> openDeviceSettings() => _pushOnce(
  segnoDeviceSettingsRouteName,
  () =>
      (_) => const DeviceSettingsPage(),
);

/// Pushes the Network settings page.
Future<void> openNetworkSettings() => _pushOnce(
  segnoNetworkSettingsRouteName,
  () =>
      (_) => const NetworkSettingsPage(),
);

/// Pushes the Displays settings page.
Future<void> openDisplaySettings() => _pushOnce(
  segnoDisplaySettingsRouteName,
  () =>
      (_) => const DisplaysSettingsPage(),
);

/// Pushes the Storage settings page.
Future<void> openStorageSettings() => _pushOnce(
  segnoStorageSettingsRouteName,
  () =>
      (_) => const StorageSettingsPage(),
);

/// Pushes the Updates settings page, and drops the update toast: the page
/// shows the same offer with its own action.
Future<void> openUpdateSettings() {
  dismissAppToast(AppToastId.update);
  return _pushOnce(
    segnoUpdateSettingsRouteName,
    () =>
        (_) => const UpdatesSettingsPage(),
  );
}

/// Pushes the About page.
Future<void> openAboutSettings() => _pushOnce(
  segnoAboutSettingsRouteName,
  () =>
      (_) => const AboutSettingsPage(),
);

/// Pushes the Controller firmware page.
Future<void> openControllerFirmware() => _pushOnce(
  segnoControllerFirmwareRouteName,
  () =>
      (_) => const ControllerFirmwarePage(),
);

/// Shows the Updates page: back down to it when it is already under the
/// current page (About and Controller firmware are opened from it), pushed
/// otherwise.
///
/// Pushing a second Updates is what [openUpdateSettings] refuses, so a page
/// above it that leads to it has to go back instead.
Future<void> showUpdateSettings() async {
  final navigator = segnoNavigatorKey.currentState;
  if (navigator == null) return;
  if (isSegnoUpdatesSettingsOpen) {
    navigator.popUntil(ModalRoute.withName(segnoUpdateSettingsRouteName));
    return;
  }
  await openUpdateSettings();
}

/// Resets the open-route guard.
///
/// The guard is module-level and only released when a route pops, so a
/// widget test that leaves a route open wedges it for every later test in the
/// file: the open call then returns early and the page never appears.
@visibleForTesting
void resetSegnoNavigatorForTest() {
  _openRoutes.clear();
  _fxCatalogue = null;
}

/// Whether the Updates page is on screen (skip the update toast).
bool get isSegnoUpdatesSettingsOpen =>
    _openRoutes.contains(segnoUpdateSettingsRouteName);

/// Pushes the Settings page, the ten destinations, onto the root navigator,
/// guarding against stacking duplicates from rapid triggers (the header
/// icon, a key and a menu item in one frame).
Future<void> openSegnoSettings() => _pushOnce(
  segnoSettingsRouteName,
  () =>
      (_) => const SettingsHomePage(),
);
