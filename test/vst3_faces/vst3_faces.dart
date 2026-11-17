/// The pedal faces Segno.vst3's editors draw (#1815), exported from the
/// console's own drawing code: the layout every editor reads
/// ([kVst3FacesManifest]) and the pictures it draws, which
/// `vst3_faces_render_test.dart` renders when the plugins are installed.
///
/// An editor is the console's single-effect page reduced to what a plugin
/// window holds: the effect's pedal ([FxStompPedal]) on the effect page's
/// background and, beside it, the controls the face has no knob for and every
/// choice, as the effect page draws them ([FxBuiltInParamControl]). The whole
/// is laid out in the console's pixels and drawn at [kVst3Scale] points per
/// pixel.
///
/// The plugin draws a still background and, over it, the parts that move:
/// each a picture of its own region of the same composition, drawn with its
/// control at another setting. A knob or a slider has one at each of
/// [kVst3Frames] settings (or at each position of a stepped one), a choice
/// one at each position, and the LED one lit. So every picture fits the
/// background exactly.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fx_catalogue/fx_catalogue.dart';
import 'package:looper_repository/looper_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/model/fx_art.dart';
import 'package:segno/looper/view/fx/fx_editor_parts.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_face.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_pedal.dart';
import 'package:segno/looper/view/fx/stomp/fx_stomp_spec.dart';
import 'package:segno/looper/view/loop_settings/loop_settings_widgets.dart';
import 'package:segno/theme/theme.dart';

import '../helpers/helpers.dart';

/// Points of the plugin's window per pixel of the console: a 450 by 662
/// treadle is 300 by 441.3 points.
const double kVst3Scale = 2 / 3;

/// The settings a continuous knob or slider is drawn at: 0 to 1 in 127
/// steps, about 2 degrees of a knob's 270.
const int kVst3Frames = 128;

/// How many pictures of a control one row of its picture sheet holds.
const int kVst3SheetColumns = 16;

/// The plugin's bypass parameter (`params.h`, `kBypassId`), which the
/// footswitch switches and the LED shows.
const int kVst3BypassId = 1100;

/// The committed layout, which the plugin bundles and reads, relative to the
/// repository root.
const String kVst3FacesManifest = 'packages/segno_engine/vst3/faces/faces.json';

/// The margin around the pedal and the panel, the gap between them and the
/// panel's width, in console pixels: each a whole number of points.
const double _kMargin = 30;
const double _kGap = 30;
const double _kPanelWidth = 480;

/// The space between two of the panel's controls.
const double _kControlGap = 39;

/// The plugin kinds: every built-in type but none, by engine code.
List<TrackEffectType> get vst3Kinds => [
  for (final type in TrackEffectType.values)
    if (type != TrackEffectType.none) type,
];

/// The entry a plugin of [type] stands for on the console, at [params], or
/// `null` when the console draws no pedal for it.
///
/// A standalone built-in wears its [kFxBuiltInLooks] look and prints its own
/// name, as the console's single effects do. Any other kind wears the look of
/// the first catalogue module with a pedal that runs on it (the console draws
/// such an entry only in a rack, with that module's look), and shows its
/// kind's own settings, as an entry built as no rack variant does: a
/// plugin's parameters are its kind's.
BuiltInEffect? vst3FaceEffect(TrackEffectType type, {List<double>? params}) {
  if (kFxBuiltInLooks.containsKey(type)) {
    return BuiltInEffect(type: type, params: params);
  }
  for (final module in kFxModules) {
    final variants = kFxModuleVariants[module.name]?.values ?? const [];
    if (variants.any((build) => build.type == type)) {
      final entry = BuiltInEffect(
        type: type,
        params: params,
        module: module.name,
      );
      if (fxEntryArt(entry, live: true) != null) return entry;
    }
  }
  return null;
}

/// What one editor shows: a pedal face and the panel beside it.
class Vst3Face {
  new _(this.type, this.look, this.knobs, this.panel);

  /// The face of a plugin of [type], or `null` when the console draws no
  /// pedal for it.
  static Vst3Face? of(TrackEffectType type) {
    final effect = vst3FaceEffect(type);
    if (effect == null) return null;
    final art = fxEntryArt(effect, live: true)!;
    final room = kFxStompSpecs[art.look]!.face.maxKnobs;
    final knobs = [
      for (final i in fxStompKnobs(art.look, art.controls, room: room))
        art.controls.params[i],
    ];
    final params = type.params;
    return Vst3Face._(type, art.look, knobs, [
      for (var p = 0; p < params.length; p++)
        if (fxParamIsChoice(params[p]) || !knobs.contains(p)) p,
    ]);
  }

