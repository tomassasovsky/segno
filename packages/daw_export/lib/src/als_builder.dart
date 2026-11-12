import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daw_export/src/daw_project.dart';
import 'package:daw_export/src/live_set_template.dart';
import 'package:xml/xml.dart';

/// The time of the event Live writes first in every envelope: it holds the
/// parameter's value before the song starts.
const double _kBeforeSongTime = -63072000;

/// Where Live's Arrangement lane chooser finds a track's mixer envelopes,
/// as Live 12.2.7 numbers them for an audio track with no devices and no
/// sends: device 1 is the Mixer, and its envelope 0 is the activator
/// ("Speaker On") and 2 the volume.
const int _kLaneMixerDevice = 1;
const Map<AutomationTarget, int> _kLaneMixerEnvelope = {
  AutomationTarget.activator: 0,
  AutomationTarget.volume: 2,
};

/// Live's `WarpMode` number for Re-Pitch, which at the clip's own tempo plays
/// the file's samples unchanged.
const int _kWarpModeRePitch = 3;

/// Builds an Ableton Live 12 `.als` set (gzipped XML) from [project].
///
/// The set is [liveSetTemplate], a set Live 12 saved, with its one audio
/// track used as the prototype for every track in [project]: the template
/// supplies every element and default Live writes, and this function only
/// fills in names, clips, automation and tempo. Each copy of the prototype
/// gets fresh automation and modulation target ids, numbered on from the
/// template's `NextPointeeId`.
///
/// - Arrangement clips are unwarped: each plays its file at its own speed
///   whatever the set's tempo, so a capture sounds as it was played.
/// - Session clips loop their whole file, warped in Re-Pitch with warp
///   markers at the file's own length in beats at the set's tempo, so at
///   that tempo they too play the file unchanged. Live only loops a warped
///   clip.
/// - Every `FileRef` is relative to the set's folder, so the capture folder
///   can be moved or copied anywhere. An absolute path throws
///   [ArgumentError].
/// - The set opens in the Arrangement.
///
/// Throws [ArgumentError] for a project with no tracks, which Live cannot
/// open.
Uint8List buildAls(DawProject project) {
  if (project.tracks.isEmpty) {
    // Live refuses such a set: "Set has no player tracks".
    throw ArgumentError.value(project, 'project', 'has no tracks');
  }
  final document = XmlDocument.parse(liveSetTemplate);
  final liveSet = document.rootElement.getElement('LiveSet')!;
  final prototype = _TrackPrototype.take(liveSet);
  final nextPointeeId = liveSet.getElement('NextPointeeId')!;
  final ids = _PointeeIds(_intValue(nextPointeeId));

  var sceneCount = 1;
  for (final track in project.tracks) {
    for (final clip in track.sessionClips) {
      if (clip.laneIndex + 1 > sceneCount) sceneCount = clip.laneIndex + 1;
    }
  }
  sceneCount = _ensureListLength(
    liveSet.getElement('Scenes')!,
    'Scene',
    sceneCount,
  );

  final tracks = liveSet.getElement('Tracks')!;
  for (var i = 0; i < project.tracks.length; i++) {
    tracks.children.add(
      prototype.build(
        project.tracks[i],
        trackId: prototype.trackId + i,
        sceneCount: sceneCount,
        tempoBpm: project.tempoBpm,
        ids: ids,
      ),
    );
  }

  _setTempo(liveSet, project.tempoBpm);
  _setValue(nextPointeeId, '${ids.next}');
  _setValue(liveSet.getElement('SelectedDocumentViewInMainWindow')!, '0');
  _zoomToFit(liveSet, project);
  // Automation Mode draws each track's envelopes over its clips.
  final automated = project.tracks.any((t) => t.automationLanes.isNotEmpty);
  _setValue(liveSet.getElement('AutomationMode')!, '$automated');

  final xml = document.toXmlString();
  return Uint8List.fromList(GZipCodec().encode(utf8.encode(xml)));
}

/// Converts [seconds] to beats at [bpm].
double secondsToBeats(double seconds, double bpm) => seconds * bpm / 60;

/// Hands out pointee ids (automation and modulation targets), each one
/// higher than the last.
class _PointeeIds {
  new(this.next);

  int next;

  int take() => next++;
}

/// The template's audio track with its clips and envelopes taken out, plus
/// one of each as the prototype for the clips and envelopes a track gets.
class _TrackPrototype {
  new _(this.track, this.clip, this.envelope, this.lane, this.trackId);

