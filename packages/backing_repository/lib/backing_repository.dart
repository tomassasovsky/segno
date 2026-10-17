/// The backing player's repository (#1200): the managed `Backing tracks`
/// store and the player that drives the engine's backing voice.
library;

export 'package:segno_engine/segno_engine.dart'
    show AudioDecoder, BackingEnd, BackingEndEvent, BackingTransport;
export 'src/audio_decoders.dart'
    show createMockAudioDecoder, createNativeAudioDecoder;
export 'src/backing_asset_store.dart'
    show BackingAssetStore, BackingCopier, BackingDigester, BackingDirSync;
export 'src/backing_repository.dart' show BackingRepository;
export 'src/internal_copier.dart' show internalBackingCopier;
export 'src/models/backing_asset.dart' show BackingAsset;
export 'src/models/backing_failure.dart'
    show BackingFailure, BackingFailureReason;
export 'src/models/backing_player_state.dart'
    show BackingNotice, BackingPlayerState;
