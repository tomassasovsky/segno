import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:segno/audio_setup/cubit/inputs_cubit.dart';
import 'package:segno/audio_setup/cubit/outputs_cubit.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

/// Which side of the rig is being named.
enum RoutingNames {
  /// The hardware inputs, one name per jack.
  inputs,

  /// The destinations, one name per stereo pair.
  outputs,
}

/// The pen's `Input names` / `Output names` list: what each port is called,
/// and a way to change it.
///
/// One page for both sides because they differ only in what a row is called
/// and who stores the name. The unit does differ — a jack on the way in, a
/// PAIR of jacks on the way out — and that is exactly what the port label
/// says.
class RoutingNamesList extends StatelessWidget {
  /// Creates a [RoutingNamesList].
  const RoutingNamesList({required this.side, super.key});

  /// Which side is being named.
  final RoutingNames side;

  /// The pen's row height, and the gap to the next one.
  static const double _rowStep = 120;

  Future<void> _rename(BuildContext context, int port, String current) async {
    final l10n = context.l10n;
    final label = _portLabel(context, port);
    final result = await showConsoleRenameSheet(
      context,
      title: l10n.routingRenameTitle,
      subtitle: label,
      current: current,
      fieldLabel: l10n.routingRenameField(label),
      // An empty name is a real answer: it hands the port back its numbers.
      allowEmpty: true,
    );
    if (result == null || !context.mounted) return;
    switch (side) {
      case RoutingNames.inputs:
        await context.read<InputsCubit>().rename(port, result);
      case RoutingNames.outputs:
        await context.read<OutputsCubit>().rename(port, result);
    }
  }

  /// What the row calls the port itself: a jack, or the pair a destination
  /// drives.
  String _portLabel(BuildContext context, int port) {
    final l10n = context.l10n;
    return switch (side) {
      RoutingNames.inputs => l10n.routingInputOrdinal(port + 1),
      RoutingNames.outputs => l10n.outputBusLabel(
        port,
        channels: context.read<LooperBloc>().state.status.outputChannels,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = context.select<LooperBloc, EngineStatus>(
      (bloc) => bloc.state.status,
    );
    final busCount = context.select<LooperBloc, int>(
      (bloc) => bloc.state.outputBusCount,
    );
    final (count, names) = switch (side) {
      RoutingNames.inputs => (
        status.inputChannels,
        context.watch<InputsCubit>().state.names,
      ),
      RoutingNames.outputs => (
        busCount,
        context.watch<OutputsCubit>().state.names,
      ),
    };

    if (count == 0) {
      return Positioned(
        left: 100,
        top: 132,
        child: LoopNote(l10n.routingNoPortsYet),
      );
    }
    return Positioned(
      left: 100,
      top: 132,
      width: 1720,
      height: 800,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 6),
        itemCount: count,
        itemExtent: _rowStep,
        itemBuilder: (context, port) {
          final given = names[port] ?? '';
          return _NameRow(
            key: Key('routing_name_row_$port'),
            port: _portLabel(context, port),
            name: given.isNotEmpty
                ? given
                : switch (side) {
                    RoutingNames.inputs => l10n.inputName(names, port),
                    RoutingNames.outputs => l10n.outputName(
                      names,
                      port,
                      channels: status.outputChannels,
                    ),
                  },
            named: given.isNotEmpty,
            onRename: () => unawaited(_rename(context, port, given)),
          );
        },
      ),
    );
  }
}

/// The pen's `route:rename:*` row: a port, what it is called, and Rename.
class _NameRow extends StatelessWidget {
  const _NameRow({
    required this.port,
    required this.name,
    required this.named,
    required this.onRename,
    super.key,
  });

  final String port;
  final String name;
  final bool named;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(left: 6, right: 6, bottom: 12),
      // The whole row is the button, as the pen draws it: a 1708 x 108 target
      // beats a pill inside it on a screen driven by fingers.
      child: Semantics(
        button: true,
        label: l10n.routingRenameField(port),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onRename,
          child: Container(
            height: 108,
            decoration: BoxDecoration(
              color: surface.card,
              border: Border.all(color: surface.borderSubtle),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 33,
                  top: 38,
                  child: AppText(
                    port,
                    style: TextStyle(
                      color: surface.textTertiary,
                      fontSize: 26,
                      height: 1,
                    ),
                  ),
                ),
                Positioned(
                  left: 245,
                  top: 36,
                  width: 1238,
                  child: AppText(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      // An unnamed port shows its fallback, which is a label
                      // rather than a name and reads as one.
                      color: named ? surface.textPrimary : surface.textTertiary,
                      fontSize: 30,
                      height: 1,
                    ),
                  ),
                ),
                Positioned(
                  right: 27,
                  top: 40,
                  child: Row(
                    key: const Key('routing_rename'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppText(
                        l10n.routingRename,
                        style: TextStyle(
                          color: surface.textSecondary,
                          fontSize: 24,
                          height: 1,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        LucideIcons.pencil,
                        size: 28,
                        color: surface.textSecondary,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
