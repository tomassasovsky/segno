// Header forwarder for the SPM (macOS) build: SPM adds include/ to the header
// search path but cannot point outside the package, so a cross-folder engine
// header a forwarded source includes by name is surfaced here.
//
// miniaudio_impl.c (forwarded from ../src/miniaudio/) includes
// "engine_telemetry_gate.h" to pick up LE_CALLBACK_TELEMETRY before miniaudio.h,
// which gates the SEGNO PATCH dropout-hook call sites (#722). The real header
// lives in ../src/core/, so the relative-to-source lookup from src/miniaudio/
// misses it and SPM falls through to here.
#include "../../../../../src/core/engine_telemetry_gate.h"
