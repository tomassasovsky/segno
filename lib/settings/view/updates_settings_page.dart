import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/appliance/power_off/power_host.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_settings/loop_select.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_frame.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/settings/view/about_settings_page.dart';
import 'package:segno/settings/view/settings_fact_panel.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';

/// Settings > Updates: the running version, the one panel that carries the
/// check → download → install flow, the automatic check and channel, and the
/// way on to About and the controller's firmware.
///
/// **Nothing downloads until asked.** Check automatically only looks; the
/// offer is a panel with one button to accept it, and Install and restart
/// is the power flow's restart, which refuses during a take and saves the
/// session first.
///
/// **Failures are said, not hidden.** An install cut off by a crash or a
/// power loss comes back as Update paused, and a staged build that did not
/// start leaves a notice naming both versions until it is dismissed.
///
/// **The encoder lands on the next thing to do.** Each state's one action
/// takes focus when the state arrives, so a flow that runs for minutes never
/// leaves focus on a button that has gone.
class UpdatesSettingsPage extends StatefulWidget {
  /// Creates an [UpdatesSettingsPage].
  const UpdatesSettingsPage({super.key});

  /// The width of the panels' controls column inside a fact row.
  static const double controlWidth = 320;

  @override
  State<UpdatesSettingsPage> createState() => _UpdatesSettingsPageState();
}

class _UpdatesSettingsPageState extends State<UpdatesSettingsPage> {
  /// The node of the current state's one action, which takes the encoder
  /// focus whenever the state changes.
  final FocusNode _next = FocusNode(debugLabel: 'UpdatesNext');

  @override
  void initState() {
    super.initState();
    _focusNext();
  }

  @override
  void dispose() {
    _next.dispose();
    super.dispose();
  }

