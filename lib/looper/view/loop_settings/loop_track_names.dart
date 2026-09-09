import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';

/// The display names of the first [count] tracks, from the names the user
/// gave them (`TracksCubit`) with the numbered fallback for the rest.
List<String> trackDisplayNames(BuildContext context, int count) {
  final names = context.watch<TracksCubit>().state.names;
  final l10n = context.l10n;
  return [for (var i = 0; i < count; i++) l10n.trackName(names, i)];
}