  /// The plugin's kind.
  final TrackEffectType type;

  /// The look its pedal is drawn with.
  final String look;

  /// The parameter each of the face's knobs turns, in the face's order.
  final List<int> knobs;

  /// The parameters the panel lists, in order: every choice, and every
  /// setting the face has no knob for.
  final List<int> panel;

  /// The pedal's face kind.
  FxStompFaceKind get kind => kFxStompSpecs[look]!.face;

  /// The entry at [settings] (the kind's defaults where `null`), switched on
  /// or off.
  BuiltInEffect effect({required bool enabled, List<double>? settings}) =>
      vst3FaceEffect(type, params: settings)!.copyWith(enabled: enabled);

  /// How many pictures parameter [p]'s controls have: one per position of
  /// a stepped parameter, [kVst3Frames] of a continuous one.
  int framesOf(int p) {
    final steps = type.params[p].steps;
    return steps > 1 ? steps : kVst3Frames;
  }
}

/// One editor's picture: the pedal of [effect] on the effect page's background,
/// and the panel's controls beside it, in a box of [size] (the whole
/// editor), or as large as they are when [size] is `null`.
class Vst3FaceArt extends StatelessWidget {
  /// Creates a [Vst3FaceArt].
  const new({required this.face, required this.effect, this.size, super.key});

  /// What the editor shows.
  final Vst3Face face;

  /// The entry drawn: its settings and its power.
  final BuiltInEffect effect;

  /// The editor's size, or `null` to measure it.
  final Size? size;

