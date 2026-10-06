import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

/// Stable toast ids used by the app shell (and widget tests).
///
/// The lost-*device* id is gone on purpose (#453): a lost audio interface is a
/// standing CONDITION — the engine stops, nothing is heard — surfaced by the
/// persistent `ConnectivityBanners` on the stage, not a toast. A lost *MIDI*
/// controller is the opposite: the loops keep playing, so it is a low-stakes
/// event that flashes a transient toast ([midiLost]) and leaves no standing
/// bar. Both hardware returns are *restored* events, each a short snack.
abstract final class AppToastId {
  static const clickModeSettings = 'app_clickModeSettings_banner';
  static const recordStartSettings = 'app_recordStartSettings_banner';
  static const recordingInputRequired = 'app_recordingInputRequired_toast';
  static const recordRefused = 'app_recordRefused_toast';
  static const deviceRestored = 'app_deviceRestored_snackbar';
  static const deviceRestoredPartial = 'app_deviceRestoredPartial_toast';
  static const midiLost = 'app_midiLost_toast';
  static const midiRestored = 'app_midiRestored_snackbar';
  static const sessionBootRecovery = 'app_sessionBootRecovery_error';
  static const monitorRestore = 'app_monitorRestore_error';
  static const audioRecovery = 'app_audioRecovery_banner';
  static const update = 'app_update_banner';
  static const updateDismiss = 'app_update_banner_dismiss';
  static const updateAction = 'app_update_banner_update';
  static const waveformFailed = 'app_waveformWindowFailed_banner';
  static const singleDisplay = 'app_singleDisplay_banner';
  static const bluetoothRetired = 'app_bluetoothRetired_toast';
  static const recoveryRefused = 'app_recoveryRefused_toast';
  static const undoClearAll = 'app_undoClearAll_snackbar';
  static const undoClearAllAction = 'app_undoClearAll_snackbar_action';
  static const footMixerFailure = 'app_footMixerFailure_error';
  static const footFadeFailure = 'app_footFadeFailure_error';
  static const footReverseFailure = 'app_footReverseFailure_error';
  static const mixSettings = 'app_mixSettings_error';
  static const clickSettings = 'app_clickSettings_error';
  static const decaySettings = 'app_decaySettings_error';
  static const oneShotSettings = 'app_oneShotSettings_error';
  static const recordLengthSettings = 'app_recordLengthSettings_error';
  static const recordTimingSettings = 'app_recordTimingSettings_error';

  /// Persistent Fade duration storage recovery.
  static const fadeSettings = 'app_fadeSettings_error';
}

final Map<String, ToastificationItem> _active = {};

/// Dismisses a previously shown app toast, if any.
/// Forgets every live toast without animating them out.
///
/// The registry below is module-level, so it survives between widget tests:
/// one test showing a toast makes the next test's identical toast a duplicate
/// and silently a no-op. Reset it in `setUp`.
///
/// This clears only *this module's* id→item map. The `toastification` package
/// keeps its OWN process-global singleton (`toastification.managers`) that also
/// leaks across tests under `very_good test --optimization`; wiping that is the
/// job of `resetToastificationForTest` in `test/helpers/toast_test_helpers.dart`
/// (it pokes a package member the analyzer only permits from test code). Toast
/// tests call BOTH in `setUp`.
@visibleForTesting
void resetAppToastsForTest() => _active.clear();

/// Whether a toast with [id] is currently registered.
///
/// The test seam for toast assertions: toastification renders into an overlay
/// the widget-test harness does not reliably provide, so "the snack showed"
/// is asserted against this registry rather than against widget keys.
@visibleForTesting
bool debugAppToastActive(String id) => _active.containsKey(id);

void dismissAppToast(String id, {bool animate = true}) {
  final item = _active.remove(id);
  if (item != null) {
    toastification.dismiss(item, showRemoveAnimation: animate);
  }
}

/// Shows a persistent (manual-dismiss) toast with optional trailing actions.
ToastificationItem showAppToast({
  required String id,
  required Widget title,
  Widget? description,
  Widget? icon,
  ToastificationType type = ToastificationType.info,
  List<Widget> actions = const [],
  Duration? autoCloseDuration,
  bool dismissible = true,
}) {
  dismissAppToast(id);
  final item = toastification.showCustom(
    alignment: Alignment.topCenter,
    autoCloseDuration: autoCloseDuration,
    builder: (context, holder) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      return KeyedSubtree(
        key: Key(id),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                IconTheme(
                  data: IconThemeData(color: _accent(type, scheme), size: 22),
                  child: icon,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: DefaultTextStyle(
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: scheme.onSurface,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        child: title,
                      ),
                      if (description != null) ...[
                        const SizedBox(height: 2),
                        DefaultTextStyle.merge(
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w400,
                          ),
                          child: description,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              ...actions.map(
                (action) => Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: action,
                ),
              ),
              if (dismissible)
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () {
                    dismissAppToast(id);
                    toastification.dismiss(holder);
                  },
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
            ],
          ),
        ),
      );
    },
  );
  _active[id] = item;
  return item;
}

/// Short-lived status toast (e.g. "reconnected").
void showAppSnackToast({
  required String id,
  required Widget title,
  Widget? icon,
  ToastificationType type = ToastificationType.success,
  Duration autoCloseDuration = const Duration(seconds: 3),
}) {
  showAppToast(
    id: id,
    title: title,
    icon: icon,
    type: type,
    autoCloseDuration: autoCloseDuration,
  );
}

Color _accent(ToastificationType type, ColorScheme scheme) {
  if (type == ToastificationType.success) return scheme.primary;
  if (type == ToastificationType.error) return scheme.error;
  if (type == ToastificationType.warning) return scheme.tertiary;
  return scheme.secondary;
}
