import 'package:operation_guards/operation_guards.dart';

/// Work in flight that holds `PerformanceRepository.arm` off until it ends.
enum PerformanceArmBusy {
  /// A take is being finalized: a live take after its disarm, or one a crash
  /// left behind being recovered (and converted from raw, #1078).
  finalizing,

  /// A take's stems are rendering in the engine's one render slot.
  rendering,
}

/// Why `PerformanceRepository.arm` did not start a take (#1633). The
/// repository publishes every refusal on `armRefusals`, whoever pressed
/// (the recorder, a pedal, a MIDI control), so one listener can say why.
sealed class PerformanceArmRefusal {
  const new();
}

/// Refused because [busy] is still in flight. Capture is available again
/// when it ends.
final class PerformanceArmBusyRefusal extends PerformanceArmRefusal {
  /// Creates a [PerformanceArmBusyRefusal] for [busy].
  const new(this.busy);

  /// The work holding the arm off.
  final PerformanceArmBusy busy;
}

/// Refused at the arm's commit by the guard table: [refusal] names the
/// operation in flight (accepted behaviour 6.12).
final class PerformanceArmGuardRefusal extends PerformanceArmRefusal {
  /// Creates a [PerformanceArmGuardRefusal] for [refusal].
  const new(this.refusal);

  /// What the guard table refused the take with.
  final GuardRefused refusal;
}
