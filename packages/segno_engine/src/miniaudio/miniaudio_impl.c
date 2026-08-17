/*
 * miniaudio_impl.c — the single translation unit that compiles the miniaudio
 * implementation. Kept separate from engine.c so the (large) library body is
 * only compiled once and engine.c stays fast to rebuild.
 */
#define MINIAUDIO_IMPLEMENTATION

/* We only need PCM capture/playback; disable decoders/encoders/resources we do
 * not use to keep the binary small and the build fast. */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH

/* The audio-callback-telemetry gate (#722), BEFORE miniaudio.h: this is the
 * only TU that compiles miniaudio's implementation, so it is the only place the
 * SEGNO PATCH dropout-hook call sites in the ALSA recovery branches exist, and
 * LE_CALLBACK_TELEMETRY=0 has to reach them here to compile them out. Shared
 * with the engine through engine_telemetry_gate.h so the default lives in one
 * place. */
#include "engine_telemetry_gate.h"

#include "miniaudio.h"