  /// Removes the template's only audio track from [liveSet] and splits it
  /// into an empty track, its Arrangement clip and its first envelope.
  factory take(XmlElement liveSet) {
    final track =
        liveSet.getElement('Tracks')!.findElements('AudioTrack').single
          ..remove();
    final events = _arrangerEvents(track);
    final clip = events.findElements('AudioClip').first.copy();
    events.children.clear();
    for (final slot in _clipSlotValues(track)) {
      slot.children.clear();
    }
    final envelopes = _envelopes(track);
    final envelope = envelopes.findElements('AutomationEnvelope').first.copy();
    envelopes.children.clear();
    final lane = _automationLanes(track)
        .findElements('AutomationLane')
        .first
        .copy();
    return _TrackPrototype._(
      track,
      clip,
      envelope,
      lane,
      int.parse(track.getAttribute('Id')!),
    );
  }

  final XmlElement track;
  final XmlElement clip;
  final XmlElement envelope;
  final XmlElement lane;
  final int trackId;

  /// Shows one Arrangement lane per envelope [source] has, so its
  /// automation is visible when the set opens. A track without automation
  /// keeps the template's single lane.
  void _showLanes(XmlElement track, DawTrack source) {
    final targets = [
      for (final target in AutomationTarget.values)
        if (_laneFor(source, target) != null) target,
    ];
    if (targets.isEmpty) return;
    _automationLanes(track).children
      ..clear()
      ..addAll([
        for (var i = 0; i < targets.length; i++)
          (lane.copy()..setAttribute('Id', '$i'))
            ..getElement('SelectedDevice')!
                .setAttribute('Value', '$_kLaneMixerDevice')
            ..getElement('SelectedEnvelope')!
                .setAttribute('Value', '${_kLaneMixerEnvelope[targets[i]]}'),
      ]);
  }

  XmlElement build(
    DawTrack source, {
    required int trackId,
    required int sceneCount,
    required double tempoBpm,
    required _PointeeIds ids,
  }) {
    final track = this.track.copy()..setAttribute('Id', '$trackId');
    for (final element in track.descendantElements) {
      if (_isPointee(element.name.local)) {
        element.setAttribute('Id', '${ids.take()}');
      }
    }

    final name = track.getElement('Name')!;
    _setValue(name.getElement('EffectiveName')!, source.name);
    _setValue(name.getElement('UserName')!, source.name);

    final deviceChain = track.getElement('DeviceChain')!;
    for (final sequencer in ['MainSequencer', 'FreezeSequencer']) {
      _ensureListLength(
        deviceChain.getElement(sequencer)!.getElement('ClipSlotList')!,
        'ClipSlot',
        sceneCount,
      );
    }

    final arrangement = source.arrangementClip;
    if (arrangement != null) {
      _arrangerEvents(track).children.add(
        _clip(
          id: 0,
          startBeats: secondsToBeats(arrangement.startSeconds, tempoBpm),
          audio: arrangement.audio,
          name: source.name,
          tempoBpm: tempoBpm,
          loop: false,
        ),
      );
    }

    final slots = _clipSlotValues(track).toList();
    for (final session in source.sessionClips) {
      slots[session.laneIndex].children.add(
        _clip(
          id: 0,
          startBeats: 0,
          audio: session.audio,
          name: '${source.name} / Lane ${session.laneIndex}',
          tempoBpm: tempoBpm,
          loop: true,
        ),
      );
    }

    final mixer = deviceChain.getElement('Mixer')!;
    final envelopes = _envelopes(track);
    for (final target in AutomationTarget.values) {
      final lane = _laneFor(source, target);
      if (lane == null) continue;
      final parameter = mixer.getElement(switch (target) {
        AutomationTarget.volume => 'Volume',
        AutomationTarget.activator => 'Speaker',
      })!;
      envelopes.children.add(
        _envelope(
          id: envelopes.childElements.length,
          pointeeId: parameter
              .getElement('AutomationTarget')!
              .getAttribute('Id')!,
          lane: lane,
          range: target == AutomationTarget.volume ? _range(parameter) : null,
        ),
      );
    }
    _showLanes(track, source);
    return track;
  }

