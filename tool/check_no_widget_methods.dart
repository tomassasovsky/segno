// Fails when app code declares a method, function or getter that returns a
// widget (#1697).
//
// Every piece of UI is a StatelessWidget or StatefulWidget class that takes
// its data through constructor parameters. A helper such as
// `Widget _buildHeader()` or `List<Widget> _rows()` rebuilds with its caller,
// cannot be const, and has no element of its own, so it is not allowed.
//
// Checked: every method, top-level function, getter and local function
// declaration in lib/ and packages/*/lib whose declared or inferred return
// type is a widget: Widget and its subtypes (PreferredSizeWidget, Container,
// a type parameter bounded by Widget), nullable or not, and a Future,
// FutureOr, List, Iterable or other Iterable of one. A method or function
// written without a return type is `dynamic` to Dart; for those, the types of
// the expressions it returns decide.
//
// Not checked: a method that overrides a member declared outside this
// repository (State.build, StatelessWidget.build, SliverChildDelegate.build
// and the other framework hooks a class must implement), closures (builder
// callbacks), constructors, generated code (*.g.dart, *.freezed.dart,
// lib/l10n/gen/, generated/ directories such as ffigen's) and tests.
//
// tool/widget_methods_baseline.txt lists the declarations that still break
// the rule, one `path#Scope.name` per line; lines starting with `#` and blank
// lines are ignored. The check fails on a declaration missing from it and on
// an entry that no longer matches one, so the list only shrinks.
//
// Usage: dart run tool/check_no_widget_methods.dart (after flutter pub get)

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/file_system/file_system.dart' show ResourceProvider;
// The public AnalysisContextCollection cannot take a package config, and the
// packages under packages/ are resolved through the app's, so they need no
// `pub get` of their own.
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:path/path.dart' as p;

/// The baseline, relative to the repository root.
const baselinePath = 'tool/widget_methods_baseline.txt';

const _frameworkUri = 'package:flutter/src/widgets/framework.dart';

/// One declaration that returns a widget.
class WidgetMethod {
  const WidgetMethod({
    required this.path,
    required this.line,
    required this.scope,
    required this.type,
  });

  /// The file, relative to the repository root, with `/` separators.
  final String path;

  /// The 1-based line of the declaration's name.
  final int line;

  /// The enclosing declarations and the name, joined by `.`, such as
  /// `_PedalSetupPageState._actions` or `_PanelState.build.row`.
  final String scope;

  /// The return type, as Dart writes it.
  final String type;

  /// The baseline key: stable while lines move.
  String get key => '$path#$scope';

  @override
  String toString() => '$path:$line: $scope returns $type';
}

/// The directories checked under [root]: lib/ and every packages/*/lib.
List<String> checkedDirectories(String root) => [
  p.join(root, 'lib'),
  for (final package in Directory(
    p.join(root, 'packages'),
  ).listSync()..sort((a, b) => a.path.compareTo(b.path)))
    if (Directory(p.join(package.path, 'lib')).existsSync())
      p.join(package.path, 'lib'),
];

/// Whether [path] is generated code, which the check skips.
bool isGenerated(String path) {
  final posix = p.split(path);
  return path.endsWith('.g.dart') ||
      path.endsWith('.freezed.dart') ||
      posix.contains('generated') ||
      _containsRun(posix, const ['lib', 'l10n', 'gen']);
}

