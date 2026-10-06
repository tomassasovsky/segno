import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/audio_setup/cubit/audio_setup_cubit.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';

/// How long one track's loop may grow: memory the engine reserves per track
/// when the device opens, so it lives with the device rather than with the
/// loop settings, and changing it reopens the device.
///
/// A row that opens in place onto a chip grid of the offered caps.
class MaxLoopLengthCard extends StatefulWidget {
  /// Creates a [MaxLoopLengthCard].
  const MaxLoopLengthCard({super.key});

  @override
  State<MaxLoopLengthCard> createState() => _MaxLoopLengthCardState();
}

class _MaxLoopLengthCardState extends State<MaxLoopLengthCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final audio = context.watch<AudioSetupCubit>();
    final cap = audio.state.maxLoopMinutes;
    return ConsoleCard(
      children: [
        ConsoleRow(
          key: const Key('audio_max_loop_row'),
          title: l10n.audioMaxLoopTitle,
          subtitle: l10n.audioMaxLoopSubtitle,
          value: _capLabel(l10n, cap),
          expanded: _open,
          fill: _open ? surface.control : null,
          showDivider: false,
          onTap: () => setState(() => _open = !_open),
        ),
        ConsoleChooser.grid(
          key: const Key('audio_max_loop_chooser'),
          open: _open,
          // A grid, not a row list: every option is a bare token, and a
          // token has nothing to put in a row's width.
          grid: ConsoleChipGrid<int>(
            selected: {cap},
            options: [
              for (final minutes in AudioSetupState.maxLoopMinuteOptions)
                ConsoleSegment(
                  value: minutes,
                  label: _capLabel(l10n, minutes),
                  optionKey: Key('audio_max_loop_$minutes'),
                ),
            ],
            onTap: (minutes) {
              audio.setMaxLoopMinutes(minutes);
              // A pick-one: the question is answered, so it shuts.
              setState(() => _open = false);
            },
          ),
        ),
      ],
    );
  }

  String _capLabel(AppLocalizations l10n, int minutes) =>
      minutes <= 0 ? l10n.maxLoopDefault30s : l10n.maxLoopMinutes(minutes);
}
