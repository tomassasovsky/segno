/// The pure projections from `(LooperState × ControlState)` to
/// everything the control surfaces render: the armed set, per-track LEDs, and
/// the pedal wire frame. NOTHING here is stored — a projection cannot go
/// stale, which retires the reconciliation bug class ("redo didn't relight
/// the LED") structurally.
///
/// Debug builds assert the control-surface invariant spec on every projected
/// frame ([projectFrame]); the sequence fuzzer checks the same spec against
/// the real engine.
library;

import 'package:looper_repository/looper_repository.dart';
import 'package:pedal_repository/pedal_repository.dart';
import 'package:segno/control/binding/pedal_palette.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/invariants.dart';
import 'package:segno/control/model/foot_fade.dart';
import 'package:segno/control/model/foot_mixer.dart';
import 'package:segno/control/model/foot_peel.dart';
import 'package:segno/control/model/foot_reverse.dart';
import 'package:segno/looper/model/interaction_mode.dart';

/// Whether the play transport is PARKED: content exists but none of it is
/// running. State-based and mute-ignored — keyboard-muting every track does
/// NOT park (mute silences; only Stop freezes playheads).
bool isParked(LooperState looper) {
  var anyContent = false;
  for (final t in looper.tracks) {
    if (!t.hasContent) continue;
    anyContent = true;
    if (t.state == TrackState.playing || t.state == TrackState.overdubbing) {
      return false;
    }
  }
  return anyContent;
}

/// Whether [track] is actually sounding in the mix: unmuted recorded content
/// with a running playhead.
bool isSounding(Track track) =>
    track.hasContent &&
    !track.muted &&
    (track.state == TrackState.playing ||
        track.state == TrackState.overdubbing);

/// The mute-mode armed set, DERIVED on every read:
/// `parked ? parkedResume : sounding ∖ excluded`. A redo, an on-screen play,
/// or any future engine state is reflected the moment the snapshot changes —
/// there is no stored set to forget to update.
Set<int> armedTracks(LooperState looper, ControlState overlay) {
  if (isParked(looper)) return overlay.parkedResume;
  return {
    for (final t in looper.tracks)
      if (isSounding(t) && !overlay.excluded.contains(t.channel)) t.channel,
  };
}

/// The pedal-track LED for [channel] under the current mode.
///
/// [boundChains] carries the resolved `enabled` of every track button that
/// carries an FX binding, keyed by channel — absent means unbound, and a
/// present null means the binding no longer resolves. Handed in rather than
/// read here, because a binding meets the live rig in `FxBindingResolver` and
/// this function stays pure.
///
/// Mute mode: green = armed AND audible (a muted or excluded track reads
/// off; while parked, the parked-resume members show what Rec/Play brings
/// back). Record mode: the cursor and any capturing track read red. FX mode:
/// blue = the track's Track-stage chain is engaged. Custom mode: blue = the
/// assigned function is active, based on its current target/contact state.
///
/// The FX-mode reading costs ZERO new wire bytes (R8): the same `trackLeds`
/// enum-index byte carries a different meaning per mode, so the firmware
/// renders it verbatim with no mode branch. An ENGAGED-BUT-EMPTY chain still
/// reads blue — the LED reports the flag the stomp toggles, so every stomp
/// gives immediate, unambiguous feedback; a lit LED promises "this chain is
/// in circuit", not "this chain has effects in it".
PedalTrackLed projectTrackLed(
  LooperState looper,
  ControlState overlay,
  int channel, {
  Map<int, bool?> boundChains = const {},
  Map<int, bool> customFunctions = const {},
}) {
  final track = channel >= 0 && channel < looper.tracks.length
      ? looper.tracks[channel]
      : null;
  switch (overlay.mode) {
    case InteractionMode.mute:
      final armed = armedTracks(looper, overlay).contains(channel);
      return armed && !(track?.muted ?? false)
          ? PedalTrackLed.green
          : PedalTrackLed.off;
    case InteractionMode.record:
      if (channel == overlay.cursor) return PedalTrackLed.red;
      if (track?.isCapturing ?? false) return PedalTrackLed.red;
      return PedalTrackLed.off;
    case InteractionMode.mixer:
      return PedalTrackLed.off;
    case InteractionMode.fade:
      // Lit while fading or faded out; never a claim about audibility. Only
      // recorded tracks: Clear publishes EMPTY before its envelope reset.
      return (track != null && track.hasContent && track.fade.attenuated)
          ? PedalTrackLed.blue
          : PedalTrackLed.off;
    case InteractionMode.reverse:
      // Lit while the recorded track plays reversed. Clear publishes EMPTY
      // with the direction reset, so an empty track never reads reversed.
      return (track != null && track.hasContent && track.reversed)
          ? PedalTrackLed.blue
          : PedalTrackLed.off;
    case InteractionMode.peel:
      // Lit while a press would remove a layer, so "none remain" and a busy
      // track are visible by foot.
      return (track?.canPeel ?? false) ? PedalTrackLed.blue : PedalTrackLed.off;
    case InteractionMode.custom:
      return customFunctions[channel] ?? false
          ? PedalTrackLed.blue
          : PedalTrackLed.off;
    case InteractionMode.fx:
      // A BOUND switch reports its own target, not this channel's track chain.
      // The two are different flags — a binding can name a chain on any stage
      // or a single slot inside one — so a switch bound to an input's reverb
      // used to light from track N's chain and stay lit when you stomped it
      // off. Present-but-null is a stale binding: R25 says it lights nothing,
      // which the old reading could not honour either.
      if (boundChains.containsKey(channel)) {
        return (boundChains[channel] ?? false)
            ? PedalTrackLed.blue
            : PedalTrackLed.off;
      }
      // A channel the engine does not expose reads dark — there is no chain
      // behind it to stomp.
      if (track == null) return PedalTrackLed.off;
      return track.chainEnabled ? PedalTrackLed.blue : PedalTrackLed.off;
  }
}

