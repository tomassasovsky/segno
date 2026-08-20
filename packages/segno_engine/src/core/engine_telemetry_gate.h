/*
 * engine_telemetry_gate.h — the ONE definition of the audio-callback-telemetry
 * build gate (#722).
 *
 * Its own header, three lines long, because two translation-unit families need
 * the same answer and neither can include the other's headers: the engine
 * (engine_telemetry.h and everything that pulls it in) and the vendored
 * miniaudio implementation (miniaudio_impl.c, which guards the SEGNO PATCH
 * dropout-hook call sites with it). A duplicated `#ifndef` default in both
 * places would silently drift the day someone flips one of them.
 *
 * -DLE_CALLBACK_TELEMETRY=0 removes the instrument entirely: no clock reads, no
 * accumulators, and no hook call sites in the ALSA recovery branches, leaving
 * the audio path exactly as it was before #722. Default ON — the appliance
 * ships with it, which is the whole point.
 */
#ifndef SEGNO_ENGINE_TELEMETRY_GATE_H
#define SEGNO_ENGINE_TELEMETRY_GATE_H

#ifndef LE_CALLBACK_TELEMETRY
#define LE_CALLBACK_TELEMETRY 1
#endif

#endif /* SEGNO_ENGINE_TELEMETRY_GATE_H */
