#ifndef SEGNO_TEST_HARDWARE_SYNC_H
#define SEGNO_TEST_HARDWARE_SYNC_H

#include <stdint.h>
namespace fake_sync {
inline bool interrupts_enabled = true;
}
inline uint32_t save_and_disable_interrupts() {
  const bool was_enabled = fake_sync::interrupts_enabled;
  fake_sync::interrupts_enabled = false;
  return was_enabled ? 0 : 1;
}
inline void restore_interrupts(uint32_t saved) {
  fake_sync::interrupts_enabled = saved == 0;
}

#endif
