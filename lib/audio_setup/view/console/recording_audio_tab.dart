import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/record_options_cubit.dart';
import 'package:segno/theme/theme.dart';

/// Whether the tab's openable row is showing its list.
enum _OpenRow {
  /// Nothing is open — the tab's resting state.
  none,

  /// The default loop length for new recordings.
  defaultLength,
}

/// The Recording tab: the length new recordings on other tracks default to,
/// as a multiple of the first loop.
///
/// One row that opens in place onto a **chip grid**: `Auto`, `×2` are bare
/// tokens, and a token has nothing to put in a row's width. How long a loop
/// may grow is the Device's (memory reserved when the device opens), and
/// what a record press does — Rec/Dub, Sound start and quantize — is Loop
/// settings'.
class RecordingAudioTab extends StatefulWidget {
  /// Creates a [RecordingAudioTab].
  const RecordingAudioTab({super.key});

  @override
  State<RecordingAudioTab> createState() => _RecordingAudioTabState();
}

class _RecordingAudioTabState extends State<RecordingAudioTab> {
  _OpenRow _open = _OpenRow.none;

  /// The fixed default-length multiples, beside `Auto`. Three, because a
  /// fourth is a length you set on the track itself.
  static const _multiples = [1, 2, 3];

  void _toggle(_OpenRow row) =>
      setState(() => _open = _open == row ? _OpenRow.none : row);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final options = context.watch<RecordOptionsCubit>().state.options;

    return KeyedSubtree(
      key: const Key('audio_recording_tab'),
      child: ConsoleFace(
        previewKey: const Key('audio_upcoming_group'),
        groups: [
          ConsoleGroup(
            caption: l10n.recordingGroupLabel,
            blocks: [
              ConsoleCard(
                children: [
                  ConsoleRow(
                    key: const Key('audio_default_length_row'),
                    title: l10n.audioDefaultLoopLengthTitle,
                    subtitle: l10n.audioDefaultLoopLengthSubtitle,
                    value: _lengthLabel(l10n, options.defaultMultiple),
                    expanded: _open == _OpenRow.defaultLength,
                    fill: _open == _OpenRow.defaultLength
                        ? surface.control
                        : null,
                    showDivider: false,
                    onTap: () => _toggle(_OpenRow.defaultLength),
                  ),
                  ConsoleChooser.grid(
                    key: const Key('audio_default_length_chooser'),
                    open: _open == _OpenRow.defaultLength,
                    grid: ConsoleChipGrid<int>(
                      selected: {options.defaultMultiple},
                      options: [
                        ConsoleSegment(
                          value: 0,
                          label: l10n.auto,
                          optionKey: const Key('audio_default_length_0'),
                        ),
                        for (final multiple in _multiples)
                          ConsoleSegment(
                            value: multiple,
                            label: l10n.loopMultipleLabel(multiple),
                            optionKey: Key('audio_default_length_$multiple'),
                          ),
                      ],
                      onTap: (multiple) {
                        unawaited(
                          context.read<RecordOptionsCubit>().setDefaultMultiple(
                            multiple,
                          ),
                        );
                        // A pick-one: the question is answered, so the drawer
                        // shuts. A bitmask grid would stay open.
                        setState(() => _open = _OpenRow.none);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _lengthLabel(AppLocalizations l10n, int multiple) =>
      multiple <= 0 ? l10n.auto : l10n.loopMultipleLabel(multiple);
}
