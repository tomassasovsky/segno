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
import 'package:segno/control/binding/pedal_binding.dart';
import 'package:segno/control/binding/pedal_led_map.dart';
import 'package:segno/control/cubit/control_cubit.dart';
import 'package:segno/control/invariants.dart';
import 'package:segno/control/model/foot_fade.dart';
import 'package:segno/control/model/foot_fx.dart';
import 'package:segno/control/model/foot_length.dart';
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

/// The Song section waiting for the playing one's next lap edge, as the
/// pedal shows it (#1077): in Song, in Mute and Record mode (a queue can start
/// from either, or from the screen), only on a track that still holds a take,
/// and `null` otherwise. The engine owns the queue; this only decides whether
/// the pedal shows it.
int? queuedSongTrack(LooperState looper, ControlState overlay) {
  final queued = looper.songWaitingSection;
  if ((overlay.mode != InteractionMode.mute &&
          overlay.mode != InteractionMode.record) ||
      queued == null ||
      queued >= PedalStateFrame.trackCount) {
    return null;
  }
  return queued;
}

/// The footswitch that shows [queuedSongTrack] and how far its pill has
/// filled, `0`..`254` of 255. No switch for a section on the other bank: its
/// pill is not on the plate.
({PedalButton? button, int progress}) queuedSongPill(
  LooperState looper,
  ControlState overlay,
) {
  final queued = queuedSongTrack(looper, overlay);
  if (queued == null || !overlay.bankContains(queued)) {
    return (button: null, progress: 0);
  }
  final progress = (looper.transport.songQueueProgress * 255).floor().clamp(
    0,
    254,
  );
  return (
    button: PedalButton
        .values[PedalButton.track1.index + queued - overlay.bankBaseChannel],
    progress: progress,
  );
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
/// back). In Song a press asks for a section instead, so the LEDs show the
/// sections that sound and the one waiting to start ([queuedSongTrack]).
/// Record mode: the cursor and any capturing track read red, except a Song
/// section waiting to start, which reads green (its pill fills) even on the
/// cursor. FX mode: blue = the track's Track-stage chain is engaged. Custom
/// mode: blue = the assigned function is active, based on its current
/// target/contact state.
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
      if (looper.transport.looperMode == LooperMode.song) {
        return channel == queuedSongTrack(looper, overlay) ||
                (track != null && isSounding(track))
            ? PedalTrackLed.green
            : PedalTrackLed.off;
      }
      final armed = armedTracks(looper, overlay).contains(channel);
      return armed && !(track?.muted ?? false)
          ? PedalTrackLed.green
          : PedalTrackLed.off;
    case InteractionMode.record:
      // A waiting Song section reads green, as in Mute mode, so its pill can
      // fill; it is never capturing (a capture refuses the queue).
      if (channel == queuedSongTrack(looper, overlay)) {
        return PedalTrackLed.green;
      }
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
    case InteractionMode.tuner:
      // The track switches pick inputs here, not tracks: their light is the
      // switch light alone (`tunerStates`).
      return PedalTrackLed.off;
    case InteractionMode.multiply:
    case InteractionMode.divide:
      // Red on the selected recorded track, the one every edit acts on (the
      // Record-mode cursor convention); an empty track is never selected.
      return (channel == overlay.cursor && track != null && track.hasContent)
          ? PedalTrackLed.red
          : PedalTrackLed.off;
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
  Map<PedalButton, FxSwitchReading> boundSwitches = const {},
  Map<int, bool> customFunctions = const {},
  Map<PedalButton, bool> physicalCustomStates = const {},
  Map<PedalButton, bool> tunerStates = const {},
  Set<PedalButton> pressed = const {},
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
  final lights = projectPedalLights(
    looper,
    overlay,
    leds,
    global: global,
    performanceArmed: performanceArmed,
    physicalCustomStates: physicalCustomStates,
    tunerStates: tunerStates,
    boundSwitches: boundSwitches,
    pressed: pressed,
  );
  var activeButtonMask = 0;
  for (final button in PedalButton.values) {
    if (lights[button.index] != null) activeButtonMask |= 1 << button.index;
  }
  final sampleRate = looper.status.sampleRate;
  // The engine keeps the master grid alive after undo-to-empty (redo needs
  // it), but a pedal with no loops anywhere must not keep its ring lit —
  // render the length only while something holds or captures one.
  final anyLoop = looper.tracks.any((t) => t.hasContent || t.isCapturing);
  final lengthMicros = sampleRate > 0 && anyLoop
      ? (looper.transport.masterLengthFrames * 1000000 / sampleRate).round()
      : 0;
  final queued = queuedSongPill(looper, overlay);
  final frame = PedalStateFrame(
    globalColor: global,
    trackLeds: leds,
    activeBank: overlay.activeBank,
    selectedTrack: overlay.cursor,
    // The wire frame still calls mute mode PLAY: PedalMode is the pedal
    // firmware's protocol enum (its mode LED predates the rename), so the
    // mapping — not the wire token — carries the new name. Each mode has one
    // current UART value; the codec and board require an exact protocol
    // version in HELLO.
    mode: switch (overlay.mode) {
      InteractionMode.record => PedalMode.rec,
      InteractionMode.mute => PedalMode.play,
      InteractionMode.fx => PedalMode.fx,
      InteractionMode.custom ||
      InteractionMode.mixer ||
      InteractionMode.fade ||
      InteractionMode.reverse ||
      InteractionMode.peel ||
      InteractionMode.tuner => PedalMode.custom,
      InteractionMode.multiply || InteractionMode.divide => PedalMode.custom,
    },
    loopLengthMicros: lengthMicros.clamp(
      0,
      PedalStateFrame.maxLoopLengthMicros,
    ),
    clearFadeActive: clearFadeActive,
    performanceArmed: performanceArmed,
    masterGain: masterGain,
    pedalColors: [
      for (final button in PedalButton.values)
        _colorOf(overlay, button, lights[button.index]),
    ],
    activeButtonMask: activeButtonMask,
    queuedButton: queued.button,
    queuedProgress: queued.progress,
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
        pressed: pressed,
      ),
    ),
    'control-surface invariants must hold at projection time',
  );
  return frame;
}

