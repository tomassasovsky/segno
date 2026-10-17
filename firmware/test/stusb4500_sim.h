// A simulated STUSB4500 for the host tests: registers, five NVM sectors and
// the NVM controller's opcodes (#1352).
#pragma once
#include <cassert>
#include <cstdint>
#include <cstring>

#include "pd_trigger.h"

namespace stusb_sim {

// Registers, five NVM sectors and the NVM controller. An erase leaves 0xFF; a
// program needs an erased sector, as flash does.
struct Chip {
  uint8_t regs[256] = {};
  pd_trigger_nvm nvm = {};
  uint8_t pl[8] = {};
  uint8_t eraseMask = 0, erased = 0, programmed = 0;
  bool present = true, bufferCleared = true, stuck = false, corruptProgram = false;
  int writes = 0;

  void execute() {
    if (regs[0x95] != 0x47) return;  // locked
    const uint8_t sector = regs[0x96] & 7, op = regs[0x97] & 7;
    switch (op) {
      case 0: memcpy(&regs[0x53], nvm[sector], 8); break;  // READ
      case 1: memcpy(pl, &regs[0x53], 8); break;           // WRITE_PL
      case 2:  // WRITE_SER: ST's sequence clears the RW buffer first
        eraseMask = regs[0x97] >> 3;
        if (regs[0x53] != 0) bufferCleared = false;
        break;
      case 5:  // ERASE_SECTOR
        for (uint8_t s = 0; s < 5; ++s) {
          if (!(eraseMask & (1u << s))) continue;
          memset(nvm[s], 0xFF, 8);
          erased |= (uint8_t)(1u << s);
        }
        break;
      case 6:  // PROG_SECTOR
        for (uint8_t i = 0; i < 8; ++i) assert(nvm[sector][i] == 0xFF);
        memcpy(nvm[sector], pl, 8);
        if (corruptProgram) nvm[sector][0] ^= 1;
        programmed |= (uint8_t)(1u << sector);
        break;
      default: break;  // SOFT_PROG_SECTOR: nothing to model
    }
  }
};

inline Chip chip;

inline int busWrite(void *, uint8_t reg, const uint8_t *data, uint8_t len) {
  if (!chip.present) return 2;
  ++chip.writes;
  for (uint8_t i = 0; i < len; ++i) chip.regs[(uint8_t)(reg + i)] = data[i];
  if (reg == 0x96 && (data[0] & 0x10)) {
    chip.execute();
    if (!chip.stuck) chip.regs[0x96] &= (uint8_t)~0x10u;
  }
  return 0;
}

inline int busRead(void *, uint8_t reg, uint8_t *data, uint8_t len) {
  if (!chip.present) return 2;
  for (uint8_t i = 0; i < len; ++i) data[i] = chip.regs[(uint8_t)(reg + i)];
  return 0;
}

// A provisioned trigger holding a contract.
inline void attachContract(const pd_trigger_nvm nvm, uint32_t rdo, uint8_t volts) {
  chip = Chip();
  memcpy(chip.nvm, nvm, sizeof(pd_trigger_nvm));
  for (uint8_t i = 0; i < 4; ++i) chip.regs[0x91 + i] = (uint8_t)(rdo >> (8 * i));
  chip.regs[0x21] = volts;
}

}  // namespace stusb_sim
