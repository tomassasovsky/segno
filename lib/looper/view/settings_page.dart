import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/app/segno_navigator.dart';
import 'package:segno/audio_setup/audio_setup.dart';
import 'package:segno/control/control.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/cubit/high_contrast_cubit.dart';
import 'package:segno/looper/cubit/refresh_rate_cubit.dart';
import 'package:segno/looper/cubit/tracks_cubit.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:segno/looper/view/rename_track_dialog.dart';
import 'package:segno/setup/setup_surface.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:segno/update/view/updates_settings_section.dart';
import 'package:segno/visualizer/visualizer.dart';

/// A settings section, shown one at a time and selected from the left rail.
enum SettingsSection {
  /// Appearance / view preferences.
  view,

  /// Audio device and engine settings.
  audio,

  /// Per-track names and length presets.
  tracks,

  /// Appliance / desktop in-app updates.
  updates,
}

/// The app settings page, reachable from the Tracks view via right-click or
/// the `S` key, and from the system menu bar on macOS.
///
/// Laid out like the audio onboarding panel: a dark centered surface with a
/// left rail that selects a section, and a scrollable right pane of the
/// selected section's controls. `Esc` closes the page.
class SettingsPage extends StatefulWidget {
  /// Creates a [SettingsPage].
  const SettingsPage({
    super.key,
    this.initialSection = SettingsSection.view,
    this.onSectionChanged,
  });

  /// Section shown when the page first opens (e.g. Updates from the toast).
  final SettingsSection initialSection;

  /// Notifies when the left-rail selection changes (and once for the initial
  /// section). Used so the shell can suppress the update toast while Updates
  /// is already visible.
  final ValueChanged<SettingsSection>? onSectionChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SettingsSection _section = widget.initialSection;

  @override
  void initState() {
    super.initState();
    widget.onSectionChanged?.call(_section);
  }

  void _select(SettingsSection section) {
    if (section == _section) return;
    setState(() => _section = section);
    widget.onSectionChanged?.call(section);
  }

  @override
  Widget build(BuildContext context) {
    // Esc closes settings. The rename dialog is a separate route pushed on top,
    // so its own focus scope handles Esc first — this never swallows it.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        // Full-bleed: a full-screen Scaffold (supplying the Material ancestor
        // the rail's ink taps need) instead of the old centered 940×640 panel.
        // CallbackShortcuts + Focus stay outside it so Esc still closes.
        child: Scaffold(
          backgroundColor: context.surface.background,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 264,
                    child: _SettingsRail(
                      current: _section,
                      onSelect: _select,
                    ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: context.surface.line,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: ValueKey(_section),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(34, 34, 30, 26),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: _sectionChildren(context),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 10,
                right: 10,
                child: IconButton(
                  key: const Key('settings_close_button'),
                  tooltip: context.l10n.close,
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: context.surface.textSecondary,
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sectionChildren(BuildContext context) => switch (_section) {
    SettingsSection.view => _viewSection(context),
    SettingsSection.audio => _audioSection(context),
    SettingsSection.tracks => _tracksSection(context),
    SettingsSection.updates => const [UpdatesSettingsSection()],
  };

  List<Widget> _viewSection(BuildContext context) {
    final l10n = context.l10n;
    final waveformEnabled = context.watch<WaveformWindowCubit>().state.enabled;
    final highContrast = context.watch<HighContrastCubit>().state;
    // The default mode is a looper-wide behavior default, owned by the shared
    // control overlay (the InteractionMode's home), not a view preference.
    final defaultMode = context.watch<ControlCubit>().state.defaultMode;
    final refreshHz = context.watch<RefreshRateCubit>().state;
    return [
      AppText(l10n.settingsViewIntro, style: context.setupBody),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.viewGroupLabel),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('settings_waveformWindow_switch'),
        title: l10n.waveformWindowTitle,
        subtitle: l10n.waveformWindowSubtitle,
        value: waveformEnabled,
        onChanged: (on) =>
            context.read<WaveformWindowCubit>().setEnabled(value: on),
      ),
      const SizedBox(height: 12),
      SetupToggleRow(
        toggleKey: const Key('settings_highContrast_switch'),
        title: l10n.highContrastTitle,
        subtitle: l10n.highContrastSubtitle,
        value: highContrast,
        onChanged: (on) =>
            unawaited(context.read<HighContrastCubit>().setEnabled(value: on)),
      ),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.looperGroupLabel),
      const SizedBox(height: 12),
      AppText(l10n.defaultModeIntro, style: context.setupBody),
      const SizedBox(height: 12),
      SetupOptionRow<InteractionMode>(
        selected: defaultMode,
        onSelected: (m) => context.read<ControlCubit>().setDefaultMode(m),
        options: [
          SetupOption(
            value: InteractionMode.record,
            label: l10n.recordModeLabel,
            sub: l10n.recordModeSub,
            optionKey: const Key('settings_defaultMode_record'),
          ),
          SetupOption(
            value: InteractionMode.mute,
            label: l10n.muteModeLabel,
            sub: l10n.muteModeSub,
            optionKey: const Key('settings_defaultMode_mute'),
          ),
        ],
      ),
      const SizedBox(height: 20),
      AppText(l10n.refreshRateIntro, style: context.setupBody),
      const SizedBox(height: 12),
      SetupOptionRow<int>(
        selected: refreshHz,
        onSelected: (hz) =>
            unawaited(context.read<RefreshRateCubit>().setHz(hz)),
        options: [
          for (final hz in RefreshRateCubit.options)
            SetupOption(
              value: hz,
              label: l10n.refreshRateHz(hz),
              sub: switch (hz) {
                30 => l10n.refreshRateLowCpu,
                120 => l10n.refreshRateSmoothest,
                _ => l10n.defaultLabel,
              },
              optionKey: Key('settings_refreshRate_$hz'),
            ),
        ],
      ),
    ];
  }

  List<Widget> _audioSection(BuildContext context) => const [
    AudioSettingsSection(),
  ];

  List<Widget> _tracksSection(BuildContext context) {
    final l10n = context.l10n;
    final tracks = context.watch<TracksCubit>();
    return [
      AppText(l10n.tracksIntro, style: context.setupBody),
      const SizedBox(height: 28),
      SetupGroupLabel(l10n.tracksGroupLabel),
      const SizedBox(height: 12),
      for (var i = 0; i < tracks.state.names.length; i++) ...[
        SetupTrackNameRow(
          rowKey: Key('settings_trackName_$i'),
          channel: i,
          name: l10n.trackName(tracks.state.names, i),
          onTap: () => showRenameTrackDialog(
            context: context,
            cubit: context.read<TracksCubit>(),
            channel: i,
            current: tracks.state.names[i],
          ),
        ),
        if (i < tracks.state.names.length - 1) const SizedBox(height: 8),
      ],
    ];
  }
}

class _SettingsRail extends StatelessWidget {
  const _SettingsRail({required this.current, required this.onSelect});

