import 'dart:io';

import 'package:analyzer/file_system/overlay_file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/check_no_widget_methods.dart';

/// The repository root: `flutter test` runs from it.
final String _root = Directory.current.path;

/// The Dart SDK that ships with the Flutter SDK running this test. The
/// analyzer finds its SDK next to the running executable, which here is
/// flutter_tester (`bin/cache/artifacts/engine/<platform>/flutter_tester`).
final String _sdkPath = p.normalize(
  p.join(
    p.dirname(Platform.resolvedExecutable),
    '..',
    '..',
    '..',
    'dart-sdk',
  ),
);

var _fixtures = 0;

/// Runs the check over [source], held in memory as a file under test/ so it
/// resolves package:flutter through the app's package config.
Future<List<WidgetMethod>> _find(String source) {
  final path = p.join(_root, 'test', 'tool', '_fixture_${_fixtures++}.dart');
  return findWidgetMethods(
    root: _root,
    files: [path],
    resourceProvider: OverlayResourceProvider(
      PhysicalResourceProvider.INSTANCE,
    )..setOverlay(path, content: source, modificationStamp: 0),
    sdkPath: _sdkPath,
  );
}

/// The scopes the check flags in [source].
Future<List<String>> _flagged(String source) async => [
  for (final method in await _find(source)) method.scope,
];

const _imports = '''
import 'dart:async';

import 'package:flutter/material.dart';
''';

void main() {
  group('findWidgetMethods', () {
    test('flags methods, getters, functions and local functions', () async {
      final flagged = await _flagged('''
$_imports
Widget header() => const Text('');

Widget? get maybe => null;

class Panel extends StatelessWidget {
  const Panel({super.key});

  Widget _row() => const SizedBox();

  Widget? get _banner => null;

  PreferredSizeWidget _bar() => AppBar();

  Text _label() => const Text('');

  List<Widget> _items() => const [];

  Iterable<Widget> _more() sync* {}

  Future<Widget> _later() async => const SizedBox();

  @override
  Widget build(BuildContext context) {
    Widget cell() => const SizedBox();
    return Column(children: [_row(), cell()]);
  }
}

extension on BuildContext {
  Widget get gap => const SizedBox();
}

mixin Rows {
  Widget row();
}

T pick<T extends Widget>(T widget) => widget;
''');
      expect(flagged, [
        'header',
        'maybe',
        'Panel._row',
        'Panel._banner',
        'Panel._bar',
        'Panel._label',
        'Panel._items',
        'Panel._more',
        'Panel._later',
        'Panel.build.cell',
        'extension.gap',
        'Rows.row',
        'pick',
      ]);
    });

    test(
      'flags a declaration without a return type that returns a widget',
      () async {
        final flagged = await _flagged('''
$_imports
// ignore: type_annotate_public_apis, always_declare_return_types
untyped() => const SizedBox();

class Holder {
  // ignore: type_annotate_public_apis
  get label => const Text('');

  // ignore: always_declare_return_types
  count() => 1;

  // ignore: always_declare_return_types
  row(bool wide) {
    if (wide) return const SizedBox();
    return null;
  }
}
''');
        expect(flagged, ['untyped', 'Holder.label', 'Holder.row']);
      },
    );

    test('does not flag framework overrides', () async {
      final flagged = await _flagged('''
$_imports
class Panel extends StatefulWidget {
  const Panel({super.key});

  @override
  State<Panel> createState() => _PanelState();
}

class _PanelState extends State<Panel> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

class Delegate extends SliverPersistentHeaderDelegate {
  @override
  Widget build(BuildContext context, double shrink, bool overlaps) =>
      const SizedBox();

  @override
  double get maxExtent => 1;

  @override
  double get minExtent => 1;

  @override
  bool shouldRebuild(Delegate oldDelegate) => false;
}

class Route extends PageRoute<void> {
  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox();
}
''');
      expect(flagged, isEmpty);
    });

    test('flags an override of a member declared in app code', () async {
      final flagged = await _flagged('''
$_imports
abstract class Cell {
  Widget face();
}

class Square extends Cell {
  @override
  Widget face() => const SizedBox();
}
''');
      expect(flagged, ['Cell.face', 'Square.face']);
    });

    test(
      'does not flag closures, constructors, setters or other types',
      () async {
        final flagged = await _flagged('''
$_imports
class Panel extends StatelessWidget {
  const Panel({super.key});

  factory Panel.empty() => const Panel();

  set child(Widget value) {}

  Color _tone() => const Color(0xFF000000);

  Widget Function() _factory() => () => const SizedBox();

  Map<String, Widget> _byName() => const {};

  @override
  Widget build(BuildContext context) => ListView.builder(
    itemBuilder: (context, index) => const SizedBox(),
    itemCount: [1].map((_) => const SizedBox()).length,
  );
}
''');
        expect(flagged, isEmpty);
      },
    );

    test('reports the path, line and type', () async {
      final found = await _find(
        '$_imports\nList<Widget> rows() => const [];\n',
      );
      final path = 'test/tool/_fixture_${_fixtures - 1}.dart';
      expect(found.map((method) => '$method'), [
        '$path:5: rows returns List<Widget>',
      ]);
      expect(found.single.key, '$path#rows');
    });
  });

  group('isGenerated', () {
    test('matches generated code', () {
      expect(isGenerated('lib/a.g.dart'), isTrue);
      expect(isGenerated('lib/a.freezed.dart'), isTrue);
      expect(isGenerated('lib/l10n/gen/app_localizations.dart'), isTrue);
      expect(
        isGenerated('packages/segno_engine/lib/src/generated/bindings.dart'),
        isTrue,
      );
    });

    test('does not match hand-written code', () {
      expect(isGenerated('lib/looper/view/mixer_column.dart'), isFalse);
      expect(isGenerated('lib/l10n/localized.dart'), isFalse);
    });
  });

  group('compare', () {
    WidgetMethod method(String scope) => WidgetMethod(
      path: 'lib/a.dart',
      line: 1,
      scope: scope,
      type: 'Widget',
    );

    test('passes when every declaration is in the baseline', () {
      final comparison = compare(
        [method('A._row'), method('A._row')],
        ['lib/a.dart#A._row', 'lib/a.dart#A._row'],
      );
      expect(comparison.passes, isTrue);
    });

    test('fails on a declaration missing from the baseline', () {
      final comparison = compare(
        [method('A._row'), method('A._cell')],
        ['lib/a.dart#A._row'],
      );
      expect(comparison.passes, isFalse);
      expect(comparison.violations.map((m) => m.key), ['lib/a.dart#A._cell']);
      expect(comparison.stale, isEmpty);
    });

    test('fails on a stale baseline entry', () {
      final comparison = compare(
        [method('A._row')],
        ['lib/a.dart#A._row', 'lib/a.dart#A._row', 'lib/a.dart#A._gone'],
      );
      expect(comparison.passes, isFalse);
      expect(comparison.violations, isEmpty);
      expect(comparison.stale, ['lib/a.dart#A._row', 'lib/a.dart#A._gone']);
    });
  });

  group('readBaseline', () {
    test('skips comments and blank lines', () {
      final file = File(
        p.join(Directory.systemTemp.createTempSync('nwm_').path, 'b.txt'),
      )..writeAsStringSync('# header\n\nlib/a.dart#A._row\n  \n');
      expect(readBaseline(file), ['lib/a.dart#A._row']);
    });

    test('reads a missing file as empty', () {
      expect(
        readBaseline(File(p.join(_root, 'no_such_baseline.txt'))),
        isEmpty,
      );
    });
  });
}