  @override
  Widget build(BuildContext context) {
    final pedal = fxStompFace(context.l10n, fxEntryArt(effect, live: true)!)!;
    return Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: const Key('vst3_face'),
        // The page's Material, which sets the controls' text as the console
        // does.
        child: Material(
          color: context.surface.frameBackground,
          child: SizedBox(
            width: size?.width,
            height: size?.height,
            child: Padding(
              padding: const EdgeInsets.all(_kMargin),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox.fromSize(
                    key: const Key('vst3_pedal'),
                    size: face.kind.size,
                    child: FxStompPedal(face: pedal),
                  ),
                  if (face.panel.isNotEmpty) ...[
                    const SizedBox(width: _kGap),
                    SizedBox(
                      width: _kPanelWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, p) in face.panel.indexed) ...[
                            if (i > 0) const SizedBox(height: _kControlGap),
                            FxBuiltInParamControl(
                              key: Key('vst3_param_$p'),
                              effect: effect,
                              index: p,
                              width: _kPanelWidth,
                              onChanged: (_) {},
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How a control works, as the plugin reads it.
enum Vst3ControlKind {
  /// A knob: dragged up and down, drawn from its pictures.
  knob,

  /// The panel's slider: set where it is pressed along [Vst3Control.track].
  slider,

  /// A row of buttons, one per position ([Vst3Control.buttons]).
  buttons,

  /// A select: opens a menu of [Vst3Control.names].
  select,

  /// The footswitch: switches the bypass. It has no pictures; the LED shows
  /// what it did.
  footswitch,
}

/// One of an editor's controls, in console pixels.
class Vst3Control {
  const new({
    required this.kind,
    required this.param,
    required this.rect,
    this.frames = 0,
    this.track,
    this.buttons = const [],
    this.names = const [],
  });

  final Vst3ControlKind kind;

  /// The plugin parameter it sets.
  final int param;

  /// Where it is: what it is pressed in, and the region its pictures show.
  final Rect rect;

  /// How many pictures it has.
  final int frames;

  /// A slider's track, whose left edge is 0 and right edge 1.
  final Rect? track;

  /// A button row's buttons, by position.
  final List<Rect> buttons;

  /// A select's position names, in order.
  final List<String> names;
}

/// An editor laid out: its size, its LED and its controls.
class Vst3Layout {
  const new(this.face, this.size, this.led, this.controls);

  final Vst3Face face;

  /// The editor's size in console pixels: a whole number of points.
  final Size size;

  /// What the LED lights.
  final Rect led;

  final List<Vst3Control> controls;

  /// The layout as [kVst3FacesManifest] holds it, in points.
  Map<String, Object> toJson() => {
    'type': face.type.code,
    'look': face.look,
    'size': [_points(size.width), _points(size.height)],
    'led': _rectJson(led),
    'controls': [
      for (final c in controls)
        {
          'control': c.kind.name,
          'param': c.param,
          'rect': _rectJson(c.rect),
          if (c.frames > 0) 'frames': c.frames,
          if (c.track != null) 'track': _rectJson(c.track!),
          if (c.buttons.isNotEmpty)
            'buttons': [for (final b in c.buttons) _rectJson(b)],
          if (c.names.isNotEmpty) 'names': c.names,
        },
    ],
  };
}

int _points(double px) => (px * kVst3Scale).round();

List<int> _rectJson(Rect r) => [
  _points(r.left),
  _points(r.top),
  _points(r.width),
  _points(r.height),
];

/// [r] grown to whole points, so its pictures start and end on a pixel at
/// either scale.
Rect _wholePoints(Rect r) {
  double down(double px) => (px * kVst3Scale + 1e-6).floor() / kVst3Scale;
  double up(double px) => (px * kVst3Scale - 1e-6).ceil() / kVst3Scale;
  return Rect.fromLTRB(down(r.left), down(r.top), up(r.right), up(r.bottom));
}

/// Pumps [face]'s editor art at [effect] in the editor's [size] (measured
/// when `null`).
Future<void> pumpVst3Face(
  WidgetTester tester,
  Vst3Face face,
  BuiltInEffect effect, {
  Size? size,
}) async {
  // Room for the tallest editor, a module and its panel, at one pixel a
  // pixel.
  tester.view
    ..physicalSize = const Size(2400, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Mounted afresh, so nothing animates from the setting drawn before (a
  // choice button's border eases to its new colour).
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpApp(Vst3FaceArt(face: face, effect: effect, size: size));
}

/// Lays out [face]'s editor: measures it, then reads where every control is.
Future<Vst3Layout> layOutVst3Face(WidgetTester tester, Vst3Face face) async {
  final effect = face.effect(enabled: true);
  await pumpVst3Face(tester, face, effect);
  final measured = tester.getSize(find.byKey(const Key('vst3_face')));
  double whole(double px) => (px * kVst3Scale - 1e-6).ceil() / kVst3Scale;
  final size = Size(whole(measured.width), whole(measured.height));
  await pumpVst3Face(tester, face, effect, size: size);

  final pedal = tester.getTopLeft(find.byKey(const Key('vst3_pedal')));
  final kind = face.kind;
  final turns = fxStompKnobTurnBounds(kind, face.knobs.length);
  final l10n = await AppLocalizations.delegate.load(const Locale('en'));
  Rect at(Finder f) => tester.getRect(f);
  final controls = <Vst3Control>[
    for (final (i, p) in face.knobs.indexed)
      Vst3Control(
        kind: Vst3ControlKind.knob,
        param: p,
        rect: _wholePoints(turns[i].shift(pedal)),
        frames: face.framesOf(p),
      ),
    Vst3Control(
      kind: Vst3ControlKind.footswitch,
      param: kVst3BypassId,
      rect: fxStompSwitchBounds(kind).shift(pedal),
    ),
    for (final p in face.panel)
      ...() {
        final param = face.type.params[p];
        final control = find.byKey(Key('vst3_param_$p'));
        final rect = _wholePoints(at(control));
        if (!fxParamIsChoice(param)) {
          return [
            Vst3Control(
              kind: Vst3ControlKind.slider,
              param: p,
              rect: rect,
              frames: face.framesOf(p),
              track: at(
                find.descendant(of: control, matching: find.byType(LoopSlider)),
              ),
            ),
          ];
        }
        final last = param.steps - 1;
        final buttons = [
          for (var k = 0; k <= last; k++)
            find.byKey(Key('fx_choice_${param.key}_$k')),
        ];
        final row = buttons.every((b) => b.evaluate().isNotEmpty);
        return [
          Vst3Control(
            kind: row ? Vst3ControlKind.buttons : Vst3ControlKind.select,
            param: p,
            rect: rect,
            frames: param.steps,
            buttons: row ? [for (final b in buttons) at(b)] : const [],
            names: row
                ? const []
                : [
                    for (var k = 0; k <= last; k++)
                      l10n.fxParamValueText(param, k / last),
                  ],
          ),
        ];
      }(),
  ];
  return Vst3Layout(
    face,
    size,
    _wholePoints(fxStompLedBounds(kind).shift(pedal)),
    controls,
  );
}

/// Every plugin's layout, as [kVst3FacesManifest] holds it.
Future<Map<String, Object>> vst3FacesManifest(WidgetTester tester) async => {
  'frames': kVst3Frames,
  'columns': kVst3SheetColumns,
  'faces': [
    for (final type in vst3Kinds)
      if (Vst3Face.of(type) case final face?)
        (await layOutVst3Face(tester, face)).toJson(),
  ],
};

/// A rectangle's or a size's numbers, each on a line of their own.
final RegExp _numberRow = RegExp(r'\[\s+(-?\d+(?:,\s+-?\d+)*)\s+\]');

/// [manifest] as the committed file holds it: two-space JSON, with a
/// rectangle's or a size's numbers on one line.
String encodeVst3Manifest(Map<String, Object> manifest) {
  final text = const JsonEncoder.withIndent('  ').convert(manifest);
  final rows = text.replaceAllMapped(
    _numberRow,
    (m) => '[${m[1]!.split(RegExp(r',\s+')).join(', ')}]',
  );
  return '$rows\n';
}

/// The repository root, from the test's working directory (the app's root).
Directory get repoRoot => Directory.current;

/// Renders [layout]'s pictures into [out]: for each scale (1 and 2), the
/// background, the lit LED and every control's picture sheet.
///
/// The background is the entry at its defaults, switched off. A sheet holds
/// a control's pictures in rows of [kVst3SheetColumns], picture k showing it
/// at setting k / (frames - 1).
Future<void> renderVst3Face(
  WidgetTester tester,
  Vst3Layout layout,
  Directory out,
) async {
  final face = layout.face;
  final type = face.type.code;
  final count = face.type.params.length;
  final defaults = face.type.defaultParams;
  OffsetLayer layer() =>
      tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const Key('vst3_face')),
              )
              .debugLayer!
          as OffsetLayer;
  Future<void> pump(BuiltInEffect effect) =>
      pumpVst3Face(tester, face, effect, size: layout.size);
  Future<void> write(String name, ui.Image image) async {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('${out.path}/$name.png').writeAsBytes(png!.buffer.asUint8List());
  }

  final sprites = [
    for (final (i, c) in layout.controls.indexed)
      if (c.frames > 0) (i, c),
  ];
  final frames = sprites.map((s) => s.$2.frames).fold(0, math.max);
  for (final scale in const [1, 2]) {
    final suffix = scale == 1 ? '' : '@2x';
    final ratio = kVst3Scale * scale;
    final full = Offset.zero & layout.size;
    await tester.runAsync(() async {
      await pump(face.effect(enabled: false));
      await write(
        '$type$suffix',
        await layer().toImage(full, pixelRatio: ratio),
      );
      await pump(face.effect(enabled: true));
      await write(
        '${type}_led$suffix',
        await layer().toImage(layout.led, pixelRatio: ratio),
      );
      final pictures = {for (final (i, _) in sprites) i: <ui.Image>[]};
      for (var f = 0; f < frames; f++) {
        final settings = List<double>.of(defaults);
        for (final (_, c) in sprites) {
          if (f < c.frames && c.param < count) {
            settings[c.param] = f / (c.frames - 1);
          }
        }
        await pump(face.effect(enabled: false, settings: settings));
        for (final (i, c) in sprites) {
          if (f < c.frames) {
            final picture = await layer().toImage(c.rect, pixelRatio: ratio);
            // Whole points, so the plugin draws each picture pixel for pixel.
            expect(
              [picture.width, picture.height],
              [_points(c.rect.width) * scale, _points(c.rect.height) * scale],
            );
            pictures[i]!.add(picture);
          }
        }
      }
      for (final (i, _) in sprites) {
        await write('${type}_$i$suffix', _sheet(pictures[i]!));
      }
    });
  }
}

/// [pictures] in rows of [kVst3SheetColumns], disposed once drawn.
ui.Image _sheet(List<ui.Image> pictures) {
  final w = pictures.first.width;
  final h = pictures.first.height;
  final columns = math.min(pictures.length, kVst3SheetColumns);
  final rows = (pictures.length / kVst3SheetColumns).ceil();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (final (k, picture) in pictures.indexed) {
    canvas.drawImage(
      picture,
      Offset((k % columns * w).toDouble(), (k ~/ columns * h).toDouble()),
      Paint(),
    );
  }
  final sheet = recorder.endRecording().toImageSync(columns * w, rows * h);
  for (final picture in pictures) {
    picture.dispose();
  }
  return sheet;
}