/// What each footswitch is showing, indexed by [PedalButton.index]: the
/// state it lights for, or `null` when it is dark.
///
/// A held pedal reads [PedalLedState.pressed] whatever else it shows, MODE
/// included. [pressed] is the cubit's set of held contacts, updated on the
/// press event itself and projected in the same call, so the light never waits
/// for the engine to answer.
List<PedalLedState?> projectPedalLights(
  LooperState looper,
  ControlState overlay,
  List<PedalTrackLed> trackLeds, {
  required GlobalColor global,
  bool performanceArmed = false,
  Map<PedalButton, bool> physicalCustomStates = const {},
  Map<PedalButton, bool> tunerStates = const {},
  Map<PedalButton, FxSwitchReading> boundSwitches = const {},
  Set<PedalButton> pressed = const {},
}) {
  final mode = overlay.mode;
  // Rec/Play reports the loop whatever lit it: a take, a playing loop, or
  // nothing running.
  PedalLedState loopState() => switch (global) {
    // Amber is overdub, or a new take over playing loops: both record.
    GlobalColor.red || GlobalColor.amber => PedalLedState.recording,
    GlobalColor.green => PedalLedState.playing,
    GlobalColor.blue || GlobalColor.off => PedalLedState.idle,
  };
  PedalLedState? trackState(PedalButton button) {
    final channel =
        overlay.bankBaseChannel + button.index - PedalButton.track1.index;
    if (trackLeds[channel] == PedalTrackLed.off) return null;
    // A waiting Song section lights as the playing section it is about to
    // become, in Record mode too, so its pill fills in that colour (#1077).
    if (mode == InteractionMode.record &&
        channel == queuedSongTrack(looper, overlay)) {
      return PedalLedState.playing;
    }
    return switch (mode) {
      // Record lights the selected track as well as any capturing one, so
      // the state is that track's own rather than the lit reason.
      InteractionMode.record => switch (channel < looper.tracks.length
          ? looper.tracks[channel].state
          : null) {
        TrackState.recording => PedalLedState.recording,
        TrackState.overdubbing => PedalLedState.overdubbing,
        TrackState.playing => PedalLedState.playing,
        _ => PedalLedState.selected,
      },
      InteractionMode.mute => PedalLedState.armed,
      InteractionMode.fx => PedalLedState.engaged,
      InteractionMode.fade => PedalLedState.fading,
      InteractionMode.reverse => PedalLedState.reversed,
      InteractionMode.peel => PedalLedState.peelable,
      InteractionMode.multiply ||
      InteractionMode.divide ||
      InteractionMode.mixer => PedalLedState.selected,
      InteractionMode.tuner => PedalLedState.tuned,
      InteractionMode.custom => PedalLedState.lit,
    };
  }

  PedalLedState? state(PedalButton button) => switch (button) {
    _ when pressed.contains(button) => PedalLedState.pressed,
    // Always lit, in the mode's own colour, as the pedal always was.
    PedalButton.mode => PedalLedState.current,
    // The Tuner face's own lights: the tuned input, Stop while muted, Bank
    // past the first page.
    _ when mode == InteractionMode.tuner =>
      (tunerStates[button] ?? false)
          ? switch (button) {
              PedalButton.stop => PedalLedState.muted,
              PedalButton.bank => PedalLedState.laterBank,
              _ => PedalLedState.tuned,
            }
          : null,
    _ when mode == InteractionMode.mixer =>
      FootMixerProjection.pedalRoles[button]!.slot != null &&
              overlay.footMixer.channel ==
                  overlay.footMixer.page * 4 +
                      FootMixerProjection.pedalRoles[button]!.slot!
          ? PedalLedState.selected
          : null,
    PedalButton.bank =>
      overlay.activeBank == 1 ? PedalLedState.laterBank : null,
    // Slot-less pedals on the hold-less performance surfaces light only
    // while held.
    _ when _slotless(mode, button) => null,
    _ when mode == InteractionMode.custom =>
      (physicalCustomStates[button] ?? false) ? PedalLedState.lit : null,
    // FX mode (#1229): Rec/Play, Stop, Undo and Clear light only for what
    // their binding drives, as their face does; unbound they are inert and
    // dark, as pen 10/03 draws them.
    PedalButton.recPlay ||
    PedalButton.stop ||
    PedalButton.undo ||
    PedalButton.clear when mode == InteractionMode.fx =>
      (boundSwitches[button]?.lit ?? false)
          ? (button == PedalButton.recPlay
                ? loopState()
                : PedalLedState.engaged)
          : null,
    PedalButton.track1 ||
    PedalButton.track2 ||
    PedalButton.track3 ||
    PedalButton.track4 => trackState(button),
    PedalButton.recPlay =>
      global != GlobalColor.off || performanceArmed ? loopState() : null,
    PedalButton.undo || PedalButton.stop || PedalButton.clear => null,
  };

  return [for (final button in PedalButton.values) state(button)];
}

