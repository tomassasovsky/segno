import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/app_toasts.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/display_role.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:toastification/toastification.dart';

/// The toast that says a brightness change was not saved.
const String displayBrightnessSaveFailedToast =
    'display_brightness_save_failed';

/// Applies [value] to [role]'s panel through the app-wide
/// [DisplayBrightnessCubit] for a brightness control under [context].
///
/// The level applies at once; saving it can fail, and that is said in a
/// toast on the app overlay (so it shows over any page), cleared by the next
/// change that does save.
void editDisplayBrightness(
  BuildContext context,
  DisplayRole role,
  double value,
) {
  final cubit = context.read<DisplayBrightnessCubit>();
  final l10n = context.l10n;
  unawaited(() async {
    try {
      await cubit.setBrightness(role, value);
      if (!context.mounted) return;
      dismissAppToast(displayBrightnessSaveFailedToast);
    } on Object {
      if (!context.mounted) return;
      showAppSnackToast(
        id: displayBrightnessSaveFailedToast,
        type: ToastificationType.error,
        icon: const Icon(Icons.error_outline),
        title: Text(l10n.powerOffSaveFailedTitle),
      );
    }
  }());
}
