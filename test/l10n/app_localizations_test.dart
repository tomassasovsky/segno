import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/l10n/l10n.dart';

void main() {
  group('AppLocalizations', () {
    testWidgets('English strings resolve through context.l10n', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              l10n = context.l10n;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(l10n.appMenuLabel, 'Segno');
      expect(l10n.sessionSaveAs, 'Save as…');
      expect(l10n.trackStatePlaying, 'playing');
      expect(l10n.defaultTrackName(1), 'TRACK 1');
    });

    testWidgets('Spanish strings resolve for es locale', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              l10n = context.l10n;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(l10n.sessionSaveAs, 'Guardar como…');
      expect(l10n.trackStatePlaying, 'reproduciendo');
      expect(l10n.defaultTrackName(1), 'PISTA 1');
      expect(l10n.startEngine, 'Iniciar motor');
    });
  });

  group('trackName', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('is the name the rig gave the track', () {
      expect(l10n.trackName(const ['drums', 'bass'], 1), 'bass');
    });

    test('localizes the untouched default rather than echoing it', () {
      // A track nobody has renamed still holds the seeded `TRACK 2`, which is
      // storage, not a display string — it goes back through the localized
      // default so a Spanish rig reads PISTA 2.
      expect(l10n.trackName(const ['drums', 'TRACK 2'], 1), 'TRACK 2');
      expect(
        l10n.trackName(const ['drums', 'TRACK 2'], 1),
        l10n.defaultTrackName(2),
      );
    });

    test('falls back rather than throwing on an absent channel', () {
      // A stale binding names a track the rig no longer has; a row that still
      // says what it used to drive beats a crash.
      expect(l10n.trackName(const ['drums'], 7), l10n.defaultTrackName(8));
      expect(l10n.trackName(const [], 0), l10n.defaultTrackName(1));
      expect(l10n.trackName(const ['drums'], -1), l10n.defaultTrackName(0));
    });
  });

  group('inputName', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('is the name the player gave the socket', () {
      expect(l10n.inputName(const {0: 'guitar', 1: 'mic'}, 1), 'mic');
    });

    test('an unnamed socket falls back to its ordinal', () {
      // A socket with no name is ABSENT from the map rather than empty, so
      // the resolver is the one place that turns "nothing stored" into words.
      expect(l10n.inputName(const {0: 'guitar'}, 1), l10n.inputChannelLabel(2));
      expect(l10n.inputName(const {}, 0), l10n.inputChannelLabel(1));
      // A stored empty string reads the same way, so a half-written value can
      // never render as a blank name.
      expect(l10n.inputName(const {1: ''}, 1), l10n.inputChannelLabel(2));
    });

    test('falls back rather than throwing on an absent socket', () {
      // A session saved on an eight-in rig still routes In 6 when it is
      // reopened on a two-in one, and that lane's row has to say something.
      expect(l10n.inputName(const {0: 'guitar'}, 5), l10n.inputChannelLabel(6));
      expect(
        l10n.inputName(const {0: 'guitar'}, -1),
        l10n.inputChannelLabel(0),
      );
    });
  });

  group('outputName and outputBusLabel', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('a destination is a PAIR of jacks, named as one thing', () {
      // Bus 1 drives outputs 3 and 4. Labelling it "Out 3" would name half a
      // cable pair, and every routing surface would have to guess the other.
      expect(l10n.outputBusLabel(0, channels: 4), l10n.outputPairLabel(1, 2));
      expect(l10n.outputBusLabel(1, channels: 4), l10n.outputPairLabel(3, 4));
    });

    test('an odd-channel device ends on a single jack, labelled as one', () {
      // A five-out interface has no output 6, and a destination card must not
      // promise a socket the rig has not got.
      expect(l10n.outputBusLabel(2, channels: 5), l10n.outputSingleLabel(5));
      expect(l10n.outputBusLabel(1, channels: 5), l10n.outputPairLabel(3, 4));
    });

    test('is the name the player gave the destination', () {
      expect(
        l10n.outputName(const {0: 'mains', 1: 'monitors'}, 1, channels: 4),
        'monitors',
      );
    });

    test('an unnamed destination falls back to its jack numbers', () {
      expect(
        l10n.outputName(const {0: 'mains'}, 1, channels: 4),
        l10n.outputPairShort(3, 4),
      );
      // A stored empty string reads the same way, so a half-written value can
      // never render as a blank name.
      expect(
        l10n.outputName(const {1: ''}, 1, channels: 4),
        l10n.outputPairShort(3, 4),
      );
      // And the short form is not the full label: a card carries both lines.
      expect(
        l10n.outputName(const {}, 0, channels: 4),
        isNot(l10n.outputBusLabel(0, channels: 4)),
      );
    });

    test('falls back rather than throwing past the rig it is shown on', () {
      // A session saved on a wider rig still routes to a destination this one
      // has not got, and that row has to say something.
      expect(
        l10n.outputName(const {0: 'mains'}, 4, channels: 4),
        l10n.outputChannelLabel(9),
      );
    });
  });

  group('the console explains its controls', () {
    testWidgets('an explanation uses the words of the control it explains', (
      tester,
    ) async {
      late AppLocalizations en;
      late AppLocalizations es;
      for (final locale in const [Locale('en'), Locale('es')]) {
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                if (locale.languageCode == 'en') {
                  en = context.l10n;
                } else {
                  es = context.l10n;
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }

      // Spanish agrees for gender, so an explanation translated without its
      // control in view says "Silenciado" over a segment reading
      // "silenciada". It reads as being about something else on the screen.
      for (final l10n in [en, es]) {
        expect(
          l10n.signalPanelInMixExplain.toLowerCase(),
          contains(l10n.signalMixMuted.toLowerCase()),
          reason: "the muted/heard explanation must use the segment's word",
        );
      }
    });
  });
}