/// The colour [button] lights in for [state]: the mode's colour map, or the
/// pedal's own assignment colour for a Custom-assignable switch in Custom
/// mode. A dark pedal carries its group's first colour, which the board
/// does not show.
PedalColor _colorOf(
  ControlState overlay,
  PedalButton button,
  PedalLedState? state,
) {
  final colors = overlay.pedalSetup.leds;
  if (overlay.mode == InteractionMode.custom &&
      !PedalBindingKey.unbindable.contains(button)) {
    return colors.customColorFor(
      PedalBindingKey(
        button: button,
        bank: PedalBindingKey.isBankKeyed(button) ? overlay.activeBank : null,
      ),
      state ?? PedalLedState.lit,
    );
  }
  final group = PedalLedMap.groupOf(button);
  return colors.colorFor(
    overlay.mode,
    group,
    state ?? PedalLedMap.schema(overlay.mode)[group]!.keys.first,
  );
}

/// Whether [button] is a slot-less pedal on a hold-less performance surface
/// (Fade, Reverse, Peel, Multiply / Divide).
bool _slotless(InteractionMode mode, PedalButton button) => switch (mode) {
  InteractionMode.fade => FootFadeProjection.pedalRoles[button]!.slot == null,
  InteractionMode.reverse =>
    FootReverseProjection.pedalRoles[button]!.slot == null,
  InteractionMode.peel => FootPeelProjection.pedalRoles[button]!.slot == null,
  InteractionMode.multiply || InteractionMode.divide =>
    FootLengthProjection.rolesFor(mode)[button]!.slot == null,
  _ => false,
};