  /// An envelope for [lane] on the parameter whose automation target is
  /// [pointeeId], opening with the value before the song starts, as every
  /// envelope Live writes does. Volume values are clamped to [range], the
  /// Volume parameter's own; the activator is a switch and has none.
  XmlElement _envelope({
    required int id,
    required String pointeeId,
    required AutomationLane lane,
    required (double, double)? range,
  }) {
    final isBool = lane.target == AutomationTarget.activator;
    String value(double v) {
      if (isBool) return '${v != 0}';
      final (min, max) = range!;
      return _number(v < min ? min : (v > max ? max : v));
    }

    // Live ramps between consecutive events, the one before the song
    // included, so the value at arm is held to the song's start with an
    // event at 0, as Live's own sets do.
    final points = [
      (_kBeforeSongTime, lane.initialValue),
      if (lane.breakpoints.first.beat > 0) (0.0, lane.initialValue),
      for (final b in lane.breakpoints) (b.beat, b.value),
    ];
    final envelope = this.envelope.copy()..setAttribute('Id', '$id');
    _setValue(
      envelope.getElement('EnvelopeTarget')!.getElement('PointeeId')!,
      pointeeId,
    );
    envelope.getElement('Automation')!.getElement('Events')!.children
      ..clear()
      ..addAll([
        for (var i = 0; i < points.length; i++)
          _element(isBool ? 'BoolEvent' : 'FloatEvent', {
            'Id': '$i',
            'Time': _number(points[i].$1),
            'Value': value(points[i].$2),
          }),
      ]);
    return envelope;
  }

  XmlElement _clip({
    required int id,
    required double startBeats,
    required DawAudioFile audio,
    required String name,
    required double tempoBpm,
    required bool loop,
  }) {
    if (_looksAbsolute(audio.fileRef)) {
      throw ArgumentError.value(
        audio.fileRef,
        'fileRef',
        'must be relative to the set, so the capture folder can move',
      );
    }
    final seconds = audio.seconds;
    final beats = secondsToBeats(seconds, tempoBpm);
    // An unwarped clip's markers are in seconds of the file, a warped
    // clip's in beats.
    final end = loop ? beats : seconds;
    final clip = this.clip.copy()
      ..setAttribute('Id', '$id')
      ..setAttribute('Time', _number(startBeats));
    _setValue(clip.getElement('CurrentStart')!, _number(startBeats));
    _setValue(clip.getElement('CurrentEnd')!, _number(startBeats + beats));
    final markers = clip.getElement('Loop')!;
    _setValue(markers.getElement('LoopStart')!, '0');
    _setValue(markers.getElement('LoopEnd')!, _number(end));
    _setValue(markers.getElement('StartRelative')!, '0');
    _setValue(markers.getElement('LoopOn')!, '$loop');
    _setValue(markers.getElement('OutMarker')!, _number(end));
    _setValue(markers.getElement('HiddenLoopStart')!, '0');
    _setValue(markers.getElement('HiddenLoopEnd')!, _number(end));
    _setValue(clip.getElement('Name')!, name);
    _setValue(clip.getElement('IsWarped')!, '$loop');
    if (loop) _setValue(clip.getElement('WarpMode')!, '$_kWarpModeRePitch');

    final sample = clip.getElement('SampleRef')!;
    final fileRef = sample.getElement('FileRef')!;
    _setValue(fileRef.getElement('RelativePathType')!, '1');
    _setValue(fileRef.getElement('RelativePath')!, audio.fileRef);
    _setValue(fileRef.getElement('Path')!, audio.fileRef);
    _setValue(fileRef.getElement('Type')!, '2');
    // Live writes these for a file it has read; they would describe the
    // template's file, not this one, and Live fills them in on its next
    // save.
    for (final stale in ['LivePackName', 'LivePackId', 'OriginalFileSize']) {
      fileRef.getElement(stale)?.remove();
    }
    fileRef.getElement('OriginalCrc')?.remove();
    _setValue(sample.getElement('LastModDate')!, '0');
    _setValue(sample.getElement('DefaultDuration')!, '${audio.frames}');
    _setValue(sample.getElement('DefaultSampleRate')!, '${audio.sampleRate}');

    final warpMarkers = clip.getElement('WarpMarkers')!;
    warpMarkers.children
      ..clear()
      ..add(_warpMarker(0, 0, 0))
      ..add(_warpMarker(1, seconds, beats));
    return clip;
  }
}

XmlElement _warpMarker(int id, double seconds, double beats) => _element(
  'WarpMarker',
  {'Id': '$id', 'SecTime': _number(seconds), 'BeatTime': _number(beats)},
);

/// An element named [name] with [attributes] and no children.
XmlElement _element(String name, Map<String, String> attributes) =>
    XmlElement(XmlName.qualified(name), [
      for (final MapEntry(:key, :value) in attributes.entries)
        XmlAttribute(XmlName.qualified(key), value),
    ]);

/// The lowest and highest value [parameter] takes, from its
/// `MidiControllerRange`.
(double, double) _range(XmlElement parameter) {
  final range = parameter.getElement('MidiControllerRange')!;
  return (
    double.parse(range.getElement('Min')!.getAttribute('Value')!),
    double.parse(range.getElement('Max')!.getAttribute('Value')!),
  );
}

