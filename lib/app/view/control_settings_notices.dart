import 'package:flutter/material.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:toastification/toastification.dart';

/// Presentation details for a settings failure; the settings owner retains
/// the recovery operation and remains the authority on whether it is needed.
class ControlSettingsNotice {
  const ControlSettingsNotice({
    required this.id,
    required this.title,
    this.description,
    this.retry,
    this.needsRecovery,
  }) : assert(
         (retry == null) == (needsRecovery == null),
         'Recovery notices require both a retry action and availability.',
       );

  final String id;
  final WidgetBuilder title;
  final WidgetBuilder? description;
  final Future<bool> Function()? retry;
  final bool Function()? needsRecovery;
}

/// Gives shutdown exclusive notice space and restores unresolved recovery
/// actions when the player returns. Transient failures never hide a recovery.
class ControlSettingsNotices {
  final _recoveries = <String, ControlSettingsNotice>{};
  final _shown = <String>{};
  bool _powerVisible = false;
  bool _disposed = false;

  void show(ControlSettingsNotice notice) {
    if (_disposed) return;
    if (notice.retry != null) {
      _recoveries[notice.id] = notice;
    } else {
      final previous = _recoveries[notice.id];
      if (previous != null && previous.needsRecovery!()) return;
      _recoveries.remove(notice.id);
    }
    if (!_powerVisible) _present(notice);
  }

  /// Resolves a recovery completed outside its Retry action.
  void dismiss(String id) {
    if (_disposed) return;
    _recoveries.remove(id);
    _shown.remove(id);
    dismissAppToast(id);
  }

  void setPowerVisible({required bool visible}) {
    if (_disposed || _powerVisible == visible) return;
    _powerVisible = visible;
    if (visible) {
      _dismissShown();
      return;
    }
    for (final notice in _recoveries.values.toList()) {
      if (notice.needsRecovery!()) {
        _present(notice);
      } else {
        _recoveries.remove(notice.id);
      }
    }
  }

  void _present(ControlSettingsNotice notice) {
    _shown.add(notice.id);
    final retry = notice.retry;
    showAppToast(
      id: notice.id,
      type: ToastificationType.error,
      dismissible: retry == null,
      autoCloseDuration: retry == null ? const Duration(seconds: 5) : null,
      title: Builder(builder: notice.title),
      description: notice.description == null
          ? null
          : Builder(builder: notice.description!),
      actions: retry == null
          ? const []
          : [
              TextButton(
                onPressed: () async {
                  final recovered = await retry();
                  if (!_disposed &&
                      recovered &&
                      identical(_recoveries[notice.id], notice)) {
                    _recoveries.remove(notice.id);
                    _shown.remove(notice.id);
                    dismissAppToast(notice.id);
                  }
                },
                child: Builder(
                  builder: (context) => Text(context.l10n.powerRetry),
                ),
              ),
            ],
    );
  }

  void _dismissShown({bool animate = true}) {
    for (final id in _shown) {
      dismissAppToast(id, animate: animate);
    }
    _shown.clear();
  }

  void dispose() {
    _disposed = true;
    _dismissShown(animate: false);
    _recoveries.clear();
  }
}
