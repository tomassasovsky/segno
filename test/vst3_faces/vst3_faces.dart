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
import 'vst3_params.dart';

export 'vst3_params.dart';

/// Points of the plugin's window per pixel of the console: a 450 by 662
/// treadle is 300 by 441.3 points.
const double kVst3Scale = 2 / 3;

/// The settings a continuous knob or slider is drawn at: 0 to 1 in 127
/// steps, about 2 degrees of a knob's 270.
const int kVst3Frames = 128;

/// How many pictures of a control one row of its picture sheet holds.
const int kVst3SheetColumns = 16;

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

/// The most controls one column of the panel holds, about a module's height
/// of them.
const int _kColumnControls = 7;

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
      kVst3InputId,
      kVst3OutputId,
      kVst3PlacementId,
      kVst3LevelId,
    ]);
  }

  /// The plugin's kind.
  final TrackEffectType type;

  /// The look its pedal is drawn with.
  final String look;

  /// The setting each of the face's knobs shows, in the face's order.
  final List<int> knobs;

  /// The parameters the panel lists, in order: every choice, every setting
  /// the face has no knob for, then the entry's input, output, balance or
  /// pan, and level.
  final List<int> panel;

  /// The pedal's face kind.
  FxStompFaceKind get kind => kFxStompSpecs[look]!.face;

  /// The panel in columns: one, or as many as keep each to
  /// [_kColumnControls], filled evenly in order.
  List<List<int>> get columns {
    final count = (panel.length / _kColumnControls).ceil();
    final per = (panel.length / count).ceil();
    return [
      for (var i = 0; i < panel.length; i += per)
        panel.sublist(i, math.min(i + per, panel.length)),
    ];
  }

  /// Every parameter at its default: the kind's settings, the default
  /// channel handling, switched on.
  Map<int, double> get defaults => {
    for (final (p, v) in type.defaultParams.take(type.params.length).indexed)
      p: v,
    kVst3InputId: 0,
    kVst3OutputId: 0,
    kVst3PlacementId: .5,
    kVst3LevelId: 1 / kVst3LevelMax,
    kVst3BypassId: 0,
  };

  /// The entry at [values] (by parameter id; the defaults where left out).
  BuiltInEffect effect(Map<int, double> values) {
    final all = {...defaults, ...values};
    return vst3FaceEffect(
      type,
      params: [for (var p = 0; p < type.params.length; p++) all[p]!],
    )!.copyWith(enabled: all[kVst3BypassId]! < .5, channels: vst3Channels(all));
  }

  /// How many pictures parameter [id]'s controls have: one per position of
  /// a stepped parameter, [kVst3Frames] of a continuous one.
  int framesOf(int id) {
    final n = vst3Positions(type, id);
    return n > 1 ? n : kVst3Frames;
  }
}

/// One editor's picture: the pedal of [effect] on the effect page's
/// background, and the panel's controls beside it, in a box of [size] (the
/// whole editor), or as large as they are when [size] is `null`.
class Vst3FaceArt extends StatelessWidget {
  /// Creates a [Vst3FaceArt].
  const new({required this.face, required this.effect, this.size, super.key});

  /// What the editor shows.
  final Vst3Face face;