/// Projects the full pedal wire frame — LEDs, ring activity color, bank,
/// cursor, mode, loop length — from engine truth and the overlay. Pure; the
/// pedal cubit diff-pushes the result, the simulator renders it.
PedalStateFrame projectFrame(
  LooperState looper,
  ControlState overlay, {
  bool clearFadeActive = false,
  bool performanceArmed = false,
  double masterGain = 1.0,
  Map<int, bool?> boundChains = const {},
  Map<int, bool> customFunctions = const {},
  Map<PedalButton, bool> physicalCustomStates = const {},
  Set<PedalButton> acceptedContacts = const {},
}) {
  final leds = <PedalTrackLed>[
    for (var channel = 0; channel < PedalStateFrame.trackCount; channel++)
      projectTrackLed(
        looper,
        overlay,
        channel,
        boundChains: boundChains,
        customFunctions: customFunctions,
      ),
  ];
  // global_color carries the ring's activity color: red while recording,
  // amber while overdubbing, green while a loop plays, off when idle. (The
  // pedal's Rec/Mute interaction mode is shown separately by the mode LED.)
  final anyRecording = looper.tracks.any(
    (t) => t.state == TrackState.recording,
  );
  final anyOverdub = looper.tracks.any(
    (t) => t.state == TrackState.overdubbing,
  );
  final anyPlaying = looper.tracks.any(
    (t) => t.state == TrackState.playing && !t.muted,
  );
  final global = anyRecording && anyPlaying
      ? GlobalColor.amber
      : anyRecording
      ? GlobalColor.red
      : anyOverdub
      ? GlobalColor.amber
      : anyPlaying
      ? GlobalColor.green
      : GlobalColor.off;
  final activeButtonMask = _physicalButtonMask(
    overlay,
    leds,
    global: global,
    performanceArmed: performanceArmed,
    clearFadeActive: clearFadeActive,
    physicalCustomStates: physicalCustomStates,
    acceptedContacts: acceptedContacts,
  );
  final sampleRate = looper.status.sampleRate;
  // The engine keeps the master grid alive after undo-to-empty (redo needs
  // it), but a pedal with no loops anywhere must not keep its ring lit —
  // render the length only while something holds or captures one.
  final anyLoop = looper.tracks.any((t) => t.hasContent || t.isCapturing);
  final lengthMicros = sampleRate > 0 && anyLoop
      ? (looper.transport.masterLengthFrames * 1000000 / sampleRate).round()
      : 0;
  final frame = PedalStateFrame(
    globalColor: global,
    trackLeds: leds,
    activeBank: overlay.activeBank,
    selectedTrack: overlay.cursor,
    // The wire frame still calls mute mode PLAY: PedalMode is the pedal
    // firmware's protocol enum (its mode LED predates the rename), so the
    // mapping — not the wire token — carries the new name. Each mode has one
    // current UART value; the codec and board require an exact v6 HELLO.
    mode: switch (overlay.mode) {
      InteractionMode.record => PedalMode.rec,
      InteractionMode.mute => PedalMode.play,
      InteractionMode.fx => PedalMode.fx,
      InteractionMode.custom ||
      InteractionMode.mixer ||
      InteractionMode.fade ||
      InteractionMode.reverse ||
      InteractionMode.peel => PedalMode.custom,
    },
    loopLengthMicros: lengthMicros.clamp(
      0,
      PedalStateFrame.maxLoopLengthMicros,
    ),
    clearFadeActive: clearFadeActive,
    performanceArmed: performanceArmed,
    masterGain: masterGain,
    pedalColors: projectPedalColors(looper, overlay, leds, global),
    activeButtonMask: activeButtonMask,
  );
  // The control-surface invariant spec runs on every projection in debug
  // builds — the same predicates the sequence fuzzer checks. assert() only:
  // zero release-mode cost.
  assert(
    debugControlInvariantsHold(
      ControlContext(
        looper: looper,
        overlay: overlay,
        frame: frame,
        boundChains: boundChains,
        customFunctions: customFunctions,
        physicalCustomStates: physicalCustomStates,
      ),
    ),
    'control-surface invariants must hold at projection time',
  );
  return frame;
}

