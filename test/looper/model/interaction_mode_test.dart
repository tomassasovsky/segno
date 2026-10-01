import 'package:flutter_test/flutter_test.dart';
import 'package:segno/looper/model/interaction_mode.dart';
import 'package:settings_repository/settings_repository.dart';

import '../../helpers/helpers.dart';

/// Only current mode tokens are persisted; unknown tokens use Record.
void main() {
  group('InteractionMode', () {
    group('token', () {
      test('derives from the member name (new saves write "mute")', () {
        expect(InteractionMode.record.token, 'record');
        expect(InteractionMode.mute.token, 'mute');
        expect(InteractionMode.fx.token, 'fx');
        expect(InteractionMode.custom.token, 'custom');
      });
    });

    group('fromToken', () {
      test('parses the current tokens', () {
        expect(InteractionMode.fromToken('record'), InteractionMode.record);
        expect(InteractionMode.fromToken('mute'), InteractionMode.mute);
      });

      test('defaults to record for null or unknown tokens', () {
        expect(InteractionMode.fromToken(null), InteractionMode.record);
        expect(InteractionMode.fromToken('bogus'), InteractionMode.record);
        expect(InteractionMode.fromToken('play'), InteractionMode.record);
      });

      test('parses "fx" — the boot-default gate lives elsewhere', () {
        expect(InteractionMode.fromToken('fx'), InteractionMode.fx);
        expect(InteractionMode.fromToken('custom'), InteractionMode.custom);
      });
    });

    group('bootDefaultFromToken (R12)', () {
      test('passes the boot-eligible modes through unchanged', () {
        expect(
          InteractionMode.bootDefaultFromToken('record'),
          InteractionMode.record,
        );
        expect(
          InteractionMode.bootDefaultFromToken('mute'),
          InteractionMode.mute,
        );
      });

      test('boots into Record for performance-only or unknown modes', () {
        expect(
          InteractionMode.bootDefaultFromToken('fx'),
          InteractionMode.record,
        );
        expect(
          InteractionMode.bootDefaultFromToken('custom'),
          InteractionMode.record,
        );
        expect(
          InteractionMode.bootDefaultFromToken('play'),
          InteractionMode.record,
        );
      });

      test('only Record and Mute are boot defaults', () {
        expect(
          InteractionMode.bootDefaults,
          [InteractionMode.record, InteractionMode.mute],
        );
      });
    });

    group('settings persistence', () {
      test('an obsolete stored mode uses Record', () async {
        final store = FakeKeyValueStore();
        store.values['looper.default_mode'] = 'play';
        final settings = SettingsRepository(store: store);

        final loaded = InteractionMode.fromToken(
          await settings.loadDefaultInteractionMode(),
        );

        expect(loaded, InteractionMode.record);
      });

      test('a saved mute default round-trips through the repository', () async {
        final settings = SettingsRepository(store: FakeKeyValueStore());

        await settings.saveDefaultInteractionMode(InteractionMode.mute.token);

        expect(await settings.loadDefaultInteractionMode(), 'mute');
        expect(
          InteractionMode.fromToken(
            await settings.loadDefaultInteractionMode(),
          ),
          InteractionMode.mute,
        );
      });
    });
  });
}