/// [track]'s lane for [target], or `null`. A track may carry at most one
/// lane per target.
AutomationLane? _laneFor(DawTrack track, AutomationTarget target) {
  final matches = track.automationLanes.where((l) => l.target == target);
  if (matches.length > 1) {
    throw ArgumentError.value(
      track.name,
      'track',
      'has ${matches.length} automation lanes for $target; at most one is '
          'allowed per track per target',
    );
  }
  return matches.isEmpty ? null : matches.single;
}

void _setTempo(XmlElement liveSet, double tempoBpm) {
  final mainTrack = liveSet.getElement('MainTrack')!;
  final tempo = mainTrack
      .getElement('DeviceChain')!
      .getElement('Mixer')!
      .getElement('Tempo')!;
  _setValue(tempo.getElement('Manual')!, _number(tempoBpm));
  final target = tempo.getElement('AutomationTarget')!.getAttribute('Id');
  for (final envelope in _envelopes(mainTrack).childElements) {
    final pointee = envelope
        .getElement('EnvelopeTarget')!
        .getElement('PointeeId')!
        .getAttribute('Value');
    if (pointee != target) continue;
    for (final event
        in envelope
            .getElement('Automation')!
            .getElement('Events')!
            .childElements) {
      event.setAttribute('Value', _number(tempoBpm));
    }
  }
}

/// The Arrangement width, in pixels, the opening zoom fits the capture
/// into: narrower than Live's Arrangement with the browser open, so the
/// whole capture shows either way.
const double _kFitWidthPixels = 500;

/// Zooms the Arrangement so the longest clip fits [_kFitWidthPixels]. Live
/// keeps the zoom as beats per pixel.
void _zoomToFit(XmlElement liveSet, DawProject project) {
  var beats = 0.0;
  for (final track in project.tracks) {
    final clip = track.arrangementClip;
    if (clip == null) continue;
    final end = secondsToBeats(
      clip.startSeconds + clip.audio.seconds,
      project.tempoBpm,
    );
    if (end > beats) beats = end;
  }
  if (beats <= 0) return;
  _setValue(
    liveSet
        .getElement('SequencerNavigator')!
        .getElement('BeatTimeHelper')!
        .getElement('CurrentZoom')!,
    _number(beats / _kFitWidthPixels),
  );
}

/// Makes [list] hold at least [length] `<name>` children by copying its
/// last one, numbering each copy's `Id` by its position. Returns the
/// resulting length.
int _ensureListLength(XmlElement list, String name, int length) {
  final members = list.findElements(name).toList();
  for (var i = members.length; i < length; i++) {
    list.children.add(members.last.copy()..setAttribute('Id', '$i'));
  }
  return members.length > length ? members.length : length;
}

XmlElement _arrangerEvents(XmlElement track) => track
    .getElement('DeviceChain')!
    .getElement('MainSequencer')!
    .getElement('Sample')!
    .getElement('ArrangerAutomation')!
    .getElement('Events')!;

Iterable<XmlElement> _clipSlotValues(XmlElement track) => track
    .getElement('DeviceChain')!
    .getElement('MainSequencer')!
    .getElement('ClipSlotList')!
    .findElements('ClipSlot')
    .map((slot) => slot.getElement('ClipSlot')!.getElement('Value')!);

XmlElement _automationLanes(XmlElement track) => track
    .getElement('DeviceChain')!
    .getElement('AutomationLanes')!
    .getElement('AutomationLanes')!;

XmlElement _envelopes(XmlElement track) =>
    track.getElement('AutomationEnvelopes')!.getElement('Envelopes')!;

/// Whether an element with this name is a pointee: its `Id` is unique
/// across the whole set, below `NextPointeeId`, rather than a position in
/// its list.
bool _isPointee(String name) =>
    name == 'AutomationTarget' ||
    name == 'Pointee' ||
    name.endsWith('ModulationTarget') ||
    name.startsWith('ControllerTargets.');

int _intValue(XmlElement element) => int.parse(element.getAttribute('Value')!);

void _setValue(XmlElement element, String value) =>
    element.setAttribute('Value', value);

/// [value] the way Live writes numbers: integers without a fraction.
String _number(double value) =>
    value == value.truncateToDouble() && value.abs() < 1e15
    ? value.toInt().toString()
    : value.toString();

bool _looksAbsolute(String path) {
  if (path.startsWith('/') || path.startsWith(r'\')) return true;
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}
