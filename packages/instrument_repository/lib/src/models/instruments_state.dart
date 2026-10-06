import 'package:equatable/equatable.dart';
import 'package:instrument_repository/src/models/working_copy.dart';
import 'package:instrument_repository/src/route_compiler.dart';

/// What the instruments page and the other surfaces read: the applied
/// definitions plus everything runtime about them.
class InstrumentsState extends Equatable {
  /// Creates an [InstrumentsState].
  const InstrumentsState({
    this.workingCopy = const InstrumentsWorkingCopy(),
    this.unavailable = const {},
    this.voices = const {},
    this.auditions = const {},
    this.drafts = const {},
    this.problems = const [],
  });

  /// The definitions the engine is driven from.
  final InstrumentsWorkingCopy workingCopy;

  /// Instruments whose sound this build does not define: the slot is silent
  /// and the definition, routes and mappings are kept.
  final Set<String> unavailable;

  /// Sounding voices per instrument id.
  final Map<String, int> voices;

  /// The sound each auditioning instrument is previewing (not saved).
  final Map<String, String> auditions;

  /// Parameter drafts per instrument id: audible, not saved.
  final Map<String, List<double>> drafts;

  /// What the routing table could not carry as defined.
  final List<RouteProblem> problems;

  @override
  List<Object?> get props => [
    workingCopy,
    unavailable,
    voices,
    auditions,
    drafts,
    problems,
  ];
}