/// The hue each footswitch lights in.
///
/// Only Custom mode takes the performer's palette, because only there is a
/// switch's function the performer's own choice. Every other mode is a fixed
/// function and lights in the state colours the screen uses: recording and
/// overdub red, playing green, an engaged FX, Fade, Reverse or Peel function
/// blue, anything else pale. Whether a switch is lit at all stays with the
/// active mask; this only answers its colour.
List<PedalColor> projectPedalColors(
  LooperState looper,
  ControlState overlay,
  List<PedalTrackLed> trackLeds,
  GlobalColor global,
) {
  if (overlay.mode == InteractionMode.custom) {
    return overlay.pedalSetup.palette.frameColors;
  }
  PedalColor trackColor(PedalButton button) {
    final channel =
        overlay.bankBaseChannel + button.index - PedalButton.track1.index;
    if (overlay.mode == InteractionMode.record) {
      // Record mode lights the selected track as well as any capturing one,
      // so the colour reports that track's own state rather than the lit
      // reason.
      final track = channel < looper.tracks.length
          ? looper.tracks[channel]
          : null;
      return switch (track?.state) {
        TrackState.recording || TrackState.overdubbing => _stateRed,
        TrackState.playing => _statePlaying,
        _ => _statePale,
      };
    }
    return switch (trackLeds[channel]) {
      PedalTrackLed.red => _stateRed,
      PedalTrackLed.green => _statePlaying,
      PedalTrackLed.blue => _stateEngaged,
      PedalTrackLed.off => _statePale,
    };
  }

  return [
    for (final button in PedalButton.values)
      switch (button) {
        PedalButton.track1 ||
        PedalButton.track2 ||
        PedalButton.track3 ||
        PedalButton.track4 => trackColor(button),
        PedalButton.recPlay => switch (global) {
          GlobalColor.red => _stateRed,
          GlobalColor.amber => _stateOverdub,
          GlobalColor.green => _statePlaying,
          GlobalColor.blue => _stateEngaged,
          GlobalColor.off => _statePale,
        },
        _ => _statePale,
      },
  ];
}

final PedalColor _stateRed = PedalPaletteColor.red.color;
final PedalColor _stateOverdub = PedalPaletteColor.orange.color;
final PedalColor _statePlaying = PedalPaletteColor.green.color;
final PedalColor _stateEngaged = PedalPaletteColor.blue.color;
final PedalColor _statePale = PedalPaletteColor.white.color;

/// Whether [button] is a slot-less pedal on a hold-less performance surface
/// (Fade, Reverse, Peel).
bool _slotless(InteractionMode mode, PedalButton button) => switch (mode) {
  InteractionMode.fade => FootFadeProjection.pedalRoles[button]!.slot == null,
  InteractionMode.reverse =>
    FootReverseProjection.pedalRoles[button]!.slot == null,
  InteractionMode.peel => FootPeelProjection.pedalRoles[button]!.slot == null,
  _ => false,
};

int _physicalButtonMask(
  ControlState overlay,
  List<PedalTrackLed> trackLeds, {
  required GlobalColor global,
  required bool performanceArmed,
  required bool clearFadeActive,
  required Map<PedalButton, bool> physicalCustomStates,
  required Set<PedalButton> acceptedContacts,
}) {
  var mask = 0;
  for (final button in PedalButton.values) {
    final lit = switch (button) {
      PedalButton.mode => overlay.mode != InteractionMode.record,
      _ when overlay.mode == InteractionMode.mixer =>
        FootMixerProjection.pedalRoles[button]!.slot != null
            ? overlay.footMixer.channel ==
                  overlay.footMixer.page * 4 +
                      FootMixerProjection.pedalRoles[button]!.slot!
            : acceptedContacts.contains(button),
      PedalButton.bank => overlay.activeBank == 1,
      // Slot-less pedals on the hold-less performance surfaces light only
      // for an accepted contact.
      _ when _slotless(overlay.mode, button) => acceptedContacts.contains(
        button,
      ),
      _ when overlay.mode == InteractionMode.custom =>
        physicalCustomStates[button] ?? false,
      PedalButton.track1 ||
      PedalButton.track2 ||
      PedalButton.track3 ||
      PedalButton.track4 =>
        trackLeds[overlay.bankBaseChannel +
                button.index -
                PedalButton.track1.index] !=
            PedalTrackLed.off,
      PedalButton.recPlay =>
        overlay.mode != InteractionMode.fx &&
            (global == GlobalColor.red ||
                global == GlobalColor.amber ||
                global == GlobalColor.green ||
                performanceArmed ||
                acceptedContacts.contains(button)),
      PedalButton.undo =>
        overlay.mode != InteractionMode.fx && acceptedContacts.contains(button),
      PedalButton.stop => acceptedContacts.contains(button),
      PedalButton.clear =>
        overlay.mode != InteractionMode.fx &&
            (clearFadeActive || acceptedContacts.contains(button)),
    };
    if (lit) mask |= 1 << button.index;
  }
  return mask;
}
