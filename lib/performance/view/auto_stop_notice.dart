import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/app_notices.dart';
import 'package:segno/appliance/idle_dim_cubit.dart';
import 'package:segno/notices/notices.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/performance/view/performance_completion_sheet.dart';

/// Tells the player, when they come back, that a capture stopped on its own
/// (#1767): nothing was played for the idle period, or it reached its
/// longest length. A capture stops this way when nobody is at the console,
/// so the passing warning waits for the player's next touch, key, encoder,
/// pedal or MIDI message ([IdleDimCubit.activities]) and is said then. The
/// capture dialog does not open for such a take (onPerformanceRecorderState),
/// so this is the one message. A new capture forgets it.
class PerformanceAutoStopNotice extends StatefulWidget {
  /// Creates a [PerformanceAutoStopNotice] around [child].
  const PerformanceAutoStopNotice({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  State<PerformanceAutoStopNotice> createState() =>
      _PerformanceAutoStopNoticeState();
}

class _PerformanceAutoStopNoticeState extends State<PerformanceAutoStopNotice> {
  StreamSubscription<void>? _back;

  @override
  void dispose() {
    unawaited(_back?.cancel());
    super.dispose();
  }

  void _sayWhenBack(PerformanceStopReason reason) {
    unawaited(_back?.cancel());
    final notices = context.read<NoticesCubit>();
    _back = context.read<IdleDimCubit>().activities.listen((_) {
      unawaited(_back?.cancel());
      _back = null;
      notices.show(
        Notice(
          id: AppNoticeId.performance,
          tone: NoticeTone.warning,
          title: (l10n) => perfAutoStopTitle(l10n, reason)!,
          body: (l10n) => l10n.perfStoppedKept,
          explains: true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      BlocListener<PerformanceRecorderCubit, PerformanceRecorderState>(
        listenWhen: (previous, current) =>
            previous.runtimeType != current.runtimeType,
        listener: (context, state) {
          switch (state) {
            case PerformanceRecorderCompleted(
                  result: PerformanceRecordStoppedEarly(:final reason),
                )
                when perfStoppedOnItsOwn(state.result):
              _sayWhenBack(reason);
            case PerformanceRecorderArmed():
              unawaited(_back?.cancel());
              _back = null;
            default:
              break;
          }
        },
        child: widget.child,
      );
}

/// Whether [result] is a take that stopped on its own (#1767).
bool perfStoppedOnItsOwn(PerformanceRecordResult? result) =>
    result is PerformanceRecordStoppedEarly &&
    (result.reason == PerformanceStopReason.idle ||
        result.reason == PerformanceStopReason.lengthLimit);