bool _containsRun(List<String> parts, List<String> run) {
  for (var i = 0; i + run.length <= parts.length; i++) {
    var match = true;
    for (var j = 0; j < run.length; j++) {
      if (parts[i + j] != run[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Finds every widget-returning declaration in the Dart files of
/// [directories] (or in the files [files] when given), resolved through the
/// package config of the repository at [root].
///
/// [resourceProvider] and [sdkPath] are for tests, which analyze fixtures
/// held in memory and run under flutter_tester rather than the Dart VM.
Future<List<WidgetMethod>> findWidgetMethods({
  required String root,
  List<String>? directories,
  List<String>? files,
  ResourceProvider? resourceProvider,
  String? sdkPath,
}) async {
  final included = files ?? directories ?? checkedDirectories(root);
  final collection = AnalysisContextCollectionImpl(
    includedPaths: included,
    packageConfigFile: p.join(root, '.dart_tool', 'package_config.json'),
    resourceProvider: resourceProvider,
    sdkPath: sdkPath,
  );
  final found = <WidgetMethod>[];
  try {
    for (final context in collection.contexts) {
      final widget = await _widgetType(context);
      for (final path in context.contextRoot.analyzedFiles()) {
        if (!path.endsWith('.dart') ||
            isGenerated(p.relative(path, from: root))) {
          continue;
        }
        if (!_isWithinAny(included, path)) continue;
        final result = await context.currentSession.getResolvedUnit(path);
        if (result is! ResolvedUnitResult) {
          throw StateError('could not resolve $path');
        }
        final visitor = _Visitor(
          root: root,
          checked: included,
          result: result,
          widget: widget,
        );
        result.unit.accept(visitor);
        found.addAll(visitor.found);
      }
    }
  } finally {
    await collection.dispose();
  }
  found.sort((a, b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : a.line.compareTo(b.line);
  });
  return found;
}

/// Whether [path] is one of [paths] or inside one of them.
bool _isWithinAny(List<String> paths, String path) =>
    paths.any((root) => root == path || p.isWithin(root, path));

Future<InterfaceType> _widgetType(AnalysisContext context) async {
  final library = await context.currentSession.getLibraryByUri(_frameworkUri);
  if (library is! LibraryElementResult) {
    throw StateError(
      'cannot resolve $_frameworkUri for ${context.contextRoot.root.path}; '
      'run `flutter pub get` at the repository root first',
    );
  }
  final widget = library.element.getClass('Widget');
  if (widget == null) throw StateError('no Widget class in $_frameworkUri');
  return widget.thisType;
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor({
    required this.root,
    required this.checked,
    required this.result,
    required this.widget,
  });

  final String root;
  final List<String> checked;
  final ResolvedUnitResult result;
  final InterfaceType widget;
  final found = <WidgetMethod>[];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element != null &&
        !node.isSetter &&
        !_overridesExternal(element, <Element>{})) {
      _check(node, node.name, _returnType(element, node.returnType, node.body));
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final element = node.declaredFragment?.element;
    if (element != null && !node.isSetter) {
      _check(
        node,
        node.name,
        _returnType(element, node.returnType, node.functionExpression.body),
      );
    }
    super.visitFunctionDeclaration(node);
  }

  /// The return type of [element], or for a declaration written without one
  /// (which Dart types `dynamic`), the first widget type its body returns.
  DartType _returnType(
    ExecutableElement element,
    TypeAnnotation? declared,
    FunctionBody body,
  ) {
    final type = element.returnType;
    if (declared != null || type is! DynamicType) return type;
    final returned = _Returned();
    body.accept(returned);
    return returned.types.firstWhere(_returnsWidget, orElse: () => type);
  }

  void _check(AstNode node, Token name, DartType type) {
    if (!_returnsWidget(type)) return;
    found.add(
      WidgetMethod(
        path: p.posix.joinAll(p.split(p.relative(result.path, from: root))),
        line: result.lineInfo.getLocation(name.offset).lineNumber,
        scope: _scope(node),
        type: type.getDisplayString(),
      ),
    );
  }

  bool _returnsWidget(DartType type) {
    final typeSystem = result.typeSystem;
    if (type is NeverType || type is InvalidType) return false;
    if (type is InterfaceType) {
      if (type.isDartAsyncFuture || type.isDartAsyncFutureOr) {
        return _returnsWidget(type.typeArguments.single);
      }
      final iterable = type.asInstanceOf(
        result.typeProvider.iterableElement,
      );
      if (iterable != null) {
        return _returnsWidget(iterable.typeArguments.single);
      }
    }
    return typeSystem.isSubtypeOf(typeSystem.promoteToNonNull(type), widget);
  }

  /// Whether [element] overrides, directly or through members it overrides,
  /// a member declared outside the checked directories: a framework hook the
  /// class has to implement.
  bool _overridesExternal(ExecutableElement element, Set<Element> seen) {
    if (!seen.add(element)) return false;
    final enclosing = element.enclosingElement;
    if (enclosing is! InterfaceElement) return false;
    final name = element.name;
    if (name == null) return false;
    final overridden = enclosing.getOverridden(
      Name(element.library.uri, name),
    );
    if (overridden == null) return false;
    for (final member in overridden) {
      final path = member.library.firstFragment.source.fullName;
      if (!_isWithinAny(checked, path)) return true;
      if (_overridesExternal(member.baseElement, seen)) return true;
    }
    return false;
  }

  String _scope(AstNode node) {
    final names = <String>[];
    for (AstNode? at = node; at != null; at = at.parent) {
      final name = switch (at) {
        ExtensionDeclaration(:final name) => name?.lexeme ?? 'extension',
        ClassDeclaration() ||
        MixinDeclaration() ||
        EnumDeclaration() ||
        ExtensionTypeDeclaration() ||
        MethodDeclaration() ||
        FunctionDeclaration() => (at as Declaration).declaredFragment?.name,
        _ => null,
      };
      if (name != null) names.add(name);
    }
    return names.reversed.join('.');
  }
}

/// Collects the static types of what a body returns or yields, skipping the
/// closures and local functions inside it.
class _Returned extends RecursiveAstVisitor<void> {
  final types = <DartType>[];

  @override
  void visitExpressionFunctionBody(ExpressionFunctionBody node) {
    if (node.expression.staticType case final type?) types.add(type);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression?.staticType case final type?) types.add(type);
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    if (node.expression.staticType case final type?) types.add(type);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (node.parent is! FunctionDeclaration) return;
    super.visitFunctionExpression(node);
  }

  @override
  void visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {}
}

/// Reads the baseline keys from [file], or none when it does not exist.
List<String> readBaseline(File file) {
  if (!file.existsSync()) return const [];
  return [
    for (final raw in file.readAsLinesSync())
      if (raw.trim() case final line
          when line.isNotEmpty && !line.startsWith('#'))
        line,
  ];
}

/// The outcome of comparing what the check found with the baseline.
class Comparison {
  const Comparison({required this.violations, required this.stale});

  /// Found and not in the baseline.
  final List<WidgetMethod> violations;

  /// In the baseline and not found.
  final List<String> stale;

  bool get passes => violations.isEmpty && stale.isEmpty;
}

/// Compares [found] with [baseline], counting repeated keys: a key listed
/// twice allows two declarations with that key.
Comparison compare(List<WidgetMethod> found, List<String> baseline) {
  final allowed = <String, int>{};
  for (final key in baseline) {
    allowed[key] = (allowed[key] ?? 0) + 1;
  }
  final violations = <WidgetMethod>[];
  for (final method in found) {
    final left = allowed[method.key] ?? 0;
    if (left > 0) {
      allowed[method.key] = left - 1;
    } else {
      violations.add(method);
    }
  }
  return Comparison(
    violations: violations,
    stale: [
      for (final MapEntry(:key, :value) in allowed.entries)
        for (var i = 0; i < value; i++) key,
    ],
  );
}

Future<void> main() async {
  final root = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..'),
  );
  final found = await findWidgetMethods(root: root);
  final comparison = compare(
    found,
    readBaseline(File(p.join(root, baselinePath))),
  );
  comparison.violations.forEach(stdout.writeln);
  for (final key in comparison.stale) {
    stdout.writeln('$baselinePath: stale entry $key');
  }
  if (comparison.passes) {
    stdout.writeln(
      'No new widget-returning methods '
      '(${found.length} left in $baselinePath).',
    );
    return;
  }
  if (comparison.violations.isNotEmpty) {
    stdout.writeln(
      '\nA method, function or getter must not return a widget. Make it a '
      'StatelessWidget or StatefulWidget class that takes its data through '
      'constructor parameters (AGENTS.md, Engineering principles).',
    );
  }
  if (comparison.stale.isNotEmpty) {
    stdout.writeln(
      '\nRemove the stale entries from $baselinePath: the declarations they '
      'name are gone.',
    );
  }
  exitCode = 1;
}
