import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';
import 'package:segno/looper/view/loop_count_words.dart';

import '../../helpers/helpers.dart';

void main() {
  testWidgets('a length reads in bars, else in beats, else uncounted '
      '(#1168)', (tester) async {
    late AppLocalizations l10n;
    await tester.pumpApp(
      Builder(
        builder: (context) {
          l10n = context.l10n;
          return const SizedBox();
        },
      ),
    );
    expect(loopCountWords(l10n, bars: 4, beats: null), (
      figure: '4',
      unit: 'bars',
      spoken: '4 bars',
    ));
    // A halved sole 1-bar loop of 4/4: 2 beats and no whole bar.
    expect(loopCountWords(l10n, bars: null, beats: 2), (
      figure: '2',
      unit: 'beats',
      spoken: '2 beats',
    ));
    expect(loopCountWords(l10n, bars: null, beats: 1).spoken, '1 beat');
    // Bars win when both are known.
    expect(loopCountWords(l10n, bars: 1, beats: 4).figure, '1');
    expect(loopCountWords(l10n, bars: null, beats: null), (
      figure: l10n.stageNoBars,
      unit: 'bars',
      spoken: 'no counted bars',
    ));
  });
}
