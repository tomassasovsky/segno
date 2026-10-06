import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:segno_engine/src/audio_device.dart';
import 'package:segno_engine/src/audio_engine.dart';
import 'package:segno_engine/src/engine_config.dart';
import 'package:segno_engine/src/engine_snapshot.dart';
import 'package:segno_engine/src/ffi_strings.dart';
import 'package:segno_engine/src/fx_recipe.dart';
import 'package:segno_engine/src/generated/segno_engine_bindings.dart';
import 'package:segno_engine/src/history_entry.dart';
import 'package:segno_engine/src/input_conditioning_param.dart';
import 'package:segno_engine/src/lane_cache.dart';
import 'package:segno_engine/src/loopback_info.dart';
import 'package:segno_engine/src/mix_settings.dart';
import 'package:segno_engine/src/output_fx_snapshot.dart';
import 'package:segno_engine/src/performance_render_progress.dart';
import 'package:segno_engine/src/plugin_descriptor.dart';
import 'package:segno_engine/src/track_effect.dart';

/// Opens the bundled native engine library for the current platform.
///
/// On Apple platforms the engine is compiled directly into the application
/// binary (Swift Package Manager static-links the plugin into the Runner; the
/// CocoaPods fallback embeds it as a framework). In both cases its exported
/// symbols live in the process's global namespace, so [DynamicLibrary.process]
/// resolves them — there is no standalone library file to open. This relies on
/// the `LE_EXPORT` symbols being marked `visibility("default")` + `used` so the
/// linker keeps them. See macos/segno_engine/Package.swift.
///
/// On Linux/Windows the engine is a separate shared library opened by name.
///
/// A `SEGNO_ENGINE_LIB` environment variable overrides the lookup with an
/// explicit path on every platform — how the device-free test suites (the
/// sequence fuzzer via [PumpedNativeEngine]) point at a freshly built library
/// outside an app bundle.
DynamicLibrary _openLibrary() {
  final override = Platform.environment['SEGNO_ENGINE_LIB'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isWindows) return DynamicLibrary.open('segno_engine.dll');
  return DynamicLibrary.open('libsegno_engine.so');
}

/// Production [AudioEngine] that drives the native miniaudio engine over FFI.
///
/// Owns a single native engine handle. Exactly one instance should own the
/// audio device at a time (the main isolate); the visualizer window consumes
/// pushed frames rather than sharing this handle.
class NativeAudioEngine implements AudioEngine {
  /// Creates a [NativeAudioEngine], loading the bundled native library and
  /// allocating the underlying engine.
  ///
  /// [bindings] may be injected (e.g. against a statically linked test binary);
  /// when omitted, the platform shared library is opened.
  NativeAudioEngine({SegnoEngineBindings? bindings})
    : _bindings = bindings ?? SegnoEngineBindings(_openLibrary()) {
    _engine = _bindings.le_engine_create();
    if (_engine == nullptr) {
      throw const EngineException(
        EngineResult.invalid,
        'failed to allocate native engine',
      );
    }
    _snapshotPtr = calloc<le_snapshot>();
    _telemetryPtr = calloc<le_callback_telemetry>();
    _trackPtr = calloc<le_track_snapshot>();
    _lanePtr = calloc<le_lane_snapshot>();
    _cachesPtr = calloc<le_lane_cache_info>(LE_MAX_TRACKS * LE_MAX_LANES);
    _vizPtr = calloc<Float>(LE_VIZ_POINTS);
  }

  /// Capacity of the device-enumeration buffer; devices beyond this are not
  /// reported (far more than any realistic host exposes).
  static const int _maxDevices = 64;

  /// Fixed size of the native `asio_buffer_sizes[8]`/`asio_sample_rates[8]`
  /// arrays (see `le_device_info` in segno_engine_api.h). The accompanying
  /// `asio_buffer_count`/`asio_sample_rate_count` fields are clamped to this
  /// before being used as loop bounds so an out-of-range native count can
  /// never read past the fixed-size arrays (mirrors the defensive clamp in
  /// [pluginStateGet]).
  static const int _maxAsioSlots = 8;

  final SegnoEngineBindings _bindings;
  late final Pointer<le_engine> _engine;
  late final Pointer<le_snapshot> _snapshotPtr;
  late final Pointer<le_callback_telemetry> _telemetryPtr;
  late final Pointer<le_track_snapshot> _trackPtr;
  late final Pointer<le_lane_snapshot> _lanePtr;
  late final Pointer<le_lane_cache_info> _cachesPtr;
  late final Pointer<Float> _vizPtr;
  bool _disposed = false;

  void _checkAlive() {
    if (_disposed) {
      throw const EngineException(
        EngineResult.invalid,
        'engine has been disposed',
      );
    }
  }

  @override
  String get version => _bindings.le_version().cast<Utf8>().toDartString();

  @override
  String get deviceName {
    _checkAlive();
    return _bindings.le_engine_device_name(_engine).cast<Utf8>().toDartString();
  }

  @override
  EngineResult start(EngineConfig config) {
    _checkAlive();
    final cfgPtr = calloc<le_config>();
    try {
      config.writeTo(cfgPtr);
      return EngineResult.fromCode(_bindings.le_engine_start(_engine, cfgPtr));
    } finally {
      calloc.free(cfgPtr);
    }
  }

