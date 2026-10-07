/// Native low-latency duplex audio engine for Segno.
///
/// Exposes a typed Dart API (`AudioEngine`) over a hand-written miniaudio
/// looping core via FFI. The generated low-level bindings are intentionally not
/// exported — depend on `AudioEngine` and the value objects instead.
library;

export 'src/audio_device.dart' show AudioDevice;
export 'src/audio_engine.dart'
    show
        AudioEngine,
        EffectsControl,
        EngineAudition,
        EngineException,
        EngineLifecycle,
        EngineMetering,
        EnginePerformanceCapture,
        EnginePluginHosting,
        EngineResult,
        EngineRouting,
        InputConditioningControl,
        LooperModeControl,
        LooperTransport,
        MasterBusControl,
        MonitorControl,
        ReopenOutcome,
        ReopenResult,
        RequestAdmission,
        SessionIo,
        TempoControl;
export 'src/audition.dart'
    show AuditionStart, AuditionState, kAuditionMaxSeconds;
export 'src/engine_config.dart' show AudioBackend, EngineConfig;
export 'src/engine_snapshot.dart'
    show
        CallbackTelemetry,
        CallbackWindowStats,
        ClickMode,
        EngineSnapshot,
        FadeImage,
        GridDivision,
        LaneSnapshot,
        LatencyState,
        LooperMode,
        LooperModeGate,
        PendingLaunchAction,
        RecordStartEditKind,
        RecordTiming,
        TempoSource,
        TrackRestoreState,
        TrackSnapshot,
        TrackState,
        XrunKind,
        kMaxChannels,
        kMaxLanes,
        kMaxMonitoredInputs,
        kMaxOutputBuses,
        kMaxTracks;
export 'src/fx_fingerprint.dart' show FxFingerprint;
export 'src/fx_recipe.dart' show FxOwner, FxRecipe, FxRecipeSlot;
export 'src/history_entry.dart' show HistoryEntry, HistoryKind, TrackHistory;
export 'src/input_conditioning_param.dart' show InputConditioningParam;
export 'src/lane_cache.dart' show LaneCacheState;
export 'src/loopback_info.dart' show LoopbackInfo, LoopbackKind;
export 'src/mix_settings.dart'
    show
        EngineMixSettings,
        OutputMix,
        RecordImage,
        StereoMix,
        inputTrimGainOfDb,
        kInputTrimStepDb,
        kMaxInputTrimDb,
        kMinInputTrimDb;
export 'src/mock_audio_engine.dart' show MockAudioEngine, MockPluginSlotHandle;
export 'src/native_audio_engine.dart'
    show NativeAudioEngine, PumpedNativeEngine;
export 'src/output_fx_snapshot.dart';
export 'src/performance_render_progress.dart'
    show PerformanceRenderProgress, PerformanceRenderTrackStatus;
export 'src/plugin_descriptor.dart'
    show
        PluginDescriptor,
        PluginFormat,
        PluginParamInfo,
        PluginScanProgress,
        PluginSlotHandle;
export 'src/storage_io.dart'
    show
        FileDigest,
        FileDigested,
        FileMissing,
        FileTruncated,
        FileUnreadable,
        NativeStorageIo,
        StorageIo;
export 'src/track_effect.dart'
    show
        BuiltInEffect,
        FxChannelInput,
        FxChannelOutput,
        FxChannels,
        FxPlacement,
        FxRack,
        ParamReadout,
        PluginEffect,
        PluginRef,
        TrackEffect,
        TrackEffectParam,
        TrackEffectType,
        decodeTrackEffects,
        encodeTrackEffects,
        fxPreCount,
        kPluginFxCode,
        kTrackEffectMax,
        kTrackEffectParams;
export 'src/vendored_licenses.dart' show registerVendoredLicenses;
export 'src/volume_space.dart' show VolumeSpace;
