import 'package:flutter/material.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/control/view/pedal_setup/pedal_setup_page.dart';
import 'package:segno/looper/model/fx_destination.dart';
import 'package:segno/looper/view/audio_routing/audio_routing_page.dart';
import 'package:segno/looper/view/fx/fx_page.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_hub.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_page.dart';
import 'package:segno/looper/view/settings_page.dart';
import 'package:segno/theme/page_transitions.dart';

/// The root navigator key, so settings can be opened from outside the widget
/// tree (e.g. the macOS system menu bar) as well as from in-app gestures.
final GlobalKey<NavigatorState> segnoNavigatorKey = GlobalKey<NavigatorState>();

/// Route name for the settings page (used to avoid stacking duplicates).
const String segnoSettingsRouteName = 'segno/settings';

/// Route name for the Loop settings pages.
const String segnoLoopSettingsRouteName = 'segno/loop-settings';

/// Route name for the Audio routing pages.
const String segnoAudioRoutingRouteName = 'segno/audio-routing';

/// Route name for the Effects page.
const String segnoFxRouteName = 'segno/fx';

/// Route name for the Pedals setup page.
const String segnoPedalSetupRouteName = 'segno/pedal-setup';

bool _loopSettingsOpen = false;
bool _audioRoutingOpen = false;
bool _fxOpen = false;
bool _pedalSetupOpen = false;
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
Future<void> openFx({FxDestination? destination}) async {
  final navigator = segnoNavigatorKey.currentState;
  if (navigator == null || _fxOpen) return;
  _fxOpen = true;
  try {
    final catalogue = await segnoFxCatalogue();
    if (segnoNavigatorKey.currentState == null) return;
    await navigator.push(
      desktopPageRoute<void>(
        (_) => FxPage(initial: destination, catalogue: catalogue),
        settings: const RouteSettings(name: segnoFxRouteName),
      ),
    );
  } finally {
    _fxOpen = false;
  }
}

/// Pushes the Audio routing route (the accepted input and output setup
/// tasks) onto the root navigator, opened on [initial]; guarded against
/// stacking duplicates like [openLoopSettings].
Future<void> openAudioRouting({
  AudioRoutingTab initial = AudioRoutingTab.setup,
}) async {
  final navigator = segnoNavigatorKey.currentState;
  if (navigator == null || _audioRoutingOpen) return;
  _audioRoutingOpen = true;
  try {
    await navigator.push(
      desktopPageRoute<void>(
        (_) => AudioRoutingPage(initial: initial),
        settings: const RouteSettings(name: segnoAudioRoutingRouteName),
      ),
    );
  } finally {
    _audioRoutingOpen = false;
  }
}

/// Pushes the Pedals setup route (the accepted Layout A) onto the root
/// navigator; guarded against stacking duplicates like [openLoopSettings].
Future<void> openPedalSetup() async {
  final navigator = segnoNavigatorKey.currentState;
  if (navigator == null || _pedalSetupOpen) return;
  _pedalSetupOpen = true;
  try {
    await navigator.push(
      desktopPageRoute<void>(
        (_) => const PedalSetupPage(),
        settings: const RouteSettings(name: segnoPedalSetupRouteName),
      ),
    );
  } finally {
    _pedalSetupOpen = false;
  }
}

/// Pushes the Loop settings route (the accepted hub and its submenus) onto
/// the root navigator, opened at [initial]; guarded against stacking
/// duplicates like [openSegnoSettings].
Future<void> openLoopSettings({
  LoopSettingsPageId initial = LoopSettingsPageId.hub,
}) async {
  final navigator = segnoNavigatorKey.currentState;
  if (navigator == null || _loopSettingsOpen) return;
  _loopSettingsOpen = true;
  try {
    await navigator.push(
      desktopPageRoute<void>(
        (_) => LoopSettingsPage(initial: initial),
        settings: const RouteSettings(name: segnoLoopSettingsRouteName),
      ),
    );
  } finally {
    _loopSettingsOpen = false;
  }
}

bool _settingsOpen = false;

/// Clears the "settings already open" guard.
///
/// The guard is module-level and only released when the route pops, so a
/// widget test that leaves settings open wedges it for every later test in the
/// file — `openSegnoSettings` then returns early and the page never appears.
@visibleForTesting
void resetSegnoNavigatorForTest() {
  _settingsOpen = false;
  _openSettingsSection = null;
  _loopSettingsOpen = false;
  _audioRoutingOpen = false;
  _fxOpen = false;
  _pedalSetupOpen = false;
  _fxCatalogue = null;
}

SettingsSection? _openSettingsSection;

/// Whether Settings is open on the Updates tab (skip the update toast).
bool get isSegnoUpdatesSettingsOpen =>
    _settingsOpen && _openSettingsSection == SettingsSection.updates;

void _onSettingsSectionChanged(SettingsSection section) {
  _openSettingsSection = section;
  if (section == SettingsSection.updates) {
    dismissAppToast(AppToastId.update);
  }
}

/// Pushes the [SettingsPage] onto the root navigator, guarding
/// against stacking duplicates from rapid triggers (menu + key + right-click).
///
/// [section] selects which left-rail tab is shown first (defaults to View).
Future<void> openSegnoSettings({
  SettingsSection section = SettingsSection.view,
}) async {
  final navigator = segnoNavigatorKey.currentState;
  if (navigator == null || _settingsOpen) return;
  _settingsOpen = true;
  _openSettingsSection = section;
  if (section == SettingsSection.updates) {
    dismissAppToast(AppToastId.update);
  }
  try {
    await navigator.push(
      desktopPageRoute<void>(
        (_) => SettingsPage(
          initialSection: section,
          onSectionChanged: _onSettingsSectionChanged,
        ),
        settings: const RouteSettings(name: segnoSettingsRouteName),
      ),
    );
  } finally {
    _settingsOpen = false;
    _openSettingsSection = null;
  }
}
