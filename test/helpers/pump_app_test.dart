import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/theme/theme.dart';

import 'helpers.dart';

/// How many times the probe below has been mounted this test.
int _mounts = 0;

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _mounts++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// `pumpApp`'s flavor-swap contract (#768).
///
/// `MaterialApp` wraps its theme in an `AnimatedTheme`, so re-pumping a
/// mounted app with a different flavor INTERPOLATES: the first pumped frame
/// still resolves the outgoing flavor's tokens. That used to be a rule
/// callers had to remember, and forgetting it did not fail — it passed, but
/// against the wrong palette. The helper now unmounts on a flavor change so
/// the hazard cannot be reached.
void main() {
  setUp(() => _mounts = 0);

  SurfaceTheme resolved(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(_Probe))).extension<SurfaceTheme>()!;

  testWidgets('a flavor swap resolves the NEW flavor on the pumped frame', (
    tester,
  ) async {
    await tester.pumpApp(const _Probe());
    expect(resolved(tester).accent, SurfaceTheme.dark.accent);

    await tester.pumpApp(const _Probe(), theme: AppTheme.highContrast);

    // Without the helper's unmount this reads a value part-way between the
    // two flavors — the assertion a caller writes here is against tokens
    // nothing ever ships.
    expect(resolved(tester).accent, SurfaceTheme.highContrast.accent);
    expect(_mounts, 2, reason: 'a flavor change remounts');
  });

  testWidgets('re-pumping the same flavor keeps the element tree', (
    tester,
  ) async {
    // The other half of the contract: pumping to push new state must NOT
    // throw the tree away, or every test that re-pumps loses its state.
    await tester.pumpApp(const _Probe());
    await tester.pumpApp(const _Probe());
    await tester.pumpApp(const _Probe(), theme: AppTheme.neon);

    expect(_mounts, 1);
  });
}
