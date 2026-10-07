import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/appliance/power_off/power_cubit.dart';
import 'package:segno/appliance/power_off/power_dialog.dart';
import 'package:segno/appliance/power_off/power_gate.dart';
import 'package:segno/appliance/power_off/power_key_source.dart';
import 'package:segno/common/console_rename_sheet.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/bloc/looper_bloc.dart';
import 'package:segno/performance/cubit/performance_recorder_cubit.dart';
import 'package:segno/session/cubit/session_cubit.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/update_cubit.dart';
import 'package:session_repository/session_repository.dart';
import 'package:storage_repository/storage_repository.dart';

/// What the power gate needs to know about the rig right now, read from the
/// app-wide owners above [context].
PowerSnapshot currentPowerSnapshot(BuildContext context) => powerSnapshotOf(
  looper: context.read<LooperBloc>().state,
  recorder: context.read<PerformanceRecorderCubit>().state,
  session: context.read<SessionCubit>().state,
  // Asked of the repository at the press: a lease can be taken between two
  // of the Storage page's reads.
  transferInFlight:
      _maybeRead<StorageRepository>(context)?.transferInFlight ?? false,
);

/// Saves the open named session through [SessionCubit], throwing when the
/// save did not land so the power flow stays on.
Future<void> Function() saveOpenSession(BuildContext context) {
  final session = context.read<SessionCubit>();
  return () async {
    await session.save();
    if (session.state.status == SessionStatus.failure) {
      throw Exception(session.state.errorMessage ?? 'save failed');
    }
  };
}

/// Opens Power options exactly as a short press of the rear power button
/// does; [PowerHost] presents it.
void requestPower(BuildContext context) =>
    context.read<PowerCubit>().press(currentPowerSnapshot(context));

/// Restarts through the one guarded path (save first), for an update's
/// Install and restart, which has asked already.
void requestRestart(BuildContext context) => context.read<PowerCubit>().restart(
  currentPowerSnapshot(context),
  save: saveOpenSession(context),
);

/// The staged update's version, which a restart installs; null when none is
/// staged or no update owner is mounted.
String? _stagedUpdate(BuildContext context) {
  final update = _maybeRead<UpdateCubit>(context)?.state;
  if (update == null || update.phase != UpdatePhase.staged) return null;
  return update.available?.version.toString();
}

/// Listens for the rear power button, shows Power options, and runs Save As.
///
/// Mounted under LooperPage so it can read SessionCubit and the app-wide
/// [LooperBloc]. [PowerCubit] itself is provided app-wide. Silent when
/// either is missing (widget tests that pump the page without the cubit).
class PowerHost extends StatefulWidget {
  /// Creates a [PowerHost] wrapping [child].
  const PowerHost({required this.child, super.key});

  /// The rest of the looper page.
  final Widget child;

  @override
  State<PowerHost> createState() => _PowerHostState();
}

class _PowerHostState extends State<PowerHost> {
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
    final cubit = _maybeRead<PowerCubit>(context);
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
        cubit.dismiss();
      });
    }
  }

  PowerSnapshot _snapshot() => currentPowerSnapshot(context);

  @override
  void dispose() {
    unawaited(_keySub?.cancel());
    unawaited(_pedalSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _maybeRead<PowerCubit>(context);
    if (cubit == null) return widget.child;
    return BlocListener<PowerCubit, PowerState>(
      listenWhen: (previous, current) => previous.phase != current.phase,
      listener: _onPhase,
      child: widget.child,
    );
  }

  /// Pops the Save As sheet and the dialog (by route name) so two maybePops
  /// in one frame cannot both hit the sheet and leave the dialog up.
  void _dismissPowerRoutes() {
    _dialogOpen = false;
    _saveAsOpen = false;
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).popUntil((route) {
      final name = route.settings.name;
      return name != powerDialogRoute && name != powerSaveAsRoute;
    });
  }

  void _onPhase(BuildContext context, PowerState state) {
    switch (state.phase) {
      case PowerPhase.refuse:
      case PowerPhase.options:
      case PowerPhase.saveFailed:
        unawaited(_openDialog());
      case PowerPhase.saving:
        break;
      case PowerPhase.saveAs:
        unawaited(_openSaveAs());
      case PowerPhase.idle:
      case PowerPhase.goodbye:
        _dismissPowerRoutes();
    }
  }

  Future<void> _openDialog() async {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    final cubit = context.read<PowerCubit>();
    await showPowerDialog(
      context,
      snapshot: _snapshot,
      save: saveOpenSession(context),
      stagedUpdate: _stagedUpdate(context),
    );
    if (!mounted) return;
    _dialogOpen = false;
    // Scrim / system back. idle / goodbye already popped this route; the
    // committed phases are not dismissible, so dismiss is a no-op there.
    cubit.dismiss();
  }

  Future<void> _openSaveAs() async {
    if (_saveAsOpen || !mounted) return;
    _saveAsOpen = true;
    final cubit = context.read<PowerCubit>();
    try {
      while (mounted && cubit.state.phase == PowerPhase.saveAs) {
        final l10n = context.l10n;
        final session = context.read<SessionCubit>();
        final raw = await showConsoleRenameSheet(
          context,
          title: l10n.sessionNewTitle,
          subtitle: l10n.sessionNameHint,
          current: '',
          fieldLabel: l10n.sessionNewTitle,
          useRootNavigator: true,
          routeSettings: const RouteSettings(name: powerSaveAsRoute),
        );
        if (!mounted) return;
        if (cubit.state.phase != PowerPhase.saveAs) return;
        // Sheet has returned — do not maybePop an unrelated root route.
        if (raw == null) {
          _saveAsOpen = false;
          cubit.dismiss();
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
        _saveAsOpen = false;
        cubit.commitSaveAs(
          _snapshot(),
          save: () async {
            await session.saveAs(raw);
            if (session.state.status == SessionStatus.failure) {
              throw Exception(session.state.errorMessage ?? 'save failed');
            }
          },
        );
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
