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
// a type parameter bounded by Widget), nullable or not, a Future, FutureOr,
// Stream, List or other Iterable of one, and a record with one among its
// fields. A declaration that returns `dynamic` (which is what Dart types one
// written without a return type), `Object` or `Object?` is judged by the
// types of the expressions it returns.
//
// Not checked: a method that overrides a member declared outside this
// repository (State.build, StatelessWidget.build, SliverChildDelegate.build
// and the other framework hooks a class must implement), closures (builder
// callbacks), constructors, generated code (*.g.dart, *.freezed.dart,
// lib/l10n/gen/, generated/ directories such as ffigen's) and tests.
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
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/file_system/file_system.dart' show ResourceProvider;
// The public AnalysisContextCollection cannot take a package config, and the
// packages under packages/ are resolved through the app's, so they need no
// `pub get` of their own.
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:path/path.dart' as p;

const _frameworkUri = 'package:flutter/src/widgets/framework.dart';

/// One declaration that returns a widget.
class WidgetMethod {
  const new({
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
  /// `_PanelState._row` or `_PanelState.build.cell`.
  final String scope;

  /// The return type, as Dart writes it.
  final String type;

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

/// Whether [path], relative to the repository root, is generated code,
/// which the check skips.
bool isGenerated(String path) {
  final posix = p.split(path);
  return path.endsWith('.g.dart') ||
      path.endsWith('.freezed.dart') ||
      posix.contains('generated') ||
      p.posix.joinAll(posix).startsWith('lib/l10n/gen/');
}

/// Finds every widget-returning declaration in the checked directories of
/// the repository at [root] (or in [files] when given), resolved through its
/// package config.
///
/// [resourceProvider] and [sdkPath] are for tests, which analyze fixtures
/// held in memory and run under flutter_tester rather than the Dart VM.
Future<List<WidgetMethod>> findWidgetMethods({
  required String root,
  List<String>? files,
  ResourceProvider? resourceProvider,
  String? sdkPath,
}) async {
  final included = files ?? checkedDirectories(root);
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
        // A file that does not resolve has no widget types to find, so it
        // would pass unchecked.
        final errors = [
          for (final diagnostic in result.diagnostics)
            if (diagnostic.severity == Severity.error) diagnostic,
        ];
        if (errors.isNotEmpty) {
          throw StateError(
            '$path has ${errors.length} analysis errors, the first: '
            '${errors.first.message}',
          );
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
  new({
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
      _check(node, node.name, _returnType(element, node.body));
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
        _returnType(element, node.functionExpression.body),
      );
    }
    super.visitFunctionDeclaration(node);
  }

  /// The return type of [element], or for a declaration that returns
  /// `dynamic`, `Object` or `Object?` (which is what Dart types one written
  /// without a return type), the first widget type its body returns.
  DartType _returnType(ExecutableElement element, FunctionBody body) {
    final type = element.returnType;
    if (type is! DynamicType && !type.isDartCoreObject) return type;
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
    // Null and Never are subtypes of every nullable type, Widget? included.
    if (type is NeverType || type is InvalidType || type.isDartCoreNull) {
      return false;
    }
    if (type is RecordType) {
      return [
        ...type.positionalFields,
        ...type.namedFields,
      ].any((field) => _returnsWidget(field.type));
    }
    if (type is InterfaceType) {
      if (type.isDartAsyncFuture ||
          type.isDartAsyncFutureOr ||
          type.isDartAsyncStream) {
        return _returnsWidget(type.typeArguments.single);
      }
      final iterable = type.asInstanceOf(result.typeProvider.iterableElement);
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
    final overridden = enclosing.getOverridden(Name(element.library.uri, name));
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

Future<void> main() async {
  final root = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..'),
  );
  final found = await findWidgetMethods(root: root);
  if (found.isEmpty) {
    stdout.writeln('No widget-returning methods.');
    return;
  }
  found.forEach(stdout.writeln);
  stdout.writeln(
    '\nA method, function or getter must not return a widget. Make it a '
    'StatelessWidget or StatefulWidget class that takes its data through '
    'constructor parameters (AGENTS.md, Engineering principles).',
  );
  exitCode = 1;
}