  final SettingsSection current;
  final ValueChanged<SettingsSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 32, 22, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: context.surface.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              AppText(l10n.settingsKicker, style: context.setupKicker),
            ],
          ),
          const SizedBox(height: 28),
          AppText(l10n.settingsTitle, style: context.setupTitle),
          const SizedBox(height: 20),
          for (final section in SettingsSection.values) ...[
            // The Updates tab appears only where in-app updates are supported
            // (appliance / desktop); it stays hidden on unsupported builds.
            if (section != SettingsSection.updates ||
                context.watch<UpdateCubit>().state.supported)
              _RailTab(
                key: Key('settings_tab_${section.name}'),
                label: _sectionLabel(l10n, section),
                selected: section == current,
                onTap: () => onSelect(section),
              ),
            // Loop settings are their own route (accepted design, slice
            // 2c): a row after Audio that opens it and leaves this page on
            // its current section.
            if (section == SettingsSection.audio) ...[
              _RailTab(
                key: const Key('settings_tab_loop'),
                label: l10n.settingsSectionLoop,
                selected: false,
                onTap: () => unawaited(openLoopSettings()),
              ),
              // Audio routing is its own route too (slice 3c), beside Loop.
              _RailTab(
                key: const Key('settings_tab_routing'),
                label: l10n.settingsSectionRouting,
                selected: false,
                onTap: () => unawaited(openAudioRouting()),
              ),
              // Effects, on the same rule (slice 3f).
              _RailTab(
                key: const Key('settings_tab_fx'),
                label: l10n.fxTitle,
                selected: false,
                onTap: () => unawaited(openFx()),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

String _sectionLabel(AppLocalizations l10n, SettingsSection section) =>
    switch (section) {
      SettingsSection.view => l10n.settingsSectionView,
      SettingsSection.audio => l10n.settingsSectionAudio,
      SettingsSection.tracks => l10n.settingsSectionTracks,
      SettingsSection.updates => l10n.settingsSectionUpdates,
    };

class _RailTab extends StatelessWidget {
  const _RailTab({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? context.surface.cardHigh : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: AppText(
              label,
              style: TextStyle(
                color: selected
                    ? context.surface.textPrimary
                    : context.surface.textSecondary,
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
