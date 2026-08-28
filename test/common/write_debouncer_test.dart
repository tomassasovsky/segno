import 'package:flutter_test/flutter_test.dart';
import 'package:segno/common/write_debouncer.dart';

void main() {
  const debounce = Duration(milliseconds: 30);

  test('coalesces a burst on one key into a single trailing write', () async {
    final written = <int>[];
    final debouncer = WriteDebouncer(debounce: debounce);

    for (var i = 0; i < 5; i++) {
      debouncer.schedule('k', () => written.add(i));
    }
    expect(written, isEmpty);

    await Future<void>.delayed(debounce * 3);

    // The LAST closure, not the first: a coalesced burst persists the value
    // the user let go on.
    expect(written, [4]);
  });

  test('keys are independent', () async {
    final written = <String>[];
    WriteDebouncer(debounce: debounce)
      ..schedule('a', () => written.add('a'))
      ..schedule('b', () => written.add('b'));

    await Future<void>.delayed(debounce * 3);

    expect(written, unorderedEquals(['a', 'b']));
  });

  test('a zero debounce writes straight through, arming no timer', () {
    final written = <String>[];
    WriteDebouncer(debounce: Duration.zero)
      ..schedule('a', () => written.add('a'))
      ..schedule('a', () => written.add('a again'));

    expect(written, ['a', 'a again']);
  });

  test('flush runs everything pending at once', () {
    final written = <String>[];
    final debouncer = WriteDebouncer(debounce: const Duration(minutes: 1))
      ..schedule('a', () => written.add('a'))
      ..schedule('b', () => written.add('b'))
      ..flush();

    expect(written, unorderedEquals(['a', 'b']));
    // And a flushed entry does not fire again when its timer comes due.
    debouncer.flush();
    expect(written, hasLength(2));
  });

  test('cancelAll drops pending writes without running them', () async {
    final written = <String>[];
    final debouncer = WriteDebouncer(debounce: debounce)
      ..schedule('a', () => written.add('a'))
      ..cancelAll();

    await Future<void>.delayed(debounce * 3);

    expect(written, isEmpty);

    // And the debouncer is still usable afterwards.
    debouncer.schedule('a', () => written.add('later'));
    await Future<void>.delayed(debounce * 3);
    expect(written, ['later']);
  });
}
