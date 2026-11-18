// The methods keep the C names of the calls they make.
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';

import 'package:segno_engine/segno_engine_ffi.dart' as native;
import 'package:segno_engine/segno_engine_ffi.dart'
    show le_midi, le_midi_event_cb, le_midi_info, le_midi_out;

/// The `le_midi_*` and `le_midi_out_*` calls `MidiClient` and
/// `MidiOutClient` make, as one object a test can replace.
///
/// The default forwards to the engine's `@Native` bindings.
class MidiBindings {
  /// Creates the [MidiBindings] that call the engine library.
  const new();

  /// `le_midi_create`.
  Pointer<le_midi> le_midi_create() => native.le_midi_create();

  /// `le_midi_destroy`.
  void le_midi_destroy(Pointer<le_midi> m) => native.le_midi_destroy(m);

  /// `le_midi_enumerate`.
  int le_midi_enumerate(
    Pointer<le_midi_info> out,
    int max,
    Pointer<Int32> count,
  ) => native.le_midi_enumerate(out, max, count);

  /// `le_midi_open`.
  int le_midi_open(Pointer<le_midi> m, Pointer<Char> id, le_midi_event_cb cb) =>
      native.le_midi_open(m, id, cb);

  /// `le_midi_close`.
  int le_midi_close(Pointer<le_midi> m) => native.le_midi_close(m);

  /// `le_midi_out_create`.
  Pointer<le_midi_out> le_midi_out_create() => native.le_midi_out_create();

  /// `le_midi_out_destroy`.
  void le_midi_out_destroy(Pointer<le_midi_out> m) =>
      native.le_midi_out_destroy(m);

  /// `le_midi_out_enumerate`.
  int le_midi_out_enumerate(
    Pointer<le_midi_info> out,
    int max,
    Pointer<Int32> count,
  ) => native.le_midi_out_enumerate(out, max, count);

  /// `le_midi_out_open`.
  int le_midi_out_open(Pointer<le_midi_out> m, Pointer<Char> id) =>
      native.le_midi_out_open(m, id);

  /// `le_midi_out_close`.
  int le_midi_out_close(Pointer<le_midi_out> m) => native.le_midi_out_close(m);

  /// `le_midi_out_send`.
  int le_midi_out_send(Pointer<le_midi_out> m, Pointer<Uint8> data, int len) =>
      native.le_midi_out_send(m, data, len);
}
