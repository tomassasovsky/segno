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

const _imports = '''
import 'dart:async';

import 'package:material_ui/material_ui.dart';
''';

const _fixtures = <String, String>{
  'flags':
      '''
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

Stream<Widget> stream() async* {}

(Widget, int) pair() => (const SizedBox(), 1);

({Widget? icon}) named() => (icon: null);

// ignore: avoid_annotating_with_dynamic
dynamic loose() => const SizedBox();

Object? boxed(bool wide) => wide ? const SizedBox() : null;
''',
  'untyped':
      '''
$_imports
// ignore: type_annotate_public_apis, always_declare_return_types
untyped() => const SizedBox();

class Holder {
  // ignore: type_annotate_public_apis
  get label => const Text('');

  // ignore: always_declare_return_types
  count() => 1;

  // ignore: always_declare_return_types
  nothing() {
    return null;
  }

  Null get empty => null;

  // ignore: always_declare_return_types
  row(bool wide) {
    if (wide) return const SizedBox();
    return null;
  }
}
''',
  'overrides':
      '''
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
''',
  'app_override':
      '''
$_imports
abstract class Cell {
  Widget face();
}

class Square extends Cell {
  @override
  Widget face() => const SizedBox();
}
''',
  'not_flagged':
      '''
$_imports
class Panel extends StatelessWidget {
  const Panel({super.key});

  factory Panel.empty() => const Panel();

  set child(Widget value) {}

  Color _tone() => const Color(0xFF000000);

  Widget Function() _factory() => () => const SizedBox();

  Map<String, Widget> _byName() => const {};

  Object _value() => 1;

  (int, String) _pair() => (1, '');

  @override
  Widget build(BuildContext context) => ListView.builder(
    itemBuilder: (context, index) => const SizedBox(),
    itemCount: [1].map((_) => const SizedBox()).length,
  );
}
''',
  'report': '$_imports\nList<Widget> rows() => const [];\n',
};

/// The fixture [name], held in memory under test/ so it resolves
/// package:flutter through the app's package config.
String _fixturePath(String name) =>
    p.join(_root, 'test', 'tool', '_fixture_$name.dart');

/// Runs the check over [sources], keyed by fixture name.
Future<List<WidgetMethod>> _find(Map<String, String> sources) {
  final provider = OverlayResourceProvider(PhysicalResourceProvider.INSTANCE);
  for (final MapEntry(:key, :value) in sources.entries) {
    provider.setOverlay(
      _fixturePath(key),
      content: value,
      modificationStamp: 0,
    );
  }
  return findWidgetMethods(
    root: _root,
    files: [for (final name in sources.keys) _fixturePath(name)],
    resourceProvider: provider,
    sdkPath: _sdkPath,
  );
}

/// What the check found in every fixture, resolved once: resolving the
/// framework takes seconds.
late List<WidgetMethod> _found;

/// What the check found in the fixture [name].
List<WidgetMethod> _foundIn(String name) => [
  for (final method in _found)
    if (method.path == 'test/tool/_fixture_$name.dart') method,
];

/// The scopes the check flags in the fixture [name].
List<String> _flagged(String name) => [
  for (final method in _foundIn(name)) method.scope,
];

void main() {
  group('findWidgetMethods', () {
    setUpAll(() async => _found = await _find(_fixtures));

    test('flags methods, getters, functions and local functions', () {
      expect(_flagged('flags'), [
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
        'stream',
        'pair',
        'named',
        'loose',
        'boxed',
      ]);
    });

    test(
      'flags a declaration without a return type that returns a widget',
      () {
        expect(_flagged('untyped'), ['untyped', 'Holder.label', 'Holder.row']);
      },
    );

    test('does not flag framework overrides', () {
      expect(_flagged('overrides'), isEmpty);
    });

    test('flags an override of a member declared in app code', () {
      expect(_flagged('app_override'), ['Cell.face', 'Square.face']);
    });

    test(
      'does not flag closures, constructors, setters or other types',
      () {
        expect(_flagged('not_flagged'), isEmpty);
      },
    );

    test('reports the path, line and type', () {
      const path = 'test/tool/_fixture_report.dart';
      expect(_foundIn('report').map((method) => '$method'), [
        '$path:5: rows returns List<Widget>',
      ]);
    });

    test('fails on a file that does not resolve', () {
      expect(
        _find({'broken': 'Widget row() => const SizedBox();\n'}),
        throwsA(isA<StateError>()),
      );
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
}
