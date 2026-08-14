import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:segno/common/console_surface.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/theme/theme.dart';
import 'package:segno/update/cubit/pedal_firmware_cubit.dart';
import 'package:update_repository/update_repository.dart';

/// Covers [child] while the pedal's firmware is being flashed.
///
/// The cover is the point. Programming leaves the pedal in its bootloader with
/// dead footswitches and a dark ring for the duration; a user left in the
/// looper reads that as broken hardware, not as an update in progress. So the
/// looper is not merely obscured, it is unreachable until the flash resolves.
///
/// Nothing is drawn while the answer is still being fetched, so the ordinary
/// case — desktop, or a console with nothing to flash — never flickers a screen
/// the user did not need to see.
class PedalFirmwareGate extends StatelessWidget {
  /// Creates a [PedalFirmwareGate] over [child].
  const PedalFirmwareGate({required this.child, super.key});

  /// The looper, shown once no flash is pending.
  final Widget child;

  /// The pen's scrim for these two screens (`firmware-gate` /
  /// `firmware-failed`): `#08080adb`, deliberately denser than
  /// [SurfaceTheme.scrim] — an ordinary dialog leaves the console readable
  /// behind it, but here the console is *blocked*, and the mockups darken it
  /// to say so.
  static const Color barrierColor = Color(0xDB08080A);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PedalFirmwareCubit, PedalFirmwareState>(
      builder: (context, state) {
        if (!state.blocksLooper) return child;
        return Stack(
          children: [
            child,
            const Positioned.fill(
              child: ModalBarrier(
                key: Key('pedal_firmware_gate_barrier'),
                dismissible: false,
                color: barrierColor,
              ),
            ),
            // The gate wraps the looper from `home:`, so it sits ABOVE the
            // Scaffold and has no Material ancestor of its own — text fell
            // back to the debug style and the button had nothing to paint on.
            // Transparent so the barrier behind it still shows through.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: _GateBody(state: state),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The two faces of the gate, from the pen's `SESSION & CAPTURE` drawings:
/// `firmware-gate` (progress ring, title, body) and `firmware-failed`
/// (title, body, Continue in the accent). Both sit in the console's dialog
/// shell at the pen's 552 width, all copy centred.
class _GateBody extends StatelessWidget {
  const _GateBody({required this.state});

  final PedalFirmwareState state;

  /// Panel width, as both pen drawings set it.
  static const double _width = 552;

  /// The pen's progress ring: 31px across, 2px of stroke.
  static const double _ringSize = 31;
  static const double _ringStroke = 2;

  /// The failed body branches on how far the flash got (#670): the comforting
  /// "still works on its previous firmware" is only TRUE when the write never
  /// began. Anything else — including an unknown class — gets the honest
  /// interrupted copy: once avrdude was handed the bootloader port, the pedal
  /// may be parked in Caterina with the old firmware already gone.
  String _failedBody(AppLocalizations l10n) =>
      state.failureClass == PedalFlashFailureClass.notStarted
      ? l10n.pedalFirmwareGateFailedBody
      : l10n.pedalFirmwareGateFailedInterruptedBody;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final surface = context.surface;
    final failed = state.stage == PedalFirmwareStage.failed;

    final titleStyle = TextStyle(
      color: surface.textPrimary,
      fontSize: 20,
      height: 1.15,
      fontWeight: FontWeight.w600,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final bodyStyle = TextStyle(
      color: surface.textSecondary,
      fontSize: 16,
      height: 1.55,
      leadingDistribution: TextLeadingDistribution.even,
    );

    return Center(
      child: SingleChildScrollView(
        child: ConsoleDialogShell(
          key: const Key('pedal_firmware_gate'),
          width: _width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!failed) ...[
                Center(
                  child: SizedBox(
                    width: _ringSize,
                    height: _ringSize,
                    child: CircularProgressIndicator(
                      key: const Key('pedal_firmware_gate_progress'),
                      // Determinate from the first frame: the helper reports
                      // PROGRESS from 0, and a ring that sits still is more
                      // honest than a spinner about a flash that takes
                      // seconds, not milliseconds.
                      value: state.progress,
                      strokeWidth: _ringStroke,
                      backgroundColor: surface.borderStrong,
                      color: surface.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 17),
              ],
              AppText(
                failed
                    ? l10n.pedalFirmwareGateFailedTitle
                    : l10n.pedalFirmwareGateTitle,
                textAlign: TextAlign.center,
                style: titleStyle,
              ),
              const SizedBox(height: 12),
              AppText(
                failed
                    ? _failedBody(l10n)
                    : l10n.pedalFirmwareGateBody(
                        state.version ?? '',
                      ),
                textAlign: TextAlign.center,
                style: bodyStyle,
              ),
              if (failed) ...[
                const SizedBox(height: 19),
                Center(
                  child: ConsoleDialogButton(
                    key: const Key('pedal_firmware_gate_continue'),
                    label: l10n.pedalFirmwareGateContinue,
                    tone: ConsoleDialogTone.accent,
                    onPressed: context.read<PedalFirmwareCubit>().dismiss,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
