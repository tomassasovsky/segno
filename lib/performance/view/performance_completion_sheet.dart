import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:performance_repository/performance_repository.dart';
import 'package:segno/common/console_mode.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/performance/view/export_device_chain_summary.dart';
import 'package:segno/theme/theme.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shows the capture dialog for the live [PerformanceRecorderCubit] (read
/// from [context]) — the rendering face while the offline render runs, the
/// completion face once it settles.
///
/// A centred dialog, not a bottom sheet: `SESSION & CAPTURE / capture-saved`
/// draws this as a 744 panel in the console's own `Dialog` idiom, over the
/// stage. The sheet this replaces rose from the bottom edge in Material's
/// idiom, which nothing else on the console uses.
Future<void> showPerformanceCompletionSheet(BuildContext context) async {
  // One at a time. The listener fires on entering Rendering AND on entering
  // Completed; when the render outlives the operator's patience they Hide the
  // first and the second call reopens it, but when the dialog is still up it
  // simply morphs — a second route on top of it would stack two copies of the
  // same capture.
  if (PerformanceCompletionSheet._open) return;
  // Set here, not in the widget's initState: the route's first build is a
  // frame away, and a second listener firing inside that gap would stack a
  // copy.
  //
  // Cleared TWICE, deliberately, because each clear covers the other's blind
  // spot. The `finally` runs when `showDialog`'s future resolves — at pop
  // INITIATION, before the ~150ms exit transition — so a `Completed` that
  // lands while Hide's animation is still running can reopen the dialog
  // instead of being refused against a corpse (the capture's own result
  // dialog would otherwise be gone for good: nothing else ever reopens it).
  // The dispose clear covers the tree being torn down WITHOUT a pop (a test,
  // a window close), where the future never resolves and a finally alone
  // would wedge the flag true for the life of the process.
  PerformanceCompletionSheet._open = true;
  try {
    final cubit = context.read<PerformanceRecorderCubit>();
    await showDialog<void>(
      context: context,
      barrierColor: context.surface.scrim,
      builder: (_) => BlocProvider<PerformanceRecorderCubit>.value(
        value: cubit,
        child: const PerformanceCompletionSheet(),
      ),
    );
  } finally {
    PerformanceCompletionSheet._open = false;
  }
}

/// A capture's outcome, drawn to `SESSION & CAPTURE / capture-saved` and its
/// state variants: the title and where it went, a banner when something went
/// wrong on the way (stopped early / dropped frames / partial render), the
/// per-track EXPORT card, and the action row.
///
/// Watches [PerformanceRecorderCubit] directly (rather than taking the result
/// as a constructor param) so a rename mid-dialog updates the displayed name
/// immediately — and so the `capture-rendering` face morphs into
/// `capture-saved` in place when the render lands, exactly the transition the
/// pen draws as two frames of one dialog.
class PerformanceCompletionSheet extends StatefulWidget {
  /// Creates a [PerformanceCompletionSheet].
  const PerformanceCompletionSheet({super.key});

  /// Whether the dialog route is currently up — see
  /// [showPerformanceCompletionSheet]'s double-open refusal.
  static bool _open = false;

  @override
  State<PerformanceCompletionSheet> createState() =>
      _PerformanceCompletionSheetState();
}