  /// The entry drawn: its settings, channel handling and power.
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
                  const SizedBox(width: _kGap),
                  for (final (c, column) in face.columns.indexed) ...[
                    if (c > 0) const SizedBox(width: _kGap),
                    SizedBox(
                      width: _kPanelWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, id) in column.indexed) ...[
                            if (i > 0) const SizedBox(height: _kControlGap),
                            _Vst3PanelControl(
                              key: Key('vst3_param_$id'),
                              id: id,
                              effect: effect,
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

/// Parameter [id] of [effect] in the panel, as the console draws it: a
/// setting as the effect page does, the input and output as the effect
/// page's footer does, the balance or pan as its slider, and the level as an
/// effect page slider (the console shows a single effect's level nowhere).
class _Vst3PanelControl extends StatelessWidget {
  const new({required this.id, required this.effect, super.key});

  final int id;
  final BuiltInEffect effect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final channels = effect.channels;
    if (id < effect.type.params.length) {
      return FxBuiltInParamControl(
        effect: effect,
        index: id,
        width: _kPanelWidth,
        onChanged: (_) {},
      );
    }
    if (id == kVst3InputId) {
      return FxBlock(
        caption: l10n.fxEffectInput,
        child: FxInputChoice(value: channels.input, onChanged: (_) {}),
      );
    }
    if (id == kVst3OutputId) {
      return FxBlock(
        caption: l10n.fxEffectOutput,
        child: FxOutputChoice(value: channels.output, onChanged: (_) {}),
      );
    }
    if (id == kVst3PlacementId) {
      return FxBalanceControl(
        label: channels.output == FxChannelOutput.mono
            ? l10n.fxPan
            : l10n.fxBalance,
        value: channels.placement,
        onChanged: (_) {},
      );
    }
    return FxParamControl(
      label: l10n.fxLevel,
      value: channels.level / kVst3LevelMax,
      valueText: vst3LevelText(l10n, channels.level),
      width: _kPanelWidth,
      onChanged: (_) {},
    );
  }
}

/// How a control works, as the plugin reads it.
enum Vst3ControlKind {
  /// A knob: dragged up and down, drawn from its pictures. A knob of a
  /// choice only shows it ([Vst3Control.display]): the panel's selector
  /// sets it.
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
    this.display = false,
    this.track,
    this.readout,
    this.by,
    this.buttons = const [],
    this.names = const [],
  });

  final Vst3ControlKind kind;

  /// The plugin parameter it sets or shows.
  final int param;

  /// Where it is: what it is pressed in, and the region its pictures show.
  final Rect rect;

  /// How many pictures it has.
  final int frames;

  /// Whether it only shows its parameter, which another control sets.
  final bool display;

  /// A slider's track, whose left edge is 0 and right edge 1.
  final Rect? track;

  /// Where a slider's value text is: the plugin prints it there itself, at
  /// the exact value, over the picture's (one of [frames] settings). Its
  /// rectangle and the text's baseline.
  final ({Rect rect, double baseline})? readout;

