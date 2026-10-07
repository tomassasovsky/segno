import 'package:equatable/equatable.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/tuner/application/tuner_settings.dart';

/// The foot Tuner's transient choices while the mode is up (#1229): which
/// page of inputs the track switches show, and whether the tuned input is
/// muted. Never stored.
class FootTunerSelection extends Equatable {
  /// Creates a selection.
  const FootTunerSelection({this.page = 0, this.muted = true});

  /// The page of four tunable inputs the track switches show.
  final int page;

  /// Whether the tuned input (and its pair partner) is silent.
  final bool muted;

  /// Returns a copy with the given fields replaced.
  FootTunerSelection copyWith({int? page, bool? muted}) =>
      FootTunerSelection(page: page ?? this.page, muted: muted ?? this.muted);

  @override
  List<Object?> get props => [page, muted];
}

/// Why a foot Tuner press changed nothing. Every one says so.
enum FootTunerRefusal {
  /// The reference is already at 420 or 460 Hz.
  limit,

  /// A reference or input preference could not be saved.
  saveFailed,

  /// The engine refused to arm the tuner or mute the input.
  armFailed,
}

/// What one switch does on the Tuner face (pen 23/x).
enum FootTunerRole {
  /// Tunes the input in this position of the page.
  input,

  /// Mutes or unmutes the tuned input (Stop).
  mute,

  /// Lowers the A4 reference by 1 Hz; Hold resets it to 440 (Undo).
  referenceDown,

  /// Raises the A4 reference by 1 Hz; Hold resets it to 440 (Clear).
  referenceUp,

  /// Shows the next four inputs (Bank).
  nextPage,

  /// Back to Tracks (MODE).
  exit,

  /// Nothing in this mode (Record / Play).
  none,
}

/// One switch on the Tuner face.
class FootTunerPedal extends Equatable {
  /// Creates one switch's read.
  const FootTunerPedal({
    required this.button,
    required this.role,
    this.input,
    this.lit = false,
    this.available = true,
  });

  /// The physical switch.
  final PedalButton button;

  /// What it does.
  final FootTunerRole role;

  /// The hardware input an [FootTunerRole.input] switch tunes, or null past
  /// the last input.
  final int? input;

  /// Whether its LED is lit.
  final bool lit;

  /// Whether a press does anything. False past the last input, for Bank with
  /// one page, and for Record / Play: dimmed and silent, since nothing is
  /// there to refuse.
  final bool available;

  @override
  List<Object?> get props => [button, role, input, lit, available];
}

/// The Tuner face and the inputs it reaches.
class FootTunerProjection extends Equatable {
  /// Creates a complete projection.
  const FootTunerProjection({
    required this.inputs,
    required this.page,
    required this.source,
    required this.muted,
    required this.mutedInputs,
    required this.referenceHz,
    required this.pedals,
  });

  /// The tunable hardware inputs, in order: the device's inputs minus its
  /// loopback captures.
  final List<int> inputs;

  /// The page of four the track switches show, within [pageCount].
  final int page;

  /// The input being tuned, or `-1` when nothing is tunable.
  final int source;

  /// Whether the tuned input is muted.
  final bool muted;

  /// The inputs silenced while the tuner is up: [source] and its pair
  /// partner when [muted], else none.
  final Set<int> mutedInputs;

  /// The A4 reference in Hz.
  final int referenceHz;

  /// All ten switches.
  final Map<PedalButton, FootTunerPedal> pedals;

  /// Inputs per page: one per track switch.
  static const int pageSize = 4;

  /// How many pages of inputs there are (at least one).
  int get pageCount =>
      inputs.isEmpty ? 1 : (inputs.length + pageSize - 1) ~/ pageSize;

  /// The inputs on [page].
  List<int> get pageInputs =>
      inputs.skip(page * pageSize).take(pageSize).toList();

  /// Whether anything can be tuned.
  bool get hasSource => source >= 0;