class _PerformanceCompletionSheetState
    extends State<PerformanceCompletionSheet> {
  @override
  void dispose() {
    PerformanceCompletionSheet._open = false;
    super.dispose();
  }

  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;

  static String _revealLabel(AppLocalizations l10n) {
    if (Platform.isMacOS) return l10n.perfRevealMacos;
    if (Platform.isWindows) return l10n.perfRevealWindows;
    return l10n.perfRevealOther;
  }

  /// `2:14` for the pen's subtitle — minutes unpadded, seconds padded — and
  /// `1:15:04` past the hour, so a long set does not read as 75 minutes.
  static String _mmss(Duration d) {
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final m = (d.inMinutes % 60).toString().padLeft(2, '0');
      return '${d.inHours}:$m:$s';
    }
    return '${d.inMinutes}:$s';
  }

  Future<void> _reveal(String path) => launchUrl(Uri.directory(path));

  Future<void> _rename(BuildContext context, String path) async {
    final cubit = context.read<PerformanceRecorderCubit>();
    final l10n = context.l10n;
    // The console has no physical keyboard, so its rename is the full-width
    // sheet with the on-screen keys — the same surface every other rename on
    // the appliance uses. The desktop keeps the compact dialog its hardware
    // keyboard is already pointed at (#668).
    final to = kConsoleMode
        ? await showConsoleRenameSheet(
            context,
            title: l10n.perfRenameTitle,
            subtitle: _basename(path),
            current: _basename(path),
            fieldLabel: l10n.perfRenameTitle,
          )
        : await showDialog<String>(
            context: context,
            builder: (_) => _RenameCaptureDialog(initial: _basename(path)),
          );
    if (to == null) return;
    // The desktop dialog pre-validates inline; the console sheet has no
    // validator hook, so the same `performanceCaptureSlug` check runs here —
    // BEFORE the cubit call, because `renameCapture` rejects an unfoldable
    // name with an `ArgumentError`, which is not for catching.
    if (performanceCaptureSlug(to) == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: AppText(l10n.perfRenameInvalid)));
      return;
    }
    try {
      await cubit.renameCompletedCapture(to);
    } on PerformanceNameCollision catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: AppText(l10n.perfRenameDuplicate(e.slug))),
      );
    }
  }

  /// Pops the dialog when [state] is one this dialog cannot draw.
  ///
  /// Without this the route stayed pushed drawing `SizedBox.shrink` under its
  /// own modal barrier — a dimmed, empty, untouchable stage. Reachable: the
  /// pedal's MODE long-press arms through the repository, which has no
  /// render-in-progress gate, so the state can leave Rendering for Armed
  /// while this dialog is up.
  void _popIfForeign(BuildContext context, PerformanceRecorderState state) {
    final ours =
        state is PerformanceRecorderRendering ||
        (state is PerformanceRecorderCompleted && state.result != null);
    if (!ours) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PerformanceRecorderCubit>().state;
    return BlocListener<PerformanceRecorderCubit, PerformanceRecorderState>(
      listener: _popIfForeign,
      child: _face(context, state),
    );
  }

  Widget _face(BuildContext context, PerformanceRecorderState state) {
    // The rendering face: percent in the title, Hide as the only action.
    // Hiding is safe — the render carries on, the completion listener reopens
    // this dialog when it lands, and arming another capture is refused by the
    // CUBIT until then (`c/capture-rendering`). The pedal does not go through
    // the cubit — see [_popIfForeign].
    if (state is PerformanceRecorderRendering) {
      return _RenderingDialog(state: state);
    }
    if (state is! PerformanceRecorderCompleted || state.result == null) {
      return const SizedBox.shrink();
    }
    final result = state.result!;
    final path = switch (result) {
      PerformanceRecordDone(:final path) => path,
      PerformanceRecordPartial(:final path) => path,
      PerformanceRecordStoppedEarly(:final path) => path,
    };
    final l10n = context.l10n;
    final surface = context.surface;
    final name = _basename(path);
    // Three subtitles, best fact first: count and length when both are
    // known, length alone when the export produced no DAW tracks, the bare
    // name when the duration is unknowable (a recovered boot capture).
    final duration = state.duration;
    final subtitle = duration == null
        ? l10n.perfSavedSubtitlePlain(name)
        : state.tracks.isEmpty
        ? l10n.perfSavedSubtitleTimed(name, _mmss(duration))
        : l10n.perfSavedSubtitle(
            name,
            state.tracks.length,
            _mmss(duration),
          );
    // What went wrong on the way, if anything — the pen draws each as a
    // banner between the subtitle and the EXPORT card. Stopped-early outranks
    // a glitch: a capture that ended early with dropped frames has the
    // earlier, larger problem first.
    final (banner, tone) = switch (result) {
      PerformanceRecordStoppedEarly(:final reason) => (
        switch (reason) {
          PerformanceStopReason.diskFull => l10n.perfStoppedDiskFull,
          PerformanceStopReason.deviceChanged => l10n.perfStoppedDeviceChange,
        },
        ConsoleBannerTone.failure,
      ),
      PerformanceRecordPartial() => (
        l10n.perfPartial,
        ConsoleBannerTone.failure,
      ),
      PerformanceRecordDone() when state.hadGlitch => (
        l10n.perfCaptureGlitch,
        ConsoleBannerTone.pending,
      ),
      PerformanceRecordDone() => (null, ConsoleBannerTone.steady),
    };

    return ConsoleDialogShell(
      key: const Key('perfCompletion_sheet'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _DialogTitle(l10n.perfDone),
          const SizedBox(height: 10),
          AppText(
            subtitle,
            key: const Key('perfCompletion_subtitle'),
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 16,
              height: 1.25,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          if (banner != null) ...[
            const SizedBox(height: 14),
            ConsoleBanner(
              key: const Key('perfCompletion_banner'),
              message: banner,
              tone: tone,
            ),
          ],
          if (state.reExportFailed) ...[
            const SizedBox(height: 14),
            ConsoleBanner(
              key: const Key('perfCompletion_reExportFailed'),
              message: l10n.perfExportReExportFailed,
              tone: ConsoleBannerTone.failure,
            ),
          ],
          if (state.tracks.isNotEmpty) ...[
            const SizedBox(height: 19),
            ExportDeviceChainSummary(tracks: state.tracks),
          ],
          const SizedBox(height: 19),
          // A Wrap, not a Row: the reveal label is platform text ("Show in
          // Finder" on macOS, "Show in file manager" on Linux — six
          // characters longer), and on the harness font the Linux one
          // overflowed the 694 by 20px. One line when it fits, which is
          // every real case; a second line instead of a clipped button when
          // it does not.
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              ConsoleSmallButton(
                key: const Key('perfCompletion_reveal'),
                label: _revealLabel(l10n),
                onPressed: () => unawaited(_reveal(path)),
              ),
              ConsoleSmallButton(
                key: const Key('perfCompletion_reExport'),
                label: l10n.perfExportReExport,
                onPressed: state.isReExporting
                    ? null
                    : () => unawaited(
                        context.read<PerformanceRecorderCubit>().reExport(),
                      ),
              ),
              ConsoleSmallButton(
                key: const Key('perfCompletion_rename'),
                label: l10n.perfRenameButton,
                onPressed: () => unawaited(_rename(context, path)),
              ),
              ConsoleDialogButton(
                key: const Key('perfCompletion_close'),
                label: l10n.done,
                tone: ConsoleDialogTone.accent,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `SESSION & CAPTURE / capture-rendering`: the percent, what is being
/// written, and Hide.
class _RenderingDialog extends StatelessWidget {
  const _RenderingDialog({required this.state});

  final PerformanceRecorderRendering state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final name = state.name;
    return ConsoleDialogShell(
      key: const Key('perfRendering_dialog'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _DialogTitle(l10n.perfRenderingTitle(state.percent)),
          const SizedBox(height: 10),
          AppText(
            name == null
                ? l10n.perfRenderingSubtitle
                : l10n.perfRenderingSubtitleNamed(name),
            style: TextStyle(
              color: surface.textSecondary,
              fontSize: 16,
              height: 1.25,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          const SizedBox(height: 19),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ConsoleDialogButton(
                key: const Key('perfRendering_hide'),
                label: l10n.perfHide,
                tone: ConsoleDialogTone.accent,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The 19/650 dialog title both faces share.
class _DialogTitle extends StatelessWidget {
  const _DialogTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => AppText(
    text,
    style: TextStyle(
      color: context.surface.textPrimary,
      fontSize: 19,
      height: 1.15,
      fontWeight: FontWeight.w600,
      leadingDistribution: TextLeadingDistribution.even,
    ),
  );
}

class _RenameCaptureDialog extends StatefulWidget {
  const _RenameCaptureDialog({required this.initial});

  final String initial;

  @override
  State<_RenameCaptureDialog> createState() => _RenameCaptureDialogState();
}

class _RenameCaptureDialogState extends State<_RenameCaptureDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final raw = _controller.text;
    if (performanceCaptureSlug(raw) == null) {
      setState(() => _error = l10n.perfRenameInvalid);
      return;
    }
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: AppText(l10n.perfRenameTitle),
      content: TextField(
        key: const Key('perfRename_field'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: l10n.perfRenameHint,
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: AppText(l10n.cancel),
        ),
        TextButton(
          key: const Key('perfRename_save'),
          onPressed: _submit,
          child: AppText(l10n.perfRenameButton),
        ),
      ],
    );
  }
}
