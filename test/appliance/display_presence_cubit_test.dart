import 'dart:async';

import 'package:brightness_client/brightness_client.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segno/appliance/display_presence_cubit.dart';
import 'package:segno/appliance/display_role.dart';

class _Outputs implements DisplayOutputs {
  final status = <String, bool?>{'HDMI-A-1': true, 'HDMI-A-2': true};

  @override
  Future<Map<String, String>> appIdConnectors() async => const {
    'dev.aquiles.segno': 'HDMI-A-1',
    'dev.aquiles.segno.waveform': 'HDMI-A-2',
  };

  @override
  Future<bool?> isConnected(String connector) async => status[connector];
}

void main() {
  test('reads each panel on its pinned connector while watching', () {
    fakeAsync((async) {
      final outputs = _Outputs();
      final cubit = DisplayPresenceCubit(outputs: outputs)..watch();
      async.flushMicrotasks();
      expect(cubit.state, isEmpty);

      outputs.status['HDMI-A-2'] = false;
      async.elapse(const Duration(seconds: 2));
      expect(cubit.state, {DisplayRole.track});

      outputs.status['HDMI-A-2'] = true;
      async.elapse(const Duration(seconds: 2));
      expect(cubit.state, isEmpty);
      unawaited(cubit.close());
    });
  });

  test('a presence that cannot be read is not called unplugged', () async {
    final outputs = _Outputs()..status['HDMI-A-1'] = null;
    final cubit = DisplayPresenceCubit(outputs: outputs);
    await cubit.refresh();
    expect(cubit.state, isEmpty);
    await cubit.close();
  });

  test('a desktop knows no connectors and reports nothing unplugged', () async {
    final cubit = DisplayPresenceCubit(outputs: const UnknownDisplayOutputs());
    await cubit.refresh();
    expect(cubit.state, isEmpty);
    await cubit.close();
  });
}