  @override
  EngineResult stop() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_stop(_engine));
  }

  @override
  ReopenResult reopen(EngineConfig config) {
    _checkAlive();
    final cfgPtr = calloc<le_config>();
    final outcomePtr = calloc<Int32>();
    final droppedPtr = calloc<Int32>();
    try {
      config.writeTo(cfgPtr);
      // RETAINED (0), nothing dropped, until the native side writes a
      // decision: a failed open never reaches the settle step and leaves the
      // material in place.
      outcomePtr.value = 0;
      droppedPtr.value = 0;
      final result = EngineResult.fromCode(
        _bindings.le_engine_reopen(_engine, cfgPtr, outcomePtr, droppedPtr),
      );
      return (
        result: result,
        outcome: ReopenOutcome.fromCode(outcomePtr.value),
        droppedTracks: droppedPtr.value,
      );
    } finally {
      calloc
        ..free(cfgPtr)
        ..free(outcomePtr)
        ..free(droppedPtr);
    }
  }

  @override
  bool get commandsSettled {
    _checkAlive();
    return _bindings.le_engine_commands_settled(_engine) != 0;
  }

  @override
  EngineSnapshot snapshot() {
    _checkAlive();
    _bindings.le_engine_get_snapshot(_engine, _snapshotPtr);
    final count = _snapshotPtr.ref.track_count;
    final tracks = <TrackSnapshot>[];
    for (var i = 0; i < count; i++) {
      _bindings.le_engine_get_track(_engine, i, _trackPtr);
      // The native track snapshot can't expose its lane array directly over
      // this ffi version, so read each active lane individually.
      final laneCount = _trackPtr.ref.lane_count;
      final lanes = <LaneSnapshot>[];
      for (var l = 0; l < laneCount; l++) {
        _bindings.le_engine_get_lane(_engine, i, l, _lanePtr);
        lanes.add(LaneSnapshot.fromNative(_lanePtr.ref));
      }
      // The full snapshot owns this read's timing tuple. A callback between
      // the full and standalone track reads must not mix two timing vectors.
      final timing = _snapshotPtr.ref.record_timing_overrides[i];
      _trackPtr.ref
        ..quantize_override = timing < 0 ? -1 : (timing == 0 ? 0 : 1)
        ..quantize_div_override = timing < 0
            ? -1
            : (timing == 0 ? 0 : timing - 1);
      tracks.add(TrackSnapshot.fromNative(_trackPtr.ref, lanes));
    }
    return EngineSnapshot.fromNative(_snapshotPtr.ref, tracks);
  }

  @override
  CallbackTelemetry callbackTelemetry() {
    _checkAlive();
    // Its own native entry point, not a block on `le_snapshot`. Two reasons,
    // both deliberate: keeping the telemetry off the snapshot is what stops a
    // per-callback counter from ever reaching the render-rate projection (see
    // [CallbackTelemetry]); and `le_engine_get_snapshot` has a SIDE EFFECT —
    // it drains the engine's event ring, collecting retired undo layers —
    // which a diagnostic read has no business triggering. This call is pure
    // relaxed atomic loads, with no track or lane walk.
    _bindings.le_engine_get_callback_telemetry(_engine, _telemetryPtr);
    return CallbackTelemetry.fromNative(_telemetryPtr.ref);
  }

  @override
  LoopbackInfo detectLoopback() {
    final ptr = calloc<le_loopback_info>();
    try {
      // Returns LE_OK on success; on failure it still zero-fills the struct
      // (available == 0), so mapping the result is safe either way.
      _bindings.le_detect_loopback(ptr);
      return LoopbackInfo.fromNative(ptr);
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  List<AudioDevice> enumerateDevices() {
    _checkAlive();
    return [
      ..._enumerate(isInput: false),
      ..._enumerate(isInput: true),
    ];
  }

  /// Reads one direction's devices via the matching native enumeration call.
  /// Capacity is fixed; any devices beyond [_maxDevices] are not reported.
  List<AudioDevice> _enumerate({required bool isInput}) {
    final outPtr = calloc<le_device_info>(_maxDevices);
    final countPtr = calloc<Int32>();
    try {
      final code = isInput
          ? _bindings.le_enumerate_capture_devices(
              outPtr,
              _maxDevices,
              countPtr,
            )
          : _bindings.le_enumerate_playback_devices(
              outPtr,
              _maxDevices,
              countPtr,
            );
      if (code != 0) return const [];
      final count = countPtr.value;
      return [
        for (var i = 0; i < count; i++)
          AudioDevice(
            id: readNativeString((outPtr + i).ref.id),
            name: readNativeString((outPtr + i).ref.name),
            isDefault: (outPtr + i).ref.is_default != 0,
            isInput: isInput,
            inputChannels: (outPtr + i).ref.input_channels,
            outputChannels: (outPtr + i).ref.output_channels,
          ),
      ];
    } finally {
      calloc
        ..free(outPtr)
        ..free(countPtr);
    }
  }

  @override
  List<AudioDevice> enumerateAsioDrivers() {
    _checkAlive();
    // Modeled on _enumerate, but the native call returns DUPLEX drivers (one
    // driver = all I/O), so each result is tagged isInput: false and carries the
    // probed channel counts rather than being split by direction. Off Windows /
    // on the default build the native symbol is a stub returning 0 drivers.
    final outPtr = calloc<le_device_info>(_maxDevices);
    final countPtr = calloc<Int32>();
    try {
      final code = _bindings.le_enumerate_asio_drivers(
        outPtr,
        _maxDevices,
        countPtr,
      );
      if (code != 0) return const [];
      final count = countPtr.value;
      return [
        for (var i = 0; i < count; i++)
          AudioDevice(
            id: readNativeString((outPtr + i).ref.id),
            name: readNativeString((outPtr + i).ref.name),
            isDefault: (outPtr + i).ref.is_default != 0,
            isInput: false,
            inputChannels: (outPtr + i).ref.input_channels,
            outputChannels: (outPtr + i).ref.output_channels,
            // Clamp both counts to the arrays' fixed size before using them
            // as loop bounds: dart:ffi's Array<T> does no bounds checking, so
            // an out-of-range native count would otherwise read past the
            // 8-slot arrays into adjacent struct memory.
            bufferSizes: [
              for (
                var b = 0;
                b < _clampAsioCount((outPtr + i).ref.asio_buffer_count);
                b++
              )
                (outPtr + i).ref.asio_buffer_sizes[b],
            ],
            sampleRates: [
              for (
                var s = 0;
                s < _clampAsioCount((outPtr + i).ref.asio_sample_rate_count);
                s++
              )
                (outPtr + i).ref.asio_sample_rates[s],
            ],
          ),
      ];
    } finally {
      calloc
        ..free(outPtr)
        ..free(countPtr);
    }
  }

  /// Clamps a native ASIO buffer/sample-rate count to [_maxAsioSlots] so it
  /// is always safe to use as a bound when indexing the fixed-size
  /// `asio_buffer_sizes`/`asio_sample_rates` arrays.
  static int _clampAsioCount(int count) =>
      count < _maxAsioSlots ? count : _maxAsioSlots;

  @override
  EngineResult scanBegin({bool rescan = false}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_plugin_scan_begin(_engine, rescan ? 1 : 0),
    );
  }

  @override
  PluginScanProgress scanPoll() {
    _checkAlive();
    final donePtr = calloc<Int32>();
    final foundPtr = calloc<Int32>();
    final scannedPtr = calloc<Int32>();
    final totalPtr = calloc<Int32>();
    try {
      _bindings.le_plugin_scan_poll(
        _engine,
        donePtr,
        foundPtr,
        scannedPtr,
        totalPtr,
      );
      return PluginScanProgress(
        done: donePtr.value != 0,
        found: foundPtr.value,
        scanned: scannedPtr.value,
        total: totalPtr.value,
      );
    } finally {
      calloc
        ..free(donePtr)
        ..free(foundPtr)
        ..free(scannedPtr)
        ..free(totalPtr);
    }
  }

  @override
  List<PluginDescriptor> scanResults() {
    _checkAlive();
    // The native `found` count is monotonic, so polling it here bounds the read
    // to the entries published so far — a mid-scan call returns a valid prefix,
    // a post-`done` call returns the full set.
    final found = scanPoll().found;
    if (found <= 0) return const [];
    final descPtr = calloc<le_plugin_desc>();
    try {
      final result = <PluginDescriptor>[];
      for (var i = 0; i < found; i++) {
        if (_bindings.le_plugin_scan_get(_engine, i, descPtr) != 0) continue;
        result.add(
          PluginDescriptor(
            id: readNativeString(descPtr.ref.id),
            name: readNativeString(descPtr.ref.name, capacity: 128),
            vendor: readNativeString(descPtr.ref.vendor, capacity: 128),
            path: readNativeString(descPtr.ref.path, capacity: 1024),
            format: PluginFormat.fromCode(descPtr.ref.format),
            version: descPtr.ref.version,
          ),
        );
      }
      return result;
    } finally {
      calloc.free(descPtr);
    }
  }

  @override
  EngineResult scanCancel() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_plugin_scan_cancel(_engine));
  }

  @override
  PluginSlotHandle? preparePlugin({required String pluginId}) => _loadPlugin(
    pluginId,
    (id, out) => _bindings.le_engine_prepare_plugin(_engine, id, out),
  );

  @override
  EngineResult discardPreparedPlugin(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(
      _bindings.le_engine_discard_prepared_plugin(_engine, slot.pointer),
    );
  }

  @override
  EngineResult preparePluginParam(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(
      _bindings.le_engine_prepare_plugin_param(
        _engine,
        slot.pointer,
        paramId,
        value,
      ),
    );
  }

  bool _writeFxRecipe(le_fx_recipe target, FxRecipe recipe) {
    if (!recipe.isValid) return false;
    target
      ..count = recipe.slots.length
      ..pre_count = recipe.preCount
      ..enabled = recipe.enabled ? 1 : 0;
    for (var i = 0; i < recipe.slots.length; i++) {
      final slot = recipe.slots[i];
      final plugin = slot.plugin;
      if (plugin != null && plugin is! _NativePluginSlotHandle) return false;
      target.type[i] = plugin == null ? slot.type.code : kPluginFxCode;
      target.plugin[i] = plugin == null
          ? nullptr
          : (plugin as _NativePluginSlotHandle).pointer;
      target.slot_enabled[i] = slot.enabled ? 1 : 0;
      for (var p = 0; p < slot.params.length; p++) {
        target.params[i][p] = slot.params[p];
      }
      target.input_mode[i] = slot.channels.input.index;
      target.output_mode[i] = slot.channels.output.index;
      target.placement[i] = slot.channels.placement;
      target.level[i] = slot.channels.level;
    }
    return true;
  }

  @override
  EngineResult setFxRecipe({
    required FxOwner owner,
    required FxRecipe recipe,
    required int revision,
    int channel = 0,
    int lane = 0,
  }) {
    _checkAlive();
    if (revision <= 0 || revision > 0xffffffff) return EngineResult.invalid;
    final ptr = calloc<le_fx_recipe>();
    try {
      if (!_writeFxRecipe(ptr.ref, recipe)) return EngineResult.invalid;
      return EngineResult.fromCode(
        _bindings.le_engine_set_fx_recipe(
          _engine,
          owner.index,
          channel,
          lane,
          revision,
          ptr,
        ),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  int fxRecipeRevision({
    required FxOwner owner,
    int channel = 0,
    int lane = 0,
  }) {
    _checkAlive();
    return _bindings.le_engine_fx_recipe_revision(
      _engine,
      owner.index,
      channel,
      lane,
    );
  }

  @override
  PluginSlotHandle? setLanePlugin({
    required int channel,
    required int lane,
    required int index,
    required String pluginId,
  }) => _loadPlugin(
    pluginId,
    (idPtr, outSlot) => _bindings.le_engine_set_lane_plugin(
      _engine,
      channel,
      lane,
      index,
      idPtr,
      outSlot,
    ),
  );

  @override
  PluginSlotHandle? setMonitorPlugin({
    required int input,
    required int index,
    required String pluginId,
  }) => _loadPlugin(
    pluginId,
    (idPtr, outSlot) => _bindings.le_engine_set_monitor_plugin(
      _engine,
      input,
      index,
      idPtr,
      outSlot,
    ),
  );

  /// Shared marshalling for the two plugin-load calls: passes [pluginId] as a C
  /// string + an out-slot pointer to [call], and wraps the published handle.
  PluginSlotHandle? _loadPlugin(
    String pluginId,
    int Function(Pointer<Char> idPtr, Pointer<Pointer<le_plugin_slot>> outSlot)
    call,
  ) {
    _checkAlive();
    final idPtr = pluginId.toNativeUtf8();
    final outSlot = calloc<Pointer<le_plugin_slot>>();
    try {
      final code = call(idPtr.cast(), outSlot);
      if (code != 0) return null;
      return _NativePluginSlotHandle(outSlot.value);
    } finally {
      malloc.free(idPtr);
      calloc.free(outSlot);
    }
  }

  @override
  EngineResult clearLanePlugin({
    required int channel,
    required int lane,
    required int index,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_clear_lane_plugin(_engine, channel, lane, index),
    );
  }

  @override
  EngineResult clearMonitorPlugin({required int input, required int index}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_clear_monitor_plugin(_engine, input, index),
    );
  }

  @override
  List<PluginParamInfo> pluginParamInfos(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return const [];
    final countPtr = calloc<Int32>();
    final infoPtr = calloc<le_plugin_param_info>();
    try {
      if (_bindings.le_plugin_param_count(slot.pointer, countPtr) != 0) {
        return const [];
      }
      final count = countPtr.value;
      final result = <PluginParamInfo>[];
      for (var i = 0; i < count; i++) {
        if (_bindings.le_plugin_param_info_at(slot.pointer, i, infoPtr) != 0) {
          continue;
        }
        result.add(
          PluginParamInfo(
            id: infoPtr.ref.id,
            name: readNativeString(infoPtr.ref.name, capacity: 128),
            unit: readNativeString(infoPtr.ref.unit, capacity: 32),
            min: infoPtr.ref.min,
            max: infoPtr.ref.max,
            def: infoPtr.ref.def,
            stepCount: infoPtr.ref.step_count,
            flags: infoPtr.ref.flags,
          ),
        );
      }
      return result;
    } finally {
      calloc
        ..free(countPtr)
        ..free(infoPtr);
    }
  }

  @override
  double pluginParamGet(PluginSlotHandle slot, int paramId) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return 0;
    final out = calloc<Double>();
    try {
      if (_bindings.le_plugin_param_get(slot.pointer, paramId, out) != 0) {
        return 0;
      }
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  @override
  String? pluginParamValueText(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return null;
    const capacity = 128;
    final out = calloc<Char>(capacity);
    try {
      final code = _bindings.le_plugin_param_value_text(
        slot.pointer,
        paramId,
        value,
        out,
        capacity,
      );
      if (code != 0) return null; // unsupported / invalid -> no text
      return out.cast<Utf8>().toDartString();
    } finally {
      calloc.free(out);
    }
  }

  @override
  EngineResult pluginParamSet(
    PluginSlotHandle slot,
    int paramId,
    double value,
  ) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(
      _bindings.le_plugin_param_set(slot.pointer, paramId, value),
    );
  }

  @override
  EngineResult pluginEditorOpen(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(_bindings.le_plugin_editor_open(slot.pointer));
  }

  @override
  EngineResult pluginEditorClose(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    return EngineResult.fromCode(
      _bindings.le_plugin_editor_close(slot.pointer),
    );
  }

  @override
  bool pluginEditorIsOpen(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return false;
    final out = calloc<Int32>();
    try {
      if (_bindings.le_plugin_editor_is_open(slot.pointer, out) != 0) {
        return false;
      }
      return out.value != 0;
    } finally {
      calloc.free(out);
    }
  }

  @override
  Uint8List pluginStateGet(PluginSlotHandle slot) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return Uint8List(0);
    final sizePtr = calloc<Int32>();
    try {
      if (_bindings.le_plugin_state_size(slot.pointer, sizePtr) != 0) {
        return Uint8List(0);
      }
      final size = sizePtr.value;
      if (size <= 0) return Uint8List(0);
      final buf = calloc<Uint8>(size);
      final written = calloc<Int32>();
      try {
        if (_bindings.le_plugin_state_get(slot.pointer, buf, size, written) !=
            0) {
          return Uint8List(0);
        }
        // Copy out of native memory before it's freed. Clamp to the allocated
        // size: `buf` was sized from le_plugin_state_size, but `written` comes
        // from le_plugin_state_get's own (later) size query — if the plugin's
        // state grew between the two calls, an unclamped length would read past
        // the buffer.
        final n = written.value < size ? written.value : size;
        return Uint8List.fromList(buf.asTypedList(n));
      } finally {
        calloc
          ..free(buf)
          ..free(written);
      }
    } finally {
      calloc.free(sizePtr);
    }
  }

  @override
  EngineResult pluginStateSet(PluginSlotHandle slot, Uint8List state) {
    _checkAlive();
    if (slot is! _NativePluginSlotHandle) return EngineResult.invalid;
    if (state.isEmpty) {
      return EngineResult.fromCode(
        _bindings.le_plugin_state_set(slot.pointer, nullptr, 0),
      );
    }
    final buf = calloc<Uint8>(state.length);
    try {
      buf.asTypedList(state.length).setAll(0, state);
      return EngineResult.fromCode(
        _bindings.le_plugin_state_set(slot.pointer, buf, state.length),
      );
    } finally {
      calloc.free(buf);
    }
  }

  @override
  EngineResult measureLatency() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_measure_latency(_engine));
  }

  @override
  RequestAdmission toggleFade({required int channel, required double seconds}) {
    _checkAlive();
    final request = calloc<Uint64>();
    try {
      final result = EngineResult.fromCode(
        _bindings.le_engine_toggle_fade(_engine, channel, seconds, request),
      );
      return (result: result, request: request.value);
    } finally {
      calloc.free(request);
    }
  }

  @override
  RequestAdmission installFade({
    required int channel,
    required FadeImage image,
  }) {
    _checkAlive();
    final request = calloc<Uint64>();
    final value = calloc<le_fade_image>();
    try {
      value.ref
        ..amount = image.amount
        ..target = image.target
        ..full_travel_seconds = image.fullTravelSeconds
        ..lifetime = image.lifetime
        ..generation = image.generation;
      final result = EngineResult.fromCode(
        _bindings.le_engine_install_fade(_engine, channel, value, request),
      );
      return (result: result, request: request.value);
    } finally {
      calloc
        ..free(value)
        ..free(request);
    }
  }

  @override
  RequestAdmission toggleReverse({required int channel}) {
    _checkAlive();
    final request = calloc<Uint64>();
    try {
      final result = EngineResult.fromCode(
        _bindings.le_engine_toggle_reverse(_engine, channel, request),
      );
      return (result: result, request: request.value);
    } finally {
      calloc.free(request);
    }
  }

  @override
  RequestAdmission installReverse({
    required int channel,
    required bool reversed,
  }) {
    _checkAlive();
    final request = calloc<Uint64>();
    try {
      final result = EngineResult.fromCode(
        _bindings.le_engine_install_reverse(
          _engine,
          channel,
          reversed ? 1 : 0,
          request,
        ),
      );
      return (result: result, request: request.value);
    } finally {
      calloc.free(request);
    }
  }

  @override
  EngineResult? readRequestResult(int request) {
    _checkAlive();
    final result = calloc<Int32>();
    try {
      final status = EngineResult.fromCode(
        _bindings.le_engine_read_request_result(_engine, request, result),
      );
      if (status == EngineResult.notReady) return null;
      return status.isOk ? EngineResult.fromCode(result.value) : status;
    } finally {
      calloc.free(result);
    }
  }

  @override
  EngineResult setMix(EngineMixSettings settings) {
    _checkAlive();
    if (!settings.isValid) return EngineResult.invalid;
    final ptr = calloc<le_mix_settings>();
    try {
      final native = ptr.ref..revision = settings.revision;
      for (final entry in settings.trackLevels.entries) {
        native.track_gain_mask |= 1 << entry.key;
        native.track_gain[entry.key] = entry.value;
      }
      for (final entry in settings.lanes.entries) {
        final i = entry.key.$1 * kMaxLanes + entry.key.$2;
        native.lane_mask |= 1 << i;
        native.lane_gain[i] = entry.value.gain;
        native.lane_pan[i] = entry.value.pan;
      }
      for (final entry in settings.images.entries) {
        final i = entry.key.$1 * kMaxLanes + entry.key.$2;
        native.image_mask |= 1 << i;
        native.image_gain[i] = entry.value.gain;
        native.image_pan[i] = entry.value.pan;
      }
      for (final entry in settings.monitors.entries) {
        native.monitor_mask |= 1 << entry.key;
        native.monitor_gain[entry.key] = entry.value.gain;
        native.monitor_pan[entry.key] = entry.value.pan;
      }
      for (final entry in settings.trims.entries) {
        native.trim_mask |= 1 << entry.key;
        native.input_trim[entry.key] = entry.value;
      }
      for (final entry in settings.solos.entries) {
        native.solo_mask |= 1 << entry.key;
        if (entry.value) native.solo_values |= 1 << entry.key;
      }
      for (final entry in settings.outputs.entries) {
        native.output_mask |= 1 << entry.key;
        native.output_level[entry.key] = entry.value.level;
        native.output_balance[entry.key] = entry.value.balance;
        if (entry.value.muted) native.output_muted |= 1 << entry.key;
        if (entry.value.mono) native.output_mono |= 1 << entry.key;
      }
      for (final entry in settings.laneInputs.entries) {
        final i = entry.key.$1 * kMaxLanes + entry.key.$2;
        native.routing_input_mask |= 1 << i;
        native.lane_input[i] = entry.value;
      }
      for (final entry in settings.laneOutputs.entries) {
        final i = entry.key.$1 * kMaxLanes + entry.key.$2;
        native.routing_output_mask |= 1 << i;
        native.lane_output[i] = entry.value;
      }
      for (final entry in settings.laneCounts.entries) {
        native.lane_count_mask |= 1 << entry.key;
        native.lane_count[entry.key] = entry.value;
      }
      for (final channel in settings.sourceTracks) {
        native.source_track_mask |= 1 << channel;
      }
      return EngineResult.fromCode(_bindings.le_engine_set_mix(_engine, ptr));
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  EngineResult recordWithImage(RecordImage image, {int channel = 0}) {
    _checkAlive();
    if (!image.isValid) return EngineResult.invalid;
    final ptr = calloc<le_record_image>();
    final recipes = image.laneFx.isEmpty
        ? nullptr.cast<le_fx_recipe>()
        : calloc<le_fx_recipe>(LE_MAX_LANES);
    try {
      final native = ptr.ref
        ..revision = image.revision
        ..lane_fx = recipes;
      for (final entry in image.laneFx.entries) {
        if (!_writeFxRecipe(recipes[entry.key], entry.value)) {
          return EngineResult.invalid;
        }
        native.fx_lane_mask |= 1 << entry.key;
      }
      for (final entry in image.lanes.entries) {
        native.lane_mask |= 1 << entry.key;
        native.gain[entry.key] = entry.value.gain;
        native.pan[entry.key] = entry.value.pan;
      }
      return EngineResult.fromCode(
        _bindings.le_engine_record_with_image(_engine, channel, ptr),
      );
    } finally {
      calloc.free(ptr);
      if (recipes != nullptr) calloc.free(recipes);
    }
  }

  @override
  EngineResult record({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_record(_engine, channel),
    );
  }

  @override
  EngineResult stopTrack({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_stop_track(_engine, channel),
    );
  }

  @override
  EngineResult play({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_play(_engine, channel));
  }

  @override
  EngineResult clear({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_clear(_engine, channel));
  }

  @override
  EngineResult clearUndoable({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_clear_undoable(_engine, channel),
    );
  }

  @override
  bool clearRestorePending({int channel = 0}) {
    _checkAlive();
    return _bindings.le_engine_clear_restore_pending(_engine, channel) != 0;
  }

  @override
  EngineResult historyModeGate({required int channels, required bool redo}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_history_mode_gate(_engine, channels, redo ? 1 : 0),
    );
  }

  @override
  bool redoReclears({int channel = 0}) {
    _checkAlive();
    return _bindings.le_engine_redo_reclears(_engine, channel) != 0;
  }

  @override
  bool undoRestoresClear({int channel = 0}) {
    _checkAlive();
    return _bindings.le_engine_undo_restores_clear(_engine, channel) != 0;
  }

  @override
  EngineResult undo({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_undo(_engine, channel));
  }

  @override
  EngineResult redo({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_redo(_engine, channel));
  }

  @override
  EngineResult peel({int channel = 0}) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_peel(_engine, channel));
  }

  @override
  EngineResult setLaneCount({required int channel, required int count}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_count(_engine, channel, count),
    );
  }

  @override
  EngineResult setLaneVolume(double volume, {int channel = 0, int lane = 0}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_volume(_engine, channel, lane, volume),
    );
  }

  @override
  EngineResult setLaneMute({
    required bool muted,
    int channel = 0,
    int lane = 0,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_mute(_engine, channel, lane, muted ? 1 : 0),
    );
  }

  @override
  EngineResult setLanePan({
    required double pan,
    int channel = 0,
    int lane = 0,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_pan(_engine, channel, lane, pan),
    );
  }

  @override
  EngineResult setTrackSolo({required int channel, required bool solo}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_solo(_engine, channel, solo ? 1 : 0),
    );
  }

  // A direct store, not a ring command: works while stopped, like the enable
  // setters.
  @override
  EngineResult setInputTrim({required int input, required double gain}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_input_trim(_engine, input, gain),
    );
  }

  @override
  EngineResult setLaneInput({
    required int channel,
    required int lane,
    required int inputChannel,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_input(_engine, channel, lane, inputChannel),
    );
  }

  @override
  EngineResult setLaneOutput({
    required int channel,
    required int lane,
    required int mask,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_output(_engine, channel, lane, mask),
    );
  }

  @override
  EngineResult setRecordOffset(int frames) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_record_offset(_engine, frames),
    );
  }

  @override
  Float32List exportTrack(int channel) {
    _checkAlive();
    _bindings.le_engine_get_track(_engine, channel, _trackPtr);
    final frames = _trackPtr.ref.length_frames;
    // Per-track buffers are mono: one sample per frame.
    if (frames <= 0) return Float32List(0);
    final buf = calloc<Float>(frames);
    try {
      final n = _bindings.le_engine_export_track(_engine, channel, buf, frames);
      if (n <= 0) return Float32List(0);
      return Float32List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Float32List exportTrackLane(int channel, int lane) {
    _checkAlive();
    _bindings.le_engine_get_lane(_engine, channel, lane, _lanePtr);
    final frames = _lanePtr.ref.length_frames;
    // Per-lane buffers are mono: one sample per frame.
    if (frames <= 0) return Float32List(0);
    final buf = calloc<Float>(frames);
    try {
      final n = _bindings.le_engine_export_track_lane(
        _engine,
        channel,
        lane,
        buf,
        frames,
      );
      if (n <= 0) return Float32List(0);
      return Float32List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  @override
  EngineResult importTrack(int channel, Float32List pcm) =>
      importTrackLane(channel, 0, pcm);

  @override
  EngineResult importTrackLane(int channel, int lane, Float32List pcm) {
    _checkAlive();
    // Per-lane buffers are mono: one sample per frame.
    final frames = pcm.length;
    if (frames <= 0) return EngineResult.invalid;
    final buf = calloc<Float>(pcm.length);
    try {
      buf.asTypedList(pcm.length).setAll(0, pcm);
      return EngineResult.fromCode(
        _bindings.le_engine_import_track_lane(
          _engine,
          channel,
          lane,
          buf,
          frames,
        ),
      );
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Float32List exportLayer(int channel, int lane, int ordinal) {
    _checkAlive();
    // Every layer of a lane shares the loop length; get_lane reports it.
    _bindings.le_engine_get_lane(_engine, channel, lane, _lanePtr);
    final frames = _lanePtr.ref.length_frames;
    if (frames <= 0) return Float32List(0);
    final buf = calloc<Float>(frames);
    try {
      final n = _bindings.le_engine_export_layer(
        _engine,
        channel,
        lane,
        ordinal,
        buf,
        frames,
      );
      if (n <= 0) return Float32List(0);
      return Float32List.fromList(buf.asTypedList(n));
    } finally {
      calloc.free(buf);
    }
  }

  @override
  EngineResult importLayer(
    int channel,
    int lane,
    int ordinal,
    Float32List pcm,
  ) {
    _checkAlive();
    final frames = pcm.length;
    if (frames <= 0) return EngineResult.invalid;
    final buf = calloc<Float>(pcm.length);
    try {
      buf.asTypedList(pcm.length).setAll(0, pcm);
      return EngineResult.fromCode(
        _bindings.le_engine_import_layer(
          _engine,
          channel,
          lane,
          ordinal,
          buf,
          frames,
        ),
      );
    } finally {
      calloc.free(buf);
    }
  }

  @override
  TrackHistory exportHistory(int channel) {
    _checkAlive();
    final undoCount = calloc<Int32>();
    final empty = calloc<Int32>();
    try {
      // A zero-capacity call returns the entry count (or a negative error).
      final count = _bindings.le_engine_export_history(
        _engine,
        channel,
        empty,
        empty,
        0,
        undoCount,
      );
      if (count < 0) return TrackHistory.none;
      if (count == 0) return TrackHistory(const [], undoCount: undoCount.value);
      final kinds = calloc<Int32>(count);
      final skipped = calloc<Int32>(count);
      try {
        final n = _bindings.le_engine_export_history(
          _engine,
          channel,
          kinds,
          skipped,
          count,
          undoCount,
        );
        if (n != count) {
          throw StateError('history of track $channel changed while read');
        }
        return TrackHistory(
          [
            for (var i = 0; i < count; i++)
              HistoryEntry(HistoryKind.values[kinds[i]], skipped: skipped[i]),
          ],
          undoCount: undoCount.value,
        );
      } finally {
        calloc
          ..free(kinds)
          ..free(skipped);
      }
    } finally {
      calloc
        ..free(undoCount)
        ..free(empty);
    }
  }

  @override
  EngineResult finalizeHistory(int channel, TrackHistory history) {
    _checkAlive();
    final entries = history.entries;
    final count = entries.length;
    // One element at least: the allocator refuses a zero-byte request.
    final kinds = calloc<Int32>(count == 0 ? 1 : count);
    final skipped = calloc<Int32>(count == 0 ? 1 : count);
    try {
      for (var i = 0; i < count; i++) {
        kinds[i] = entries[i].kind.index;
        skipped[i] = entries[i].skipped;
      }
      return EngineResult.fromCode(
        _bindings.le_engine_finalize_history(
          _engine,
          channel,
          kinds,
          skipped,
          count,
          history.undoCount,
        ),
      );
    } finally {
      calloc
        ..free(kinds)
        ..free(skipped);
    }
  }

  @override
  EngineResult commitSession(int baseFrames, {required int loopBars}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_commit_session(_engine, baseFrames, loopBars),
    );
  }

  @override
  EngineResult setRecordTimingSettings({
    required RecordTiming defaultTiming,
    required GridDivision rememberedDivision,
    required Map<int, RecordTiming> trackOverrides,
    required int editMask,
  }) {
    _checkAlive();
    if (trackOverrides.keys.any((channel) => channel < 0 || channel >= 8)) {
      return EngineResult.invalid;
    }
    final ptr = calloc<le_record_timing_settings>();
    try {
      ptr.ref
        ..default_timing = defaultTiming.code
        ..remembered_division = rememberedDivision.code
        ..edit_mask = editMask;
      for (var channel = 0; channel < 8; channel++) {
        ptr.ref.track_timing[channel] = trackOverrides[channel]?.code ?? -1;
      }
      return EngineResult.fromCode(
        _bindings.le_engine_set_record_timing_settings(_engine, ptr),
      );
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  EngineResult cancelArm({required int channel}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_cancel_arm(_engine, channel),
    );
  }

  @override
  EngineResult stopRecordControl({required int channel}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_stop_record_control(_engine, channel),
    );
  }

  @override
  EngineResult cancelCountIn() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_cancel_count_in(_engine));
  }

  @override
  EngineResult finalizeTake({required int channel}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_finalize_take(_engine, channel),
    );
  }

  @override
  EngineResult setTrackMultiple({required int channel, required int multiple}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_multiple(_engine, channel, multiple),
    );
  }

  @override
  EngineResult setDefaultMultiple({required int multiple}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_default_multiple(_engine, multiple),
    );
  }

  @override
  EngineResult setRecDub({required bool enabled}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_rec_dub(_engine, enabled ? 1 : 0),
    );
  }

  @override
  EngineResult setMasterGain(double gain) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_master_gain(_engine, gain),
    );
  }

  @override
  EngineResult setLimiter({required bool enabled, double ceiling = 0.99}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_limiter(_engine, enabled ? 1 : 0, ceiling),
    );
  }

  @override
  EngineResult setOutputEnabled({required int output, required bool enabled}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_enabled(
        _engine,
        output,
        enabled ? 1 : 0,
      ),
    );
  }

  // ---- Output bus chains (slice 3b) ----

  @override
  OutputFxSnapshot outputFxSnapshot({required int bus}) {
    _checkAlive();
    final ptr = calloc<le_output_fx_snapshot>();
    try {
      final result = _bindings.le_engine_get_output_fx_snapshot(
        _engine,
        bus,
        ptr,
      );
      if (result != 0) throw StateError('Output chain unavailable: $result');
      final value = ptr.ref;
      return OutputFxSnapshot(
        chainEnabled: value.chain_enabled != 0,
        effects: [
          for (var i = 0; i < value.count; i++)
            OutputEffectSnapshot(
              type: value.type[i],
              enabled: value.enabled[i] != 0,
              params: [
                for (var p = 0; p < LE_FX_PARAMS; p++) value.params[i][p],
              ],
            ),
        ],
      );
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  EngineResult setOutputFx({
    required int bus,
    required int index,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_fx(_engine, bus, index, type.code),
    );
  }

  @override
  EngineResult setOutputFxCount({required int bus, required int count}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_fx_count(_engine, bus, count),
    );
  }

  @override
  EngineResult setOutputFxParam({
    required int bus,
    required int index,
    required int param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_fx_param(
        _engine,
        bus,
        index,
        param,
        value,
      ),
    );
  }

  @override
  EngineResult setOutputFxEnabled({
    required int bus,
    required int index,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_fx_enabled(
        _engine,
        bus,
        index,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setOutputFxChainEnabled({
    required int bus,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_fx_chain_enabled(
        _engine,
        bus,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setAllTracksFx({
    required int index,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_all_tracks_fx(_engine, index, type.code),
    );
  }

  @override
  EngineResult setAllTracksFxCount({required int count}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_all_tracks_fx_count(_engine, count),
    );
  }

  @override
  EngineResult setAllTracksFxParam({
    required int index,
    required int param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_all_tracks_fx_param(_engine, index, param, value),
    );
  }

  @override
  EngineResult setAllTracksFxEnabled({
    required int index,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_all_tracks_fx_enabled(
        _engine,
        index,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setAllTracksFxChainEnabled({required bool enabled}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_all_tracks_fx_chain_enabled(
        _engine,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setLaneFxChannels({
    required int channel,
    required int lane,
    required int index,
    required FxChannels channels,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx_channels(
        _engine,
        channel,
        lane,
        index,
        channels.input.index,
        channels.output.index,
        channels.placement,
        channels.level,
      ),
    );
  }

  @override
  EngineResult setMonitorInputFxChannels({
    required int input,
    required int index,
    required FxChannels channels,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx_channels(
        _engine,
        input,
        index,
        channels.input.index,
        channels.output.index,
        channels.placement,
        channels.level,
      ),
    );
  }

  @override
  EngineResult setTrackFxChannels({
    required int channel,
    required int index,
    required FxChannels channels,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx_channels(
        _engine,
        channel,
        index,
        channels.input.index,
        channels.output.index,
        channels.placement,
        channels.level,
      ),
    );
  }

  @override
  EngineResult setOutputFxChannels({
    required int bus,
    required int index,
    required FxChannels channels,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_fx_channels(
        _engine,
        bus,
        index,
        channels.input.index,
        channels.output.index,
        channels.placement,
        channels.level,
      ),
    );
  }

  @override
  EngineResult setAllTracksFxChannels({
    required int index,
    required FxChannels channels,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_all_tracks_fx_channels(
        _engine,
        index,
        channels.input.index,
        channels.output.index,
        channels.placement,
        channels.level,
      ),
    );
  }

  // ---- Output buses (slice 3b) ----

  @override
  EngineResult setOutputLevel({required int bus, required double level}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_level(_engine, bus, level),
    );
  }

  @override
  EngineResult setOutputMute({required int bus, required bool muted}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_mute(_engine, bus, muted ? 1 : 0),
    );
  }

  @override
  EngineResult setOutputMono({required int bus, required bool mono}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_mono(_engine, bus, mono ? 1 : 0),
    );
  }

  @override
  EngineResult setOutputBalance({required int bus, required double balance}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_output_balance(_engine, bus, balance),
    );
  }

  @override
  EngineResult cutSound() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_cut_sound(_engine));
  }

  @override
  EngineResult setOverdubFeedback(double feedback) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_overdub_feedback(_engine, feedback),
    );
  }

  @override
  EngineResult setTrackOverdubFeedback({
    required int channel,
    required double? feedback,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_overdub_feedback(
        _engine,
        channel,
        feedback ?? -1.0,
      ),
    );
  }

  // ---- tempo grid + click/count-in (TempoControl, A4a) ----

  @override
  EngineResult setTempo(double bpm) {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_set_tempo(_engine, bpm));
  }

  @override
  EngineResult restoreTempo({
    required double bpm,
    required TempoSource source,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_restore_tempo(_engine, bpm, source.index),
    );
  }

  @override
  EngineResult setTimeSignature(int num, int den) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_time_signature(_engine, num, den),
    );
  }

  @override
  EngineResult tapTempo() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_engine_tap_tempo(_engine));
  }

  @override
  EngineResult setSyncTempo({required bool on}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_sync_tempo(_engine, on ? 1 : 0),
    );
  }

  @override
  EngineResult setClickMode(ClickMode mode) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_click_mode(_engine, mode.code),
    );
  }

  @override
  EngineResult setClickOutput(int mask) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_click_output(_engine, mask),
    );
  }

  @override
  EngineResult setClickVolume(double volume) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_click_volume(_engine, volume),
    );
  }

  @override
  EngineResult setRecordStartSettings({
    required int countInBars,
    required bool soundStart,
    required RecordStartEditKind editKind,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_record_start(
        _engine,
        countInBars,
        soundStart ? 1 : 0,
        editKind.index,
      ),
    );
  }

  @override
  EngineResult setTrackLengthPreset({required int channel, required int bars}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_length_preset(_engine, channel, bars),
    );
  }

  @override
  EngineResult setTrackLengthPresets(List<int> bars) {
    _checkAlive();
    if (bars.isEmpty ||
        bars.length > LE_MAX_TRACKS ||
        bars.any((value) => value < 0 || value > LE_LENGTH_PRESET_MAX_BARS)) {
      return EngineResult.invalid;
    }
    final values = calloc<Int32>(bars.length);
    try {
      values.asTypedList(bars.length).setAll(0, bars);
      return EngineResult.fromCode(
        _bindings.le_engine_set_track_length_presets(
          _engine,
          values,
          bars.length,
        ),
      );
    } finally {
      calloc.free(values);
    }
  }

  // ---- looper mode (LooperModeControl, B2a) ----

  @override
  LooperModeGate looperModeGate(LooperMode mode) {
    _checkAlive();
    final code = _bindings.le_engine_looper_mode_gate(_engine, mode.code);
    // A stopped engine has nothing to refuse: the switch is remembered and
    // re-applied on start, like every other mode-adjacent setting.
    return code < 0 ? LooperModeGate.open : LooperModeGate.fromCode(code);
  }

  @override
  EngineResult setLooperMode(LooperMode mode) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_looper_mode(_engine, mode.code),
    );
  }

  @override
  EngineResult setLooperModeWithPresets(LooperMode mode, List<int> bars) {
    _checkAlive();
    if (bars.isEmpty ||
        bars.length > LE_MAX_TRACKS ||
        bars.any((value) => value < 0 || value > LE_LENGTH_PRESET_MAX_BARS)) {
      return EngineResult.invalid;
    }
    final values = calloc<Int32>(bars.length);
    try {
      values.asTypedList(bars.length).setAll(0, bars);
      return EngineResult.fromCode(
        _bindings.le_engine_set_looper_mode_with_presets(
          _engine,
          mode.code,
          values,
          bars.length,
        ),
      );
    } finally {
      calloc.free(values);
    }
  }

  @override
  EngineResult crownPrimary({required int channel}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_crown_primary(_engine, channel),
    );
  }

  @override
  EngineResult setOneShot({required int channel, required bool oneShot}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_one_shot(_engine, channel, oneShot ? 1 : 0),
    );
  }

  @override
  EngineResult setOneShotMask({required int channels, required bool oneShot}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_one_shot_mask(_engine, channels, oneShot ? 1 : 0),
    );
  }

  @override
  EngineResult setLaneFx({
    required int channel,
    required int lane,
    required int index,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx(_engine, channel, lane, index, type.code),
    );
  }

  @override
  EngineResult setLaneFxCount({
    required int channel,
    required int lane,
    required int count,
    int preCount = 0,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx_count(
        _engine,
        channel,
        lane,
        count,
        preCount,
      ),
    );
  }

  @override
  EngineResult setLaneFxParam({
    required int channel,
    required int lane,
    required int index,
    required int param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx_param(
        _engine,
        channel,
        lane,
        index,
        param,
        value,
      ),
    );
  }

  @override
  EngineResult setLaneFxEnabled({
    required int channel,
    required int lane,
    required int index,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx_enabled(
        _engine,
        channel,
        lane,
        index,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setLaneFxChainEnabled({
    required int channel,
    required int lane,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_lane_fx_chain_enabled(
        _engine,
        channel,
        lane,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  int laneFxFingerprint({required int channel, required int lane}) =>
      _bindings.le_engine_lane_fx_fingerprint(_engine, channel, lane);

  @override
  Map<(int, int), LaneCacheState> laneCacheStates() {
    _checkAlive();
    // One native call, one drain + scheduler tick for the whole sweep — never
    // le_engine_get_lane_cache in a loop, which drains per lane (#418).
    final filled = _bindings.le_engine_get_all_lane_caches(
      _engine,
      _cachesPtr,
      LE_MAX_TRACKS * LE_MAX_LANES,
    );
    // A rejected call (e.g. unconfigured engine) fills nothing; report
    // "nothing observed" rather than reading whatever the buffer holds.
    if (filled <= 0) return const {};
    final states = <(int, int), LaneCacheState>{};
    for (var i = 0; i < filled; i++) {
      states[(i ~/ LE_MAX_LANES, i % LE_MAX_LANES)] = LaneCacheState.fromNative(
        _cachesPtr[i].state,
      );
    }
    return states;
  }

  // ---- Track-stage (per-track stereo bus) chain (FX v3 part 1b) ----

  @override
  EngineResult setTrackFx({
    required int channel,
    required int index,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx(_engine, channel, index, type.code),
    );
  }

  @override
  EngineResult setTrackFxCount({
    required int channel,
    required int count,
    int preCount = 0,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx_count(
        _engine,
        channel,
        count,
        preCount,
      ),
    );
  }

  @override
  EngineResult setTrackFxParam({
    required int channel,
    required int index,
    required int param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx_param(
        _engine,
        channel,
        index,
        param,
        value,
      ),
    );
  }

  @override
  EngineResult setTrackFxEnabled({
    required int channel,
    required int index,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx_enabled(
        _engine,
        channel,
        index,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setTrackFxChainEnabled({
    required int channel,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_track_fx_chain_enabled(
        _engine,
        channel,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setTunerInput({required int input}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_tuner_input(_engine, input),
    );
  }

  @override
  EngineResult setMonitorInputEnabled({
    required int input,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input(
        _engine,
        input,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setMonitorInputOutput({required int input, required int mask}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_output(_engine, input, mask),
    );
  }

  @override
  EngineResult setMonitorInputVolume({
    required int input,
    required double volume,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_volume(_engine, input, volume),
    );
  }

  @override
  EngineResult setMonitorInputMute({required int input, required bool muted}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_mute(
        _engine,
        input,
        muted ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setMonitorInputPan({required int input, required double pan}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_pan(_engine, input, pan),
    );
  }

  @override
  EngineResult setInputConditioningEnabled({
    required int input,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_input_conditioning(
        _engine,
        input,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setInputConditioningParam({
    required int input,
    required InputConditioningParam param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_input_conditioning_param(
        _engine,
        input,
        param.code,
        value,
      ),
    );
  }

  @override
  EngineResult setMonitorInputFx({
    required int input,
    required int index,
    required TrackEffectType type,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx(
        _engine,
        input,
        index,
        type.code,
      ),
    );
  }

  @override
  EngineResult setMonitorInputFxCount({
    required int input,
    required int count,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx_count(_engine, input, count),
    );
  }

  @override
  EngineResult setMonitorInputFxParam({
    required int input,
    required int index,
    required int param,
    required double value,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx_param(
        _engine,
        input,
        index,
        param,
        value,
      ),
    );
  }

  @override
  EngineResult setMonitorInputFxEnabled({
    required int input,
    required int index,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx_enabled(
        _engine,
        input,
        index,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  EngineResult setMonitorInputFxChainEnabled({
    required int input,
    required bool enabled,
  }) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_engine_set_monitor_input_fx_chain_enabled(
        _engine,
        input,
        enabled ? 1 : 0,
      ),
    );
  }

  @override
  int monitorFxFingerprint({required int input}) =>
      _bindings.le_engine_monitor_fx_fingerprint(_engine, input);

  @override
  Float32List readVisual() {
    _checkAlive();
    final n = _bindings.le_engine_read_visual(_engine, _vizPtr, LE_VIZ_POINTS);
    if (n <= 0) return Float32List(0);
    return Float32List.fromList(_vizPtr.asTypedList(n));
  }

  @override
  Float32List readTrackVisual(int channel) {
    _checkAlive();
    final n = _bindings.le_engine_read_track_visual(
      _engine,
      channel,
      _vizPtr,
      LE_VIZ_POINTS,
    );
    if (n <= 0) return Float32List(0);
    return Float32List.fromList(_vizPtr.asTypedList(n));
  }

  @override
  EngineResult perfArm(String captureDir) {
    _checkAlive();
    final dirPtr = captureDir.toNativeUtf8();
    try {
      return EngineResult.fromCode(
        _bindings.le_perf_arm(_engine, dirPtr.cast()),
      );
    } finally {
      malloc.free(dirPtr);
    }
  }

  @override
  EngineResult setPerfFollowOutput({required bool follow}) {
    _checkAlive();
    return EngineResult.fromCode(
      _bindings.le_perf_set_follow_output(_engine, follow ? 1 : 0),
    );
  }

  @override
  EngineResult perfDisarm() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_perf_disarm(_engine));
  }

  /// No `_checkAlive()`, deliberately: this is the one call on this class that
  /// never touches the engine handle — it is a question about a directory — so
  /// it stays valid after [dispose].
  ///
  /// It is also SYNCHRONOUS, unlike the `df` subprocess it replaced. On a local
  /// volume `statvfs` is microseconds and this is strictly less blocking than
  /// the fork it replaced (which stalled this same isolate for 1.8-3.1 ms); on
  /// a network mount whose server has gone away it can block for that mount's
  /// timeout. The appliance's capture volume is local NVMe.
  @override
  int? volumeFreeBytes(String path) {
    if (path.isEmpty) return null;
    final pathPtr = path.toNativeUtf8();
    final outPtr = calloc<Uint64>();
    try {
      final code = _bindings.le_perf_volume_free_bytes(
        pathPtr.cast(),
        outPtr,
      );
      if (!EngineResult.fromCode(code).isOk) return null;
      return outPtr.value;
    } finally {
      calloc.free(outPtr);
      malloc.free(pathPtr);
    }
  }

  @override
  EngineResult renderBegin(String captureDir) {
    _checkAlive();
    final dirPtr = captureDir.toNativeUtf8();
    try {
      return EngineResult.fromCode(
        _bindings.le_perf_render_begin(_engine, dirPtr.cast()),
      );
    } finally {
      malloc.free(dirPtr);
    }
  }

  @override
  PerformanceRenderProgress renderPoll() {
    _checkAlive();
    final donePtr = calloc<Int32>();
    final progressPtr = calloc<Int32>();
    try {
      final result = _bindings.le_perf_render_poll(
        _engine,
        donePtr,
        progressPtr,
        nullptr,
      );
      return PerformanceRenderProgress(
        done: donePtr.value != 0,
        progressPercent: progressPtr.value,
        failed: !EngineResult.fromCode(result).isOk,
      );
    } finally {
      calloc
        ..free(donePtr)
        ..free(progressPtr);
    }
  }

  @override
  List<PerformanceRenderTrackStatus> renderTrackStatuses() {
    _checkAlive();
    final countPtr = calloc<Int32>();
    final channelPtr = calloc<Int32>();
    final succeededPtr = calloc<Int32>();
    try {
      _bindings.le_perf_render_poll(_engine, nullptr, nullptr, countPtr);
      final count = countPtr.value;
      if (count <= 0) return const [];
      final result = <PerformanceRenderTrackStatus>[];
      for (var i = 0; i < count; i++) {
        if (_bindings.le_perf_render_track_status(
              _engine,
              i,
              channelPtr,
              succeededPtr,
            ) !=
            0) {
          continue;
        }
        result.add(
          PerformanceRenderTrackStatus(
            channel: channelPtr.value,
            succeeded: succeededPtr.value != 0,
          ),
        );
      }
      return result;
    } finally {
      calloc
        ..free(countPtr)
        ..free(channelPtr)
        ..free(succeededPtr);
    }
  }

  @override
  EngineResult renderCancel() {
    _checkAlive();
    return EngineResult.fromCode(_bindings.le_perf_render_cancel(_engine));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.le_engine_destroy(_engine);
    calloc
      ..free(_telemetryPtr)
      ..free(_snapshotPtr)
      ..free(_trackPtr)
      ..free(_lanePtr)
      ..free(_cachesPtr)
      ..free(_vizPtr);
  }
}

/// A device-free [NativeAudioEngine] for deterministic tests.
///
/// [start] only CONFIGURES the native engine — no audio device is opened —
/// and [pump] drives the same block processor the real device callback runs
/// (`le_engine_process`), exactly like the native test suite pumps it. Every
/// other call (record/undo/effects/snapshot/…) is the production FFI path on
/// the same handle, so a test harness exercises the real engine end to end
/// with fully controlled time. Lives here (not a test helper file) because it
/// needs the engine handle/bindings the production class keeps private —
/// exported from the package barrel like the mock engine.
class PumpedNativeEngine extends NativeAudioEngine {
  /// Creates a [PumpedNativeEngine]; see [NativeAudioEngine.new] for
  /// [bindings]. The library lookup honours the `SEGNO_ENGINE_LIB`
  /// environment override, which is how test runs point at a freshly built
  /// engine library.
  PumpedNativeEngine({super.bindings});

  int _sampleRate = 48000;
  int _inputChannels = 1;
  int _outputChannels = 1;

  /// Configures the engine (tracks/buffers/sample rate) WITHOUT opening a
  /// device. The engine is then fully drivable via [pump].
  @override
  EngineResult start(EngineConfig config) {
    _checkAlive();
    _sampleRate =
        simulatedSampleRate ??
        (config.sampleRate > 0 ? config.sampleRate : 48000);
    _inputChannels = config.inputChannels > 0 ? config.inputChannels : 1;
    _outputChannels = config.outputChannels > 0 ? config.outputChannels : 1;
    return EngineResult.fromCode(
      _bindings.le_engine_configure(
        _engine,
        _sampleRate,
        _inputChannels,
        _outputChannels,
        config.maxLoopFrames,
      ),
    );
  }

  /// No device to stop; the configuration (and all content) stays live.
  @override
  EngineResult stop() => EngineResult.ok;

  bool _deviceLost = false;

  /// When set, what [enumerateDevices] reports instead of the host's devices:
  /// a device-free harness drives a pinned-device reconnect by unplugging and
  /// re-plugging this list.
  List<AudioDevice>? simulatedDevices;

  @override
  List<AudioDevice> enumerateDevices() {
    final simulated = simulatedDevices;
    if (simulated != null) {
      _checkAlive();
      return List.unmodifiable(simulated);
    }
    return super.enumerateDevices();
  }

  /// When set, the sample rate the simulated device negotiates on [start]
  /// and [reopen] regardless of the requested one — the way a real interface
  /// that switched its clock while unplugged comes back at another rate.
  int? simulatedSampleRate;

  /// Rehearses a device loss: the next [snapshot] reports the device absent
  /// (as the backend's device-lost notification would) until [reopen]
  /// succeeds. The engine itself keeps running the pump — there is no device
  /// to lose — so a caller's reconnect path (stop, then reopen) can be driven
  /// end to end without hardware.
  void simulateDeviceLoss() {
    _checkAlive();
    _deviceLost = true;
    _bindings.le_engine_mark_device_lost(_engine);
  }

  /// The device-free twin of [NativeAudioEngine.reopen]: the same retention
  /// decision, material settle and runtime reset through
  /// `le_engine_reopen_configured`, with [config]'s shape standing in for the
  /// negotiated device parameters. Clears a pending [simulateDeviceLoss].
  @override
  ReopenResult reopen(EngineConfig config) {
    _checkAlive();
    final sampleRate =
        simulatedSampleRate ??
        (config.sampleRate > 0 ? config.sampleRate : 48000);
    final inputs = config.inputChannels > 0 ? config.inputChannels : 1;
    final outputs = config.outputChannels > 0 ? config.outputChannels : 1;
    final outcomePtr = calloc<Int32>();
    final droppedPtr = calloc<Int32>();
    try {
      outcomePtr.value = 0;
      droppedPtr.value = 0;
      final result = EngineResult.fromCode(
        _bindings.le_engine_reopen_configured(
          _engine,
          sampleRate,
          inputs,
          outputs,
          config.maxLoopFrames,
          outcomePtr,
          droppedPtr,
        ),
      );
      if (result.isOk) {
        _sampleRate = sampleRate;
        _inputChannels = inputs;
        _outputChannels = outputs;
        _deviceLost = false;
      }
      return (
        result: result,
        outcome: ReopenOutcome.fromCode(outcomePtr.value),
        droppedTracks: droppedPtr.value,
      );
    } finally {
      calloc
        ..free(outcomePtr)
        ..free(droppedPtr);
    }
  }

  /// Processes [frames] frames of constant [input] through the engine's block
  /// processor — the audio callback, minus the device. `frames == 0` still
  /// drains the command/event rings and advances per-block maintenance (the
  /// native suites' `drain` idiom). Buffers are sized `frames * channels`
  /// because the native side treats input/output as interleaved across the
  /// engine's configured channel counts (set in [start]); `input` is
  /// broadcast as a constant across every input channel.
  void pump({int frames = 512, double input = 0}) {
    _checkAlive();
    if (frames < 0) return;
    final inPtr = calloc<Float>(frames == 0 ? 1 : frames * _inputChannels);
    final outPtr = calloc<Float>(frames == 0 ? 1 : frames * _outputChannels);
    try {
      for (var i = 0; i < frames * _inputChannels; i++) {
        inPtr[i] = input;
      }
      _bindings.le_engine_process(_engine, outPtr, inPtr, frames);
    } finally {
      calloc
        ..free(inPtr)
        ..free(outPtr);
    }
  }

  /// The pump reports a live, present "device": without this the repository's
  /// reconnect supervisor would read the never-started engine as a lost
  /// device and stop/start it mid-test, resetting every track. Only
  /// [simulateDeviceLoss] makes it read absent, until the next [reopen].
  @override
  EngineSnapshot snapshot() {
    final s = super.snapshot();
    return s.copyWith(
      isRunning: true,
      devicePresent: !_deviceLost,
      sampleRate: s.sampleRate > 0 ? s.sampleRate : _sampleRate,
    );
  }
}

/// A [PluginSlotHandle] wrapping the native `le_plugin_slot*`. The pointer is
/// owned by the engine (freed when the slot is cleared / the engine is
/// disposed); this is only a token, never freed here.
@immutable
class _NativePluginSlotHandle implements PluginSlotHandle {
  const _NativePluginSlotHandle(this.pointer);

  /// The opaque native slot pointer.
  final Pointer<le_plugin_slot> pointer;

  @override
  bool operator ==(Object other) =>
      other is _NativePluginSlotHandle && other.pointer == pointer;

  @override
  int get hashCode => pointer.hashCode;
}
