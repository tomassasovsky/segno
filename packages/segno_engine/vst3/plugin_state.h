/*
 * plugin_state.h — the size of the state every Segno VST3 plugin saves.
 *
 * Processor::getState writes, and Processor::setState and
 * Controller::setComponentState read, exactly kSegnoPluginStateParams raw
 * floats: the 0..1 settings of the entry's first four parameters, 16 bytes.
 * A DAW project (an exported Ableton set, for one) stores those bytes, so the
 * count is fixed here instead of following LE_FX_PARAMS. Widening the
 * engine's per-entry parameter array must not change what a saved project
 * holds or what an older project restores from.
 *
 * The processors' in-memory arrays stay LE_FX_PARAMS wide, because
 * fx_apply_chain reads that width; only the saved prefix is fixed.
 *
 * Each plugin includes this as "../plugin_state.h" from its own directory,
 * so no build file needs another include path.
 */
#pragma once

#include <cstdint>

extern "C" {
#include "engine_fx.h"
}

/* The number of floats in a saved plugin state. */
constexpr int32_t kSegnoPluginStateParams = 4;

static_assert(LE_FX_PARAMS >= kSegnoPluginStateParams,
              "the saved state is a prefix of the engine's parameter array");
static_assert(kSegnoPluginStateParams * sizeof(float) == 16,
              "saved projects hold 16 bytes of plugin state");
