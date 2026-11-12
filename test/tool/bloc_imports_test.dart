import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// bloc_lint's `avoid_flutter_imports` keeps Flutter out of blocs and cubits,
/// but it matches only `package:flutter/`. Material and Cupertino now come
/// from their own packages, so this test covers those imports, and
/// routing_graph's, which re-exports material_ui.
void main() {
  test('no bloc or cubit imports material_ui or cupertino_ui', () {
    final offenders = [
      for (final root in [
        Directory('lib'),
        ...Directory('packages')
            .listSync()
            .whereType<Directory>()
            .map((package) => Directory('${package.path}/lib')),
      ])
        if (root.existsSync())
          for (final file in root.listSync(recursive: true))
            if (file is File &&
                (file.path.endsWith('_bloc.dart') ||
                    file.path.endsWith('_cubit.dart')) &&
                RegExp(
                  "^import 'package:(material_ui|cupertino_ui|routing_graph)/",
                  multiLine: true,
                ).hasMatch(file.readAsStringSync()))
              file.path,
    ];
    expect(offenders, isEmpty);
  });
}