  /// The parameter whose position picks which of the control's picture
  /// sheets is drawn, for a control whose picture depends on another (the
  /// balance slider reads Pan on a mono output), or `null`.
  final int? by;

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
          if (c.display) 'display': true,
          'by': ?c.by,
          if (c.track != null) 'track': _rectJson(c.track!),
          if (c.readout case final r?) ...{
            'readout': _rectJson(r.rect),
            // To a hundredth of a point, where the picture's name sits.
            'baseline': (r.baseline * kVst3Scale * 100).round() / 100,
          },
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

/// Pumps [face]'s editor art at [values] in the editor's [size] (measured
/// when `null`).
Future<void> pumpVst3Face(
  WidgetTester tester,
  Vst3Face face,
  Map<int, double> values, {
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
  await tester.pumpApp(
    Vst3FaceArt(face: face, effect: face.effect(values), size: size),
  );
}

/// The theme the editors print their own text in, from the console's: the
/// value readouts as the effect page's (its mono face, size and colour) on
/// the page's background, and a knob's value bubble as a card.
Map<String, Object> vst3Theme() {
  final surface = AppTheme.neon.extension<SurfaceTheme>()!;
  String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}'
      '${(c.toARGB32() >> 24).toRadixString(16).padLeft(2, '0')}';
  return {
    'font': kVst3Font,
    // To a hundredth of a point: 20 px is 13.33 points.
    'size': (_kReadoutSize * kVst3Scale * 100).round() / 100,
    'background': hex(surface.frameBackground),
    'readout': hex(surface.textSecondary),
    'bubble': hex(surface.card),
    'bubbleBorder': hex(surface.borderSubtle),
    'bubbleText': hex(surface.textPrimary),
  };
}

/// The face the value text is set in ([SurfaceTheme.monoFont]), as the
/// bundle holds it.
const String kVst3Font = 'JetBrainsMono-Regular.ttf';

/// The value text's size on the effect page.
const double _kReadoutSize = 20;

/// Lays out [face]'s editor: measures it, then reads where every control is.
Future<Vst3Layout> layOutVst3Face(WidgetTester tester, Vst3Face face) async {
  await pumpVst3Face(tester, face, const {});
  final measured = tester.getSize(find.byKey(const Key('vst3_face')));
  double whole(double px) => (px * kVst3Scale - 1e-6).ceil() / kVst3Scale;
  final size = Size(whole(measured.width), whole(measured.height));
  await pumpVst3Face(tester, face, const {}, size: size);

  final pedal = tester.getTopLeft(find.byKey(const Key('vst3_pedal')));
  final kind = face.kind;
  final turns = fxStompKnobTurnBounds(kind, face.knobs.length);
  final l10n = await AppLocalizations.delegate.load(const Locale('en'));
  final defaults = face.defaults;
  Rect at(Finder f) => tester.getRect(f);
  Finder within(Finder control, Finder what) =>
      find.descendant(of: control, matching: what);

  // Where a slider's value text is: from the end of its name to the row's
  // right edge, at the text's baseline.
  ({Rect rect, double baseline}) readoutOf(Finder control, String text) {
    final value = within(control, find.text(text));
    final row = at(value);
    // The name is the control's first text; it fills the row, so its own
    // width is its text's.
    final name = within(control, find.byType(RichText)).first;
    final left =
        at(name).left +
        _textWidthOf(tester.renderObject<RenderParagraph>(name)) +
        8;
    return (
      rect: _wholePoints(Rect.fromLTRB(left, row.top, row.right, row.bottom)),
      baseline:
          row.top + _baselineOf(tester.renderObject<RenderParagraph>(value)),
    );
  }

  final controls = <Vst3Control>[
    for (final (i, p) in face.knobs.indexed)
      Vst3Control(
        kind: Vst3ControlKind.knob,
        param: p,
        rect: _wholePoints(turns[i].shift(pedal)),
        frames: face.framesOf(p),
        // A choice's selector in the panel sets it.
        display: fxParamIsChoice(face.type.params[p]),
      ),
    Vst3Control(
      kind: Vst3ControlKind.footswitch,
      param: kVst3BypassId,
      rect: fxStompSwitchBounds(kind).shift(pedal),
    ),
    for (final id in face.panel)
      ...() {
        final control = find.byKey(Key('vst3_param_$id'));
        final rect = _wholePoints(at(control));
        final n = vst3Positions(face.type, id);
        final choice = id < face.type.params.length
            ? fxParamIsChoice(face.type.params[id])
            : n > 1;
        if (!choice) {
          return [
            Vst3Control(
              kind: Vst3ControlKind.slider,
              param: id,
              rect: rect,
              frames: face.framesOf(id),
              by: id == kVst3PlacementId ? kVst3OutputId : null,
              track: at(within(control, find.byType(LoopSlider))),
              readout: readoutOf(
                control,
                vst3ValueText(l10n, face.type, id, defaults[id]!),
              ),
            ),
          ];
        }
        final names = [
          for (var k = 0; k < n; k++)
            vst3ValueText(l10n, face.type, id, k / (n - 1)),
        ];
        final buttons = within(control, find.byType(LoopChoiceButton));
        final row = buttons.evaluate().length == n;
        return [
          Vst3Control(
            kind: row ? Vst3ControlKind.buttons : Vst3ControlKind.select,
            param: id,
            rect: rect,
            frames: n,
            buttons: row
                ? [for (var k = 0; k < n; k++) at(buttons.at(k))]
                : const [],
            names: row ? const [] : names,
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
  'theme': vst3Theme(),
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

/// Renders [layout]'s pictures into [out]: for each scale (1 and 2), the
/// background, the lit LED and every control's picture sheet, and copies the
/// face the editor prints its value text in.
///
/// The background is the entry at its defaults, switched off. A sheet holds
/// a control's pictures in rows of [kVst3SheetColumns], picture k showing it
/// at setting k / (frames - 1); a control drawn by another parameter's
/// position ([Vst3Control.by]) has a sheet for each, `T_i_q.png`.
Future<void> renderVst3Face(
  WidgetTester tester,
  Vst3Layout layout,
  Directory out,
) async {
  final face = layout.face;
  final type = face.type.code;
  OffsetLayer layer() =>
      tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const Key('vst3_face')),
              )
              .debugLayer!
          as OffsetLayer;
  Future<void> pump(Map<int, double> values) =>
      pumpVst3Face(tester, face, values, size: layout.size);
  Future<void> write(String name, ui.Image image) async {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File('${out.path}/$name.png').writeAsBytes(png!.buffer.asUint8List());
  }

  final sprites = [
    for (final (i, c) in layout.controls.indexed)
      if (c.frames > 0) (i, c),
  ];
  for (final scale in const [1, 2]) {
    final suffix = scale == 1 ? '' : '@2x';
    final ratio = kVst3Scale * scale;
    final full = Offset.zero & layout.size;
    await tester.runAsync(() async {
      await pump({kVst3BypassId: 1});
      await write(
        '$type$suffix',
        await layer().toImage(full, pixelRatio: ratio),
      );
      await pump(const {});
      await write(
        '${type}_led$suffix',
        await layer().toImage(layout.led, pixelRatio: ratio),
      );
      // The controls drawn by their own value alone, all in one pass; then
      // each one drawn by another parameter too, for each of its positions.
      final passes = <(int?, int)>[
        (null, 0),
        for (final (_, c) in sprites)
          if (c.by case final by?)
            for (var q = 0; q < vst3Positions(face.type, by); q++) (by, q),
      ];
      for (final (by, q) in passes.toSet()) {
        final drawn = [
          for (final s in sprites)
            if (s.$2.by == by) s,
        ];
        final pictures = {for (final (i, _) in drawn) i: <ui.Image>[]};
        final frames = drawn.map((s) => s.$2.frames).fold(0, math.max);
        for (var f = 0; f < frames; f++) {
          final values = <int, double>{
            kVst3BypassId: 1,
            for (final (_, c) in drawn)
              if (f < c.frames) c.param: f / (c.frames - 1),
          };
          if (by != null) values[by] = q / (vst3Positions(face.type, by) - 1);
          await pump(values);
          for (final (i, c) in drawn) {
            if (f >= c.frames) continue;
            final picture = await layer().toImage(c.rect, pixelRatio: ratio);
            // Whole points, so the plugin draws each picture pixel for pixel.
            expect(
              [picture.width, picture.height],
              [_points(c.rect.width) * scale, _points(c.rect.height) * scale],
            );
            pictures[i]!.add(picture);
          }
        }
        for (final (i, _) in drawn) {
          final name = by == null ? '${type}_$i' : '${type}_${i}_$q';
          await write('$name$suffix', _sheet(pictures[i]!));
        }
      }
    });
  }
  File('${repoRoot.path}/assets/fonts/$kVst3Font')
      .copySync('${out.path}/$kVst3Font');
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

/// [paragraph]'s text laid out on its own, at its natural width.
TextPainter _painterOf(RenderParagraph paragraph) => TextPainter(
  text: paragraph.text,
  textDirection: paragraph.textDirection,
  textScaler: paragraph.textScaler,
  strutStyle: paragraph.strutStyle,
  textHeightBehavior: paragraph.textHeightBehavior,
)..layout();

/// How far below its top [paragraph]'s first line sits on its baseline.
double _baselineOf(RenderParagraph paragraph) {
  final painter = _painterOf(paragraph);
  final baseline = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  painter.dispose();
  return baseline;
}

/// How wide [paragraph]'s text is, whatever room it was given.
double _textWidthOf(RenderParagraph paragraph) {
  final painter = _painterOf(paragraph);
  final width = painter.width;
  painter.dispose();
  return width;
}
