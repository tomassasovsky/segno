// The PD trigger driver against a simulated STUSB4500: provisioning a board
// on the shipped NVM, leaving a provisioned one alone, failures, and decoding
// the live contract the bench unit reported (#1352).
#include <cassert>
#include <cstdio>
#include <cstring>

#include "pd_trigger.h"

namespace {

// Registers, five NVM sectors and the NVM controller. An erase leaves 0xFF; a
// program needs an erased sector, as flash does.
struct Chip {
  uint8_t regs[256] = {};
  pd_trigger_nvm nvm = {};
  uint8_t pl[8] = {};
  uint8_t eraseMask = 0, erased = 0, programmed = 0;
  bool present = true, partialEraseOk = true, stuck = false, corruptProgram = false;
  int writes = 0;

  void execute() {
    if (regs[0x95] != 0x47) return;  // locked
    const uint8_t sector = regs[0x96] & 7, op = regs[0x97] & 7;
    switch (op) {
      case 0: memcpy(&regs[0x53], nvm[sector], 8); break;  // READ
      case 1: memcpy(pl, &regs[0x53], 8); break;           // WRITE_PL
      case 2:                                              // WRITE_SER
        eraseMask = regs[0x97] >> 3;
        if (eraseMask != 0x1F && regs[0x53] != 0) partialEraseOk = false;
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

Chip chip;

int busWrite(void *, uint8_t reg, const uint8_t *data, uint8_t len) {
  if (!chip.present) return 2;
  ++chip.writes;
  for (uint8_t i = 0; i < len; ++i) chip.regs[(uint8_t)(reg + i)] = data[i];
  if (reg == 0x96 && (data[0] & 0x10)) {
    chip.execute();
    if (!chip.stuck) chip.regs[0x96] &= (uint8_t)~0x10u;
  }
  return 0;
}

int busRead(void *, uint8_t reg, uint8_t *data, uint8_t len) {
  if (!chip.present) return 2;
  for (uint8_t i = 0; i < len; ++i) data[i] = chip.regs[(uint8_t)(reg + i)];
  return 0;
}

uint32_t slept = 0;
void busSleep(void *, uint32_t ms) { slept += ms; }

const pd_trigger_bus bus = {busWrite, busRead, busSleep, nullptr};

// The SparkFun board's shipped NVM: three PDOs, 20 V at 1 A on PDO3.
const pd_trigger_nvm shipped = {
    {0x00, 0x00, 0xB0, 0xAA, 0x00, 0x45, 0x00, 0x00},
    {0x10, 0x40, 0x9C, 0x1C, 0xFF, 0x01, 0x3C, 0xDF},
    {0x02, 0x40, 0x0F, 0x00, 0x32, 0x00, 0xFC, 0xF1},
    {0x00, 0x19, 0x56, 0xAF, 0xF5, 0x35, 0x5F, 0x00},
    {0x00, 0x4B, 0x90, 0x21, 0x43, 0x00, 0x40, 0xFB},
};

void reset(const pd_trigger_nvm nvm) {
  chip = Chip();
  memcpy(chip.nvm, nvm, sizeof(pd_trigger_nvm));
}

// SparkFun's decoding of the profile fields.
double amps(uint8_t code) { return code == 0 ? 0 : code < 11 ? code * 0.25 + 0.25 : code * 0.5 - 2.5; }

void provisionsTheShippedBoard() {
  reset(shipped);
  assert(pd_trigger_provision(&bus) == PEDAL_PD_PROFILE_WRITTEN);
  const auto &n = chip.nvm;
  assert(((n[3][2] >> 1) & 3) == 3);                          // three PDOs
  assert(amps(n[3][2] >> 4) == 0.5);                          // PDO1
  assert(amps(n[3][4] & 0x0F) == 3.0);                        // PDO2
  assert(amps(n[3][5] >> 4) == 5.0);                          // PDO3
  assert(((n[4][1] << 2) | (n[4][0] >> 6)) == 400);           // PDO2 20 V
  assert((((n[4][3] & 3) << 8) | n[4][2]) == 400);            // PDO3 20 V
  assert((n[3][2] & 0x09) == 0);                              // no ext power, no USB comms
  assert(n[4][6] & 0x10 && n[4][6] & 0x08);                   // REQ_SRC_CURRENT, above 5 V only
  // Everything else is the board's own: UVLO/OVLO, flex current, GPIO.
  assert(memcmp(n[0], shipped[0], 8) == 0 && memcmp(n[1], shipped[1], 8) == 0 &&
         memcmp(n[2], shipped[2], 8) == 0);
  assert((n[3][4] & 0xF0) == (shipped[3][4] & 0xF0) && (n[3][5] & 0x0F) == (shipped[3][5] & 0x0F));
  assert(n[3][3] == shipped[3][3] && n[3][6] == shipped[3][6] && n[4][4] == shipped[4][4]);
  assert((n[4][3] & 0xFC) == (shipped[4][3] & 0xFC) && (n[4][6] & 0xE7) == (shipped[4][6] & 0xE7));
  // Only the two sectors that changed were erased and programmed, and the
  // NVM was left locked.
  assert(chip.erased == 0x18 && chip.programmed == 0x18 && chip.partialEraseOk);
  assert(chip.regs[0x95] == 0);
}

void leavesAProvisionedBoardAlone() {
  pd_trigger_nvm provisioned;
  pd_trigger_apply_profile(shipped, provisioned);
  reset(provisioned);
  assert(pd_trigger_provision(&bus) == PEDAL_PD_PROFILE_MATCHES);
  assert(chip.erased == 0 && chip.programmed == 0 && chip.regs[0x95] == 0);
  // A board missing only REQ_SRC_CURRENT (the bench unit before #1351) gets
  // just that byte's sector.
  provisioned[4][6] &= (uint8_t)~0x10u;
  reset(provisioned);
  assert(pd_trigger_provision(&bus) == PEDAL_PD_PROFILE_WRITTEN);
  assert(chip.erased == 0x10 && chip.programmed == 0x10 && (chip.nvm[4][6] & 0x10));
}

void failures() {
  reset(shipped);
  chip.present = false;
  assert(pd_trigger_provision(&bus) == PEDAL_PD_PROFILE_NOT_READ);

  reset(shipped);
  chip.corruptProgram = true;
  assert(pd_trigger_provision(&bus) == PEDAL_PD_PROFILE_WRITE_FAILED);

  // A controller that never finishes is abandoned in bounded time.
  reset(shipped);
  chip.stuck = true;
  slept = 0;
  assert(pd_trigger_provision(&bus) == PEDAL_PD_PROFILE_NOT_READ);
  assert(slept > 0 && slept <= 5000 && chip.regs[0x95] == 0);
}

void setRdo(uint32_t rdo, uint8_t volts) {
  for (uint8_t i = 0; i < 4; ++i) chip.regs[0x91 + i] = (uint8_t)(rdo >> (8 * i));
  chip.regs[0x21] = volts;
}

void decodesTheContract() {
  reset(shipped);
  pd_trigger_contract c;
  // The bench unit before its power cycle: PDO2 matched, 3 A of 4.7 A.
  setRdo(0x4004B1D6u, 200);
  assert(pd_trigger_read_contract(&bus, &c) == 0);
  assert(c.millivolts == 20000 && c.milliamps == 3000 && c.max_milliamps == 4700 && !c.mismatch);
  // After it: all 4.7 A.
  setRdo(0x400759D6u, 200);
  assert(pd_trigger_read_contract(&bus, &c) == 0);
  assert(c.milliamps == 4700 && c.max_milliamps == 4700);
  setRdo(0x4004B1D6u | (1u << 26), 200);
  assert(pd_trigger_read_contract(&bus, &c) == 0 && c.mismatch);
  setRdo(0, 50);  // no explicit contract
  assert(pd_trigger_read_contract(&bus, &c) == 0 && c.millivolts == 0 && c.milliamps == 0);
  chip.present = false;
  c.milliamps = 1;
  assert(pd_trigger_read_contract(&bus, &c) != 0 && c.milliamps == 0);
}

}  // namespace

int main() {
  provisionsTheShippedBoard();
  leavesAProvisionedBoardAlone();
  failures();
  decodesTheContract();
  std::puts("PD trigger: provisioning, failures and contract decoding: ALL PASSED");
}