  /// The read of [button].
  FootTunerPedal operator [](PedalButton button) => pedals[button]!;

  /// The page that holds [input], or 0.
  static int pageOf(List<int> inputs, int input) {
    final index = inputs.indexOf(input);
    return index < 0 ? 0 : index ~/ pageSize;
  }

  @override
  List<Object?> get props => [
    inputs,
    page,
    source,
    muted,
    mutedInputs,
    referenceHz,
    pedals,
  ];
}

/// The tunable inputs of [looper]'s device: `0..inputChannels-1` minus the
/// loopback captures in `excludedInputMask`.
List<int> tunableInputs(LooperState looper) {
  final status = looper.status;
  return [
    for (var input = 0; input < status.inputChannels; input++)
      if (status.excludedInputMask & (1 << input) == 0) input,
  ];
}

/// The input the tuner listens to: the stored [preferred] input when it is
/// tunable, else the first tunable one, else `-1`.
int tunerSource(List<int> inputs, int preferred) {
  if (inputs.contains(preferred)) return preferred;
  return inputs.isEmpty ? -1 : inputs.first;
}

/// Projects the Tuner face from the rig, the transient [selection] and the
/// stored [preferences] (pen 23/x, `tuner-performance-study.js`). Pure.
FootTunerProjection projectFootTuner(
  LooperState looper,
  FootTunerSelection selection,
  TunerPreferences preferences,
) {
  final inputs = tunableInputs(looper);
  final source = tunerSource(inputs, preferences.input);
  final pageCount = inputs.isEmpty
      ? 1
      : (inputs.length + FootTunerProjection.pageSize - 1) ~/
            FootTunerProjection.pageSize;
  final page = selection.page.clamp(0, pageCount - 1);
  final onPage = inputs
      .skip(page * FootTunerProjection.pageSize)
      .take(FootTunerProjection.pageSize)
      .toList();
  final muted = selection.muted && source >= 0;
  final mutedInputs = <int>{};
  if (muted) {
    mutedInputs.add(source);
    final lower = looper.inputSetup.pairOf(source);
    if (lower != null) {
      mutedInputs
        ..add(lower)
        ..add(lower + 1);
    }
  }
  FootTunerPedal read(PedalButton button) {
    switch (button) {
      case PedalButton.mode:
        return FootTunerPedal(
          button: button,
          role: FootTunerRole.exit,
          lit: true,
        );
      case PedalButton.recPlay:
        return FootTunerPedal(
          button: button,
          role: FootTunerRole.none,
          available: false,
        );
      case PedalButton.stop:
        return FootTunerPedal(
          button: button,
          role: FootTunerRole.mute,
          lit: muted,
          available: source >= 0,
        );
      case PedalButton.undo:
        return FootTunerPedal(
          button: button,
          role: FootTunerRole.referenceDown,
        );
      case PedalButton.clear:
        return FootTunerPedal(
          button: button,
          role: FootTunerRole.referenceUp,
        );
      case PedalButton.bank:
        return FootTunerPedal(
          button: button,
          role: FootTunerRole.nextPage,
          lit: page > 0,
          available: pageCount > 1,
        );
      case PedalButton.track1 ||
          PedalButton.track2 ||
          PedalButton.track3 ||
          PedalButton.track4:
        final slot = button.index - PedalButton.track1.index;
        final input = slot < onPage.length ? onPage[slot] : null;
        return FootTunerPedal(
          button: button,
          role: FootTunerRole.input,
          input: input,
          lit: input != null && input == source,
          available: input != null,
        );
    }
  }

  return FootTunerProjection(
    inputs: List.unmodifiable(inputs),
    page: page,
    source: source,
    muted: muted,
    mutedInputs: Set.unmodifiable(mutedInputs),
    referenceHz: preferences.referenceHz,
    pedals: Map.unmodifiable({
      for (final button in PedalButton.values) button: read(button),
    }),
  );
}
