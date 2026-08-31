import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/appliance/power_off/power_off_cubit.dart';
import 'package:segno/appliance/power_off/power_off_dialog.dart';
import 'package:segno/appliance/power_off/power_off_gate.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:session_repository/session_repository.dart';

/// Listens for the rear power button, shows confirm, and runs Save As.
///
/// Mounted under LooperPage so it can read SessionCubit / the page
/// [LooperBloc]. [PowerOffCubit] itself is provided app-wide. Silent when
/// either is missing (widget tests that pump the page without the cubit).
class PowerOffHost extends StatefulWidget {
  /// Creates a [PowerOffHost] wrapping [child].
  const PowerOffHost({required this.child, super.key});

  /// The rest of the looper page.
  final Widget child;

  @override
  State<PowerOffHost> createState() => _PowerOffHostState();
}

class _PowerOffHostState extends State<PowerOffHost> {
  StreamSubscription<void>? _keySub;
  StreamSubscription<PedalEvent>? _pedalSub;
  bool _dialogOpen = false;
  bool _saveAsOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bind();
    });
  }

  void _bind() {
    final cubit = _maybeRead<PowerOffCubit>(context);
    if (cubit == null) return;
    final source = _maybeRead<PowerKeySource>(context);
    if (source != null) {
      _keySub = source.presses.listen((_) {
        if (!mounted) return;
        cubit.press(_snapshot());
      });
    }
    final pedal = _maybeRead<PedalRepository>(context);
    if (pedal != null) {
      _pedalSub = pedal.events.listen((event) {
        if (!mounted || event is! ButtonPressed) return;
        if (cubit.state.isDismissible) cubit.keepPlaying();
      });
    }
  }

  PowerOffSnapshot _snapshot() {
    return powerOffSnapshotOf(
      looper: context.read<LooperBloc>().state,
      recorder: context.read<PerformanceRecorderCubit>().state,
      session: context.read<SessionCubit>().state,
    );
  }

  Future<void> _saveNamed() async {
    final session = context.read<SessionCubit>();
    await session.save();
    if (session.state.status == SessionStatus.failure) {
      throw Exception(session.state.errorMessage ?? 'save failed');
    }
  }

  @override
  void dispose() {
    unawaited(_keySub?.cancel());
    unawaited(_pedalSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _maybeRead<PowerOffCubit>(context);
    if (cubit == null) return widget.child;
    return BlocListener<PowerOffCubit, PowerOffState>(
      listenWhen: (previous, current) => previous.phase != current.phase,
      listener: _onPhase,
      child: widget.child,
    );
  }

  void _popPowerOffRoute() {
    Navigator.of(context, rootNavigator: true).maybePop();
  }

  void _onPhase(BuildContext context, PowerOffState state) {
    switch (state.phase) {
      case PowerOffPhase.refuse:
      case PowerOffPhase.confirm:
      case PowerOffPhase.saveFailed:
        unawaited(_openDialog());
      case PowerOffPhase.saveAs:
        if (_dialogOpen) _popPowerOffRoute();
        unawaited(_openSaveAs());
      case PowerOffPhase.idle:
        if (_dialogOpen || _saveAsOpen) _popPowerOffRoute();
      case PowerOffPhase.saving:
      case PowerOffPhase.goodbye:
        if (_dialogOpen || _saveAsOpen) _popPowerOffRoute();
        context.read<LooperBloc>().add(const LooperPersistFlush());
    }
  }

  Future<void> _openDialog() async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    final cubit = context.read<PowerOffCubit>();
    await showPowerOffDialog(
      context,
      snapshot: _snapshot,
      onSave: _saveNamed,
    );
    _dialogOpen = false;
    if (!mounted) return;
    // Scrim / system back. Do not treat saveAs as a dismiss of this
    // dialog — the host pops it on the way to the rename sheet.
    switch (cubit.state.phase) {
      case PowerOffPhase.refuse:
      case PowerOffPhase.confirm:
      case PowerOffPhase.saveFailed:
        cubit.keepPlaying();
      case PowerOffPhase.idle:
      case PowerOffPhase.saveAs:
      case PowerOffPhase.saving:
      case PowerOffPhase.goodbye:
        break;
    }
  }

  Future<void> _openSaveAs() async {
    if (_saveAsOpen || !mounted) return;
    _saveAsOpen = true;
    final cubit = context.read<PowerOffCubit>();
    try {
      while (mounted && cubit.state.phase == PowerOffPhase.saveAs) {
        final l10n = context.l10n;
        final session = context.read<SessionCubit>();
        final raw = await showConsoleRenameSheet(
          context,
          title: l10n.sessionNewTitle,
          subtitle: l10n.sessionNameHint,
          current: '',
          fieldLabel: l10n.sessionNewTitle,
          useRootNavigator: true,
        );
        if (!mounted) return;
        if (cubit.state.phase != PowerOffPhase.saveAs) return;
        if (raw == null) {
          cubit.keepPlaying();
          return;
        }
        final slug = sessionSlug(raw);
        if (slug == null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: AppText(l10n.sessionNameInvalid)));
          continue;
        }
        if (session.state.sessions.any((s) => s.name == slug)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: AppText(l10n.sessionNameDuplicate(slug))),
          );
          continue;
        }
        cubit.beginSaving();
        await session.saveAs(raw);
        if (!mounted) return;
        if (cubit.state.phase != PowerOffPhase.saving) return;
        if (session.state.status == SessionStatus.failure) {
          cubit.saveFailed();
          return;
        }
        cubit.saveCompleted();
        return;
      }
    } finally {
      _saveAsOpen = false;
    }
  }
}

T? _maybeRead<T>(BuildContext context) {
  try {
    return context.read<T>();
  } on ProviderNotFoundException {
    return null;
  }
}
