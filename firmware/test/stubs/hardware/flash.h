#ifndef SEGNO_TEST_HARDWARE_FLASH_H
#define SEGNO_TEST_HARDWARE_FLASH_H

// The XIAO's 2 MB QSPI flash, simulated: erase sets a sector to 0xff, program
// can only clear bits, and both enforce the alignment the real ROM routines
// need. Interrupts must be off and the other core idle around either, as on
// the device.
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <Adafruit_NeoPixel.h>

#define FLASH_SECTOR_SIZE 4096u
#define FLASH_PAGE_SIZE 256u
#define XIP_BASE 0x10000000u

namespace fake_flash {
constexpr size_t SIZE = 2u * 1024u * 1024u;
inline uint8_t mem[SIZE];
inline unsigned erases = 0, programs = 0;
inline void reset() {
  memset(mem, 0xff, SIZE);
  erases = programs = 0;
}
}  // namespace fake_flash

inline void flash_range_erase(uint32_t offset, size_t count) {
  assert(fake_arduino::interruptsOff && rp2040.otherCoreIdle);
  assert(offset % FLASH_SECTOR_SIZE == 0 && count % FLASH_SECTOR_SIZE == 0);
  assert(offset + count <= fake_flash::SIZE);
  memset(fake_flash::mem + offset, 0xff, count);
  ++fake_flash::erases;
}

inline void flash_range_program(uint32_t offset, const uint8_t *data, size_t count) {
  assert(fake_arduino::interruptsOff && rp2040.otherCoreIdle);
  assert(offset % FLASH_PAGE_SIZE == 0 && count % FLASH_PAGE_SIZE == 0);
  assert(offset + count <= fake_flash::SIZE);
  for (size_t i = 0; i < count; ++i) fake_flash::mem[offset + i] &= data[i];
  ++fake_flash::programs;
}

#endif
