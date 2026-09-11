import 'package:bloc/bloc.dart';
import 'package:brightness_client/brightness_client.dart';
import 'package:equatable/equatable.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/software_brightness.dart';
import 'package:segno/audio_setup/audio_tab.dart';
import 'package:segno/control/control_tab.dart';
import 'package:segno/network/network_tab.dart';
import 'package:segno/system/system_tab.dart';
import 'package:settings_repository/settings_repository.dart';

part 'settings_tray_state.dart';

/// Drives the console's slide-down quick-access tray (Settings / Signal
/// graph / WiFi / Bluetooth / Tuner / brightness) — the touch-reachable
/// counterpart to the `S`/`G` keyboard shortcuts on console/kiosk builds,
/// where the on-screen toolbar is hidden entirely.
///
/// Tray open/drag state is ephemeral. Brightness is persisted via
/// [SettingsRepository] (or [DisplayBrightnessCubit] when provided) and dimmed
/// in software app-wide; DDC/CI is applied when the host helper supports it.
class SettingsTrayCubit extends Cubit<SettingsTrayState> {
  /// Creates a [SettingsTrayCubit].
  SettingsTrayCubit({
    required SettingsRepository settings,
    BrightnessClient brightnessClient = const UnsupportedBrightnessClient(),
    DisplayBrightnessCubit? displayBrightness,
  }) : _settings = settings,
       _brightnessClient = brightnessClient,
       _displayBrightness = displayBrightness,
       super(const SettingsTrayState());

  final SettingsRepository _settings;
  final BrightnessClient _brightnessClient;
  final DisplayBrightnessCubit? _displayBrightness;
  Future<void>? _loadFuture;
  bool _brightnessSupported = false;

  /// Restores persisted brightness and probes whether the display helper
  /// can apply it.
  Future<void> load() => _loadFuture ??= _restore();

  Future<void> _restore() async {
    final display = _displayBrightness;
    if (display != null) {
      await display.load();
      if (isClosed) return;
      emit(state.copyWith(brightness: display.state));
      return;
    }
    final saved = clampDisplayBrightness(await _settings.loadBrightness());
    _brightnessSupported = await _brightnessClient.isSupported();
    if (isClosed) return;
    emit(state.copyWith(brightness: saved));
    if (_brightnessSupported) {
      try {
        await _brightnessClient.set(saved);
      } on Object {
        // Slider still works locally if apply fails.
      }
    }
  }

  /// Live drag progress, clamped to `0..1`. Called every
  /// `onVerticalDragUpdate` frame while the handle is being dragged.
  void dragTo(double progress) {
    emit(state.copyWith(dragProgress: progress.clamp(0.0, 1.0)));
  }

  /// Settles a released drag: past the 50% distance threshold snaps open,
  /// otherwise closed. Distance-only this round — no velocity/fling
  /// threshold.
  void settleFromDrag() {
    if (state.dragProgress > 0.5) {
      open();
    } else {
      closeTray();
    }
  }

  /// Opens the tray (tap-on-handle, or programmatic).
  void open() => emit(state.copyWith(dragProgress: 1));

  /// Closes the tray (handle activation, drag, or programmatic). Named
  /// `closeTray` rather than `close` — the latter is `Cubit.close()`, which
  /// disposes the bloc's stream; overriding it here would be a hard
  /// invalid-override error, not a UI action. Always returns to the landing
  /// destination so the next open isn't stuck in a config domain — but
  /// leaves every
  /// domain's own tab alone, so returning to a domain lands where it was
  /// left.
  void closeTray() => emit(
    state.copyWith(
      dragProgress: 0,
      destination: SettingsTrayDestination.control,
    ),
  );

  /// Toggles open/closed. Only ever called from a tap (never mid-drag), so
  /// `dragProgress` is always settled at exactly `0` or `1` here.
  void toggle() {
    if (state.dragProgress > 0) {
      closeTray();
    } else {
      open();
    }
  }

  /// Opens the tray at the Audio domain's Device tab — the device-lost
  /// banner's **Open setup** action (#453). The one caller that may set a
  /// domain's tab from outside it: the banner's whole point is the picker,
  /// and landing on whichever tab Audio was left on would bury it.
  void openAudioDevice() => emit(
    state.copyWith(
      dragProgress: 1,
      destination: SettingsTrayDestination.audio,
      audioTab: AudioTab.device,
    ),
  );

  /// Moves the Network domain's tab.
  ///
  /// Deliberately does NOT touch `destination`: the strip is only reachable
  /// while Network is already showing, so writing a destination here would
  /// give a tab a say in which domain is up.
  void showNetworkTab(NetworkTab tab) => emit(state.copyWith(networkTab: tab));

  /// Moves the Control domain's tab. Same rule as [showNetworkTab].
  void showControlTab(ControlTab tab) => emit(state.copyWith(controlTab: tab));

  /// Moves the Audio domain's tab. Same rule as [showNetworkTab].
  void showAudioTab(AudioTab tab) => emit(state.copyWith(audioTab: tab));

  /// Moves the System domain's tab. Same rule as [showNetworkTab].
  void showSystemTab(SystemTab tab) => emit(state.copyWith(systemTab: tab));

  /// Returns to the landing destination.
  ///
  /// Named for what it does, not for the face it reaches: the `home` tile grid
  /// is gone, and Control is the first face the rail has now that Effects is a
  /// route rather than a domain.
  void showLanding() =>
      emit(state.copyWith(destination: SettingsTrayDestination.control));

  /// Selects [destination] without changing whether the tray is open — the
  /// navigation rail's one entry point.
  ///
  /// Deliberately does NOT set `dragProgress`: the rail is only reachable
  /// while the tray is already open, and writing an open bit here would give
  /// the destination a second say in whether the tray is showing. Openness
  /// stays [SettingsTrayState.dragProgress]'s alone.
  void showDestination(SettingsTrayDestination destination) =>
      emit(state.copyWith(destination: destination));

  /// Sets brightness (`kMinDisplayBrightness..1`), persists it, and applies
  /// (software + optional DDC via [DisplayBrightnessCubit], or the legacy
  /// client path).
  Future<void> setBrightness(double value) async {
    final clamped = clampDisplayBrightness(value);
    emit(state.copyWith(brightness: clamped));
    final display = _displayBrightness;
    if (display != null) {
      await display.setBrightness(clamped);
      return;
    }
    await _settings.saveBrightness(clamped);
    if (_brightnessSupported) {
      try {
        await _brightnessClient.set(clamped);
      } on Object {
        // Keep UI/persistence even if the panel rejects the set.
      }
    }
  }
}