  /// Moves the encoder to the current state's action once it is built.
  void _focusNext() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _next.context == null || !_next.canRequestFocus) return;
      _next.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final state = context.watch<UpdateCubit>().state;
    final cubit = context.read<UpdateCubit>();
    final version = state.currentVersion;
    final busy =
        state.phase == UpdatePhase.checking ||
        state.phase == UpdatePhase.downloading;
    // The check is the state's action whenever the panel has none of its own.
    final checkIsNext = switch (state.phase) {
      UpdatePhase.idle || UpdatePhase.upToDate || UpdatePhase.checking => true,
      UpdatePhase.error => state.failure != UpdateFailure.download,
      _ => false,
    };

    final rollback = state.rollback;
    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (rollback != null) ...[
          _RollbackNotice(
            text: l10n.updatesPageRollback(
              '${rollback.attempted}',
              '${rollback.restored}',
            ),
            onDismiss: () => unawaited(cubit.dismissRollback()),
          ),
          const SizedBox(height: 24),
        ],
        SizedBox(
          width: AboutSettingsPage.columnWidth,
          height: 64,
          child: Row(
            children: [
              Expanded(
                child: version == null
                    ? const SizedBox.shrink()
                    : LoopSectionLabel(
                        l10n.updatesPageInstalled('$version'),
                        key: const Key('updates_installed'),
                      ),
              ),
              if (state.supported)
                LoopOutlinedButton(
                  key: const Key('updates_check'),
                  focusNode: checkIsNext ? _next : null,
                  width: UpdatesSettingsPage.controlWidth,
                  label: l10n.updatesPageCheck,
                  onTap: busy ? null : () => unawaited(cubit.check()),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _StatusPanel(state: state, cubit: cubit, next: _next),
      ],
    );

    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.supported) ...[
          SettingsFactPanel(
            key: const Key('updates_automatic'),
            title: l10n.updatesPageAutomaticPanel,
            width: AboutSettingsPage.columnWidth,
            rows: [
              SettingsFactRow(
                key: const Key('updates_auto_check_row'),
                label: l10n.updatesPageAutoCheck,
                caption: l10n.updatesPageAutoCheckCaption,
                trailing: LoopChoiceRow<bool>(
                  values: const [false, true],
                  labelOf: (on) => on ? l10n.toggleOn : l10n.toggleOff,
                  keyOf: (on) => Key(
                    on ? 'updates_auto_check_on' : 'updates_auto_check_off',
                  ),
                  selected: state.autoCheck,
                  onSelected: (on) => unawaited(cubit.setAutoCheck(value: on)),
                  width: UpdatesSettingsPage.controlWidth,
                  height: 56,
                  gap: 12,
                ),
              ),
              SettingsFactRow(
                key: const Key('updates_channel_row'),
                label: l10n.updatesPageChannel,
                // Locked mid-download rather than hidden: switching would
                // abandon a bundle already half staged.
                trailing: LoopSelect<bool>(
                  key: const Key('updates_channel'),
                  value: state.channel == 'experimental',
                  enabled: state.phase != UpdatePhase.downloading,
                  width: UpdatesSettingsPage.controlWidth,
                  height: 56,
                  items: [
                    LoopSelectItem(
                      key: const Key('updates_channel_production'),
                      value: false,
                      label: l10n.updatesPageChannelProduction,
                    ),
                    LoopSelectItem(
                      key: const Key('updates_channel_experimental'),
                      value: true,
                      label: l10n.updatesPageChannelExperimental,
                    ),
                  ],
                  onSelected: (experimental) => unawaited(
                    cubit.setExperimentalChannel(value: experimental),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
        ],
        SettingsFactPanel(
          key: const Key('updates_console'),
          title: l10n.updatesPageConsolePanel,
          width: AboutSettingsPage.columnWidth,
          rows: [
            SettingsFactRow(
              key: const Key('updates_about_row'),
              label: l10n.settingsAboutTitle,
              onTap: () => unawaited(openAboutSettings()),
            ),
            SettingsFactRow(
              key: const Key('updates_controller_row'),
              label: l10n.aboutControllerFirmwareRow,
              onTap: () => unawaited(openControllerFirmware()),
            ),
          ],
        ),
      ],
    );

    return BlocListener<UpdateCubit, UpdateState>(
      listenWhen: (previous, current) =>
          previous.phase != current.phase ||
          previous.failure != current.failure,
      listener: (_, _) => _focusNext(),
      child: Scaffold(
        body: LoopSettingsFrame(
          crumb: l10n.settingsCrumb(l10n.settingsUpdatesTitle),
          title: l10n.settingsUpdatesTitle,
          titleLeft: 100,
          onBack: () => Navigator.maybePop(context),
          onStage: () => Navigator.popUntil(context, (route) => route.isFirst),
          children: [
            Positioned(
              left: AboutSettingsPage.columns[0],
              top: AboutSettingsPage.top,
              child: left,
            ),
            Positioned(
              left: AboutSettingsPage.columns[1],
              top: AboutSettingsPage.top,
              child: right,
            ),
          ],
        ),
      ),
    );
  }
}

/// The one panel the update flow runs in: its title names the state, a meta
/// line names the version on offer, a sentence says what is happening, and
/// the state's actions sit under it. [next] goes to the action the encoder
/// should land on.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.state,
    required this.cubit,
    required this.next,
  });

  final UpdateState state;
  final UpdateCubit cubit;
  final FocusNode next;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final offered = state.available;
    final offeredVersion = offered == null ? null : '${offered.version}';
    final megabytes = (offered?.size ?? 0) > 0
        ? (offered!.size / 1000000).round()
        : null;

    final (
      String title,
      String? meta,
      String? sentence,
      List<Widget> actions,
    ) = !state.supported
        ? (l10n.updatesPanelSoftware, null, l10n.updatesUnsupportedBanner, [])
        : switch (state.phase) {
            UpdatePhase.idle => (
              l10n.updatesPanelSoftware,
              null,
              l10n.updatesPageIdle,
              <Widget>[],
            ),
            UpdatePhase.checking => (
              l10n.updatesPanelSoftware,
              null,
              l10n.updatesCheckingLabel,
              <Widget>[],
            ),
            UpdatePhase.upToDate => (
              l10n.updatesPanelSoftware,
              null,
              l10n.updatesUpToDateSubtitle(state.channel),
              <Widget>[],
            ),
            UpdatePhase.available => (
              l10n.updatesPanelAvailable,
              _meta(l10n, offeredVersion, megabytes),
              offered?.notes.isNotEmpty ?? false ? offered!.notes : null,
              [
                LoopOutlinedButton(
                  key: const Key('updates_download'),
                  focusNode: next,
                  tone: LoopButtonTone.accent,
                  width: UpdatesSettingsPage.controlWidth,
                  label: l10n.updatesPageDownload,
                  onTap: () => unawaited(cubit.startDownload()),
                ),
              ],
            ),
            UpdatePhase.downloading => (
              l10n.updatesPanelDownloading,
              _meta(l10n, offeredVersion, megabytes),
              null,
              [
                // Only while downloading: RAUC's slot write cannot be stopped.
                if (state.progress < kUpdateInstallStartsAt)
                  LoopOutlinedButton(
                    key: const Key('updates_cancel'),
                    focusNode: next,
                    width: 200,
                    label: l10n.updatesPageCancel,
                    onTap: () => unawaited(cubit.cancelDownload()),
                  ),
              ],
            ),
            UpdatePhase.staged => (
              l10n.updatesPanelReady,
              _meta(l10n, offeredVersion, null),
              l10n.updatesRestartBusySubtitle,
              [
                LoopOutlinedButton(
                  key: const Key('updates_install_restart'),
                  focusNode: next,
                  tone: LoopButtonTone.accent,
                  width: UpdatesSettingsPage.controlWidth,
                  label: l10n.updatesPageInstallRestart,
                  // The power flow's restart: refused during a take, and the
                  // session is saved before the helper boots the new slot.
                  onTap: () => requestRestart(context),
                ),
              ],
            ),
            UpdatePhase.interrupted => (
              l10n.updatesPanelPaused,
              _meta(l10n, state.interrupted?.toString(), null),
              l10n.updatesPageInterrupted,
              [
                LoopOutlinedButton(
                  key: const Key('updates_retry'),
                  focusNode: next,
                  tone: LoopButtonTone.accent,
                  width: 200,
                  label: l10n.updatesPageRetry,
                  onTap: () => unawaited(cubit.retryInterrupted()),
                ),
                LoopOutlinedButton(
                  key: const Key('updates_discard'),
                  width: 200,
                  label: l10n.updatesPageCancel,
                  onTap: () => unawaited(cubit.discardInterrupted()),
                ),
              ],
            ),
            // A failed download is not a failed check: it names the download
            // and retries the download, where a failed check's retry is the
            // check button above.
            UpdatePhase.error => switch (state.failure) {
              UpdateFailure.download => (
                l10n.updatesPanelAvailable,
                _meta(l10n, offeredVersion, megabytes),
                l10n.updatesPageDownloadFailed,
                <Widget>[
                  LoopOutlinedButton(
                    key: const Key('updates_retry'),
                    focusNode: next,
                    tone: LoopButtonTone.accent,
                    width: 200,
                    label: l10n.updatesPageRetry,
                    onTap: () => unawaited(cubit.startDownload()),
                  ),
                ],
              ),
              UpdateFailure.check || null => (
                l10n.updatesPanelSoftware,
                null,
                l10n.updatesPageCheckFailed,
                <Widget>[],
              ),
            },
          };
    final failed =
        state.supported &&
        (state.phase == UpdatePhase.error ||
            state.phase == UpdatePhase.interrupted);

    return Container(
      key: const Key('updates_status'),
      width: AboutSettingsPage.columnWidth,
      padding: const EdgeInsets.all(SettingsFactPanel.inset),
      decoration: BoxDecoration(
        color: surface.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surface.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: LoopSectionLabel(
              title,
              key: const Key('updates_status_title'),
            ),
          ),
          if (meta != null) ...[
            const SizedBox(height: 12),
            AppText(
              meta,
              key: const Key('updates_status_meta'),
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 24,
                height: 1.2,
              ),
            ),
          ],
          if (sentence != null) ...[
            const SizedBox(height: 12),
            LoopNote(
              sentence,
              key: const Key('updates_status_sentence'),
              tone: failed ? LoopNoteTone.error : LoopNoteTone.plain,
            ),
          ],
          if (state.supported && state.phase == UpdatePhase.downloading) ...[
            const SizedBox(height: 24),
            _ProgressBar(progress: state.progress),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 32),
            Row(
              children: [
                for (final (index, action) in actions.indexed) ...[
                  if (index > 0) const SizedBox(width: 16),
                  action,
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String? _meta(AppLocalizations l10n, String? version, int? mb) {
    if (version == null) return null;
    return mb == null
        ? l10n.updatesPageVersion(version)
        : l10n.updatesPageVersionSize(version, mb);
  }
}

/// The download's real progress: a track, its fill, and the percentage.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final percent = context.l10n.updatesPagePercent((progress * 100).round());
    return Semantics(
      label: context.l10n.updatesPanelDownloading,
      value: percent,
      excludeSemantics: true,
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 12,
                child: ColoredBox(
                  color: surface.meterTrack,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      key: const Key('updates_progress'),
                      widthFactor: progress.clamp(0.0, 1.0),
                      heightFactor: 1,
                      child: ColoredBox(color: surface.accent),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          SizedBox(
            width: 88,
            child: AppText(
              percent,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 24,
                height: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The rolled-back notice: a warning edge, the sentence naming both
/// versions, and Dismiss. It stays, whatever the panel shows, until
/// dismissed.
class _RollbackNotice extends StatelessWidget {
  const _RollbackNotice({required this.text, required this.onDismiss});

  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    return Container(
      key: const Key('updates_rollback_notice'),
      width: AboutSettingsPage.columnWidth,
      padding: const EdgeInsets.fromLTRB(27, 16, 16, 16),
      decoration: BoxDecoration(
        color: surface.warning.withValues(alpha: 0.14),
        border: Border(left: BorderSide(color: surface.warning, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: AppText(
              text,
              style: TextStyle(
                color: surface.textPrimary,
                fontSize: 24,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 24),
          LoopOutlinedButton(
            key: const Key('updates_rollback_dismiss'),
            width: 160,
            height: 56,
            label: context.l10n.updatesPageDismiss,
            onTap: onDismiss,
          ),
        ],
      ),
    );
  }
}
