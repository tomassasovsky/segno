import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/notices/cubit/notices_cubit.dart';

/// How every notice surface reads the notice centre (#1562).
extension SelectNotices on BuildContext {
  /// Selects from the [NoticesCubit]'s state, rebuilding when the selected
  /// value changes.
  ///
  /// A screen with no notice centre above it, a page pumped on its own in a
  /// test or a screenshot, reads the empty state and draws its top bar and
  /// cards at rest. The app provides one centre at its root, so on the
  /// console every surface reads that.
  T selectNotices<T>(T Function(NoticesState state) selector) =>
      select<NoticesCubit?, T>(
        (cubit) => selector(cubit?.state ?? const NoticesState()),
      );
}
