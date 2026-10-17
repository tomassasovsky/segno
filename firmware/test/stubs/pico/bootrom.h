#ifndef SEGNO_TEST_PICO_BOOTROM_H
#define SEGNO_TEST_PICO_BOOTROM_H

// The RP2350 bootrom calls the ring updater makes, simulated. The partition
// table is firmware/ring_board/partition_table.json's: A = sectors 2..129,
// B = 130..257. A reboot is recorded, not performed; the test boots the next
// image itself.
#include <cassert>
#include <cstdint>

#ifndef PICO_OK
#define PICO_OK 0
#endif
#define BOOTROM_ERROR_PRECONDITION_NOT_MET (-14)
#define PT_INFO_PT_INFO 0x0001u
#define PT_INFO_PARTITION_LOCATION_AND_FLAGS 0x0010u
#define BOOT_TBYB_AND_UPDATE_FLAG_BUY_PENDING 0x1u

typedef struct {
  int8_t diagnostic_partition_index;
  uint8_t boot_type;
  int8_t partition;
  uint8_t tbyb_and_update_info;
  uint32_t boot_diagnostic;
  uint32_t reboot_params[2];
} boot_info_t;

namespace fake_bootrom {
constexpr uint32_t A_FIRST = 2, A_LAST = 129, B_FIRST = 130, B_LAST = 257;
inline int8_t partition = 0;         // -1: no partition table in flash
inline bool trial = false;           // booted on trial, buy pending
inline bool tableLoaded = true;      // false: get_partition_table_info needs a load first
inline unsigned reboots = 0, buys = 0;
inline uint32_t rebootFlags = 0, rebootAddress = 0, rebootDelayMs = 0;
inline int buyResult = 0;
inline uint32_t location(uint32_t first, uint32_t last) { return first | last << 13; }
}  // namespace fake_bootrom

inline int rom_get_boot_info(boot_info_t *info) {
  *info = boot_info_t{};
  info->partition = fake_bootrom::partition;
  info->tbyb_and_update_info = fake_bootrom::trial ? BOOT_TBYB_AND_UPDATE_FLAG_BUY_PENDING : 0;
  return 1;
}

inline int rom_get_partition_table_info(uint32_t *out, uint32_t words, uint32_t flags) {
  if (!fake_bootrom::tableLoaded) return BOOTROM_ERROR_PRECONDITION_NOT_MET;
  assert(flags == (PT_INFO_PT_INFO | PT_INFO_PARTITION_LOCATION_AND_FLAGS) && words >= 8);
  out[0] = flags;
  out[1] = 2u | 0x100u;
  out[2] = out[3] = 0;
  out[4] = fake_bootrom::location(fake_bootrom::A_FIRST, fake_bootrom::A_LAST);
  out[5] = 0;
  out[6] = fake_bootrom::location(fake_bootrom::B_FIRST, fake_bootrom::B_LAST);
  out[7] = 0;
  return 8;
}

inline int rom_load_partition_table(uint8_t *, uint32_t, bool) {
  fake_bootrom::tableLoaded = true;
  return 0;
}

inline int rom_reboot(uint32_t flags, uint32_t delay_ms, uint32_t p0, uint32_t) {
  ++fake_bootrom::reboots;
  fake_bootrom::rebootDelayMs = delay_ms;
  fake_bootrom::rebootFlags = flags;
  fake_bootrom::rebootAddress = p0;
  return 0;
}

inline int rom_explicit_buy(uint8_t *buffer, uint32_t size) {
  assert(size >= 4096 && ((uintptr_t)buffer & 3) == 0);
  ++fake_bootrom::buys;
  if (fake_bootrom::buyResult == 0) fake_bootrom::trial = false;
  return fake_bootrom::buyResult;
}

#endif
