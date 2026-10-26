/// A lane's Loop-stage wet-cache state (FX v3 part 2's `le_cache_state`).
///
/// Pure telemetry: the cache is invisible in the signal contract — "when in
/// doubt, play live" — so nothing about how a lane sounds can be inferred
/// from this. It exists so a debug surface can show what the background
/// renderer is doing, which is otherwise entirely silent (R27).
enum LaneCacheState {
  /// No valid entry; the lane is being processed live.
  live,

  /// A render for the lane's current cache key is in flight.
  rendering,

  /// A published entry matches the current key — the audio thread can play it
  /// at zero FX CPU.
  cached,

  /// The last render failed (e.g. out of memory) and will be retried.
  failedRetrying,

  /// The lane is live until its chain or loop changes: its chain can never be
  /// rendered offline (it hosts a plugin slot), renders failed repeatedly, or
  /// it holds an octaver or a Whammy on a loop that is not a whole number of
  /// their hops (256 frames), so no single lap's render equals live, or it
  /// holds a free-running modulator (a chorus or a doubler), which sounds
  /// different each lap.
  gaveUp;

  /// Projects a native `le_cache_state` code, defaulting to [live] for a code
  /// this build doesn't know — an unrecognized state is not a reason to claim
  /// a lane is cached.
  static LaneCacheState fromNative(int code) => switch (code) {
    1 => LaneCacheState.rendering,
    2 => LaneCacheState.cached,
    3 => LaneCacheState.failedRetrying,
    4 => LaneCacheState.gaveUp,
    _ => LaneCacheState.live,
  };
}
