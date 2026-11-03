import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/appliance/display_brightness_cubit.dart';
import 'package:segno/appliance/display_role.dart';
import 'package:segno/notices/notices.dart';

/// The message that says the display setting [id] was not saved; a later
/// change of the same setting that does save takes it down.
Notice displaySaveFailedNotice(String id) => Notice(
  id: id,
  tone: NoticeTone.warning,
  title: (l10n) => l10n.displayBrightnessSaveFailed,
);

/// Applies [value] to [role]'s panel through the app-wide
/// [DisplayBrightnessCubit] for a brightness control under [context].
///
/// The level applies at once; saving it can fail, and that is said in the
/// top bar, cleared by the next change that does save.
void editDisplayBrightness(
  BuildContext context,
  DisplayRole role,
  double value,
) {
  final cubit = context.read<DisplayBrightnessCubit>();
  final notices = context.read<NoticesCubit>();
  unawaited(() async {
    try {
      await cubit.setBrightness(role, value);
      notices.clear(AppNoticeId.brightnessSave);
    } on Object {
      notices.show(displaySaveFailedNotice(AppNoticeId.brightnessSave));
    }
  }());
}
