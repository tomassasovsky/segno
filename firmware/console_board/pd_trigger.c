#include "pd_trigger.h"

#include <string.h>

/* Registers and NVM (FTP) controller bits, from ST's register map. */
#define REG_VBUS_SELECT 0x21u    /* negotiated voltage, 100 mV steps */
#define REG_RW_BUFFER 0x53u      /* one sector, in and out */
#define REG_RDO 0x91u            /* request data object of the contract, LE32 */
#define REG_FTP_PASSWORD 0x95u
#define FTP_PASSWORD 0x47u
#define REG_FTP_CTRL_0 0x96u
#define FTP_PWR 0x80u
#define FTP_RST_N 0x40u
#define FTP_REQ 0x10u
#define FTP_SECT 0x07u
#define REG_FTP_CTRL_1 0x97u
#define FTP_SER 0xF8u
#define FTP_OPCODE 0x07u
#define OP_READ 0x00u
#define OP_WRITE_PL 0x01u
#define OP_WRITE_SER 0x02u
#define OP_ERASE_SECTOR 0x05u
#define OP_PROG_SECTOR 0x06u
#define OP_SOFT_PROG_SECTOR 0x07u

/* Each NVM operation finishes in well under a second (an erase is the
 * slowest); a controller that never clears its request bit is abandoned. */
#define POLL_MS 10u
#define POLL_LIMIT 300u

static int put(const pd_trigger_bus *bus, uint8_t reg, uint8_t value) {
  return bus->write(bus->ctx, reg, &value, 1);
}

/* Starts the loaded opcode on `sector` and waits for the controller. */
static int run(const pd_trigger_bus *bus, uint8_t sector) {
  if (put(bus, REG_FTP_CTRL_0, (uint8_t)((sector & FTP_SECT) | FTP_PWR | FTP_RST_N | FTP_REQ)))
    return 1;
  for (uint32_t i = 0; i < POLL_LIMIT; ++i) {
    uint8_t ctrl;
    if (bus->read(bus->ctx, REG_FTP_CTRL_0, &ctrl, 1)) return 1;
    if (!(ctrl & FTP_REQ)) return 0;
    bus->sleep_ms(bus->ctx, POLL_MS);
  }
  return 1;
}

static int opcode(const pd_trigger_bus *bus, uint8_t op, uint8_t sector) {
  if (put(bus, REG_FTP_CTRL_1, (uint8_t)(op & FTP_OPCODE))) return 1;
  return run(bus, sector);
}

static int enter(const pd_trigger_bus *bus) {
  if (put(bus, REG_FTP_PASSWORD, FTP_PASSWORD)) return 1;
  if (put(bus, REG_FTP_CTRL_0, 0)) return 1; /* controller reset */
  return put(bus, REG_FTP_CTRL_0, FTP_PWR | FTP_RST_N);
}

/* Leaves the NVM powered down and locked, whatever happened before. */
static void leave(const pd_trigger_bus *bus) {
  (void)put(bus, REG_FTP_CTRL_0, FTP_RST_N);
  (void)put(bus, REG_FTP_PASSWORD, 0);
}

int pd_trigger_read_nvm(const pd_trigger_bus *bus, pd_trigger_nvm out) {
  int failed = enter(bus);
  for (uint8_t s = 0; !failed && s < PD_TRIGGER_SECTORS; ++s) {
    failed = opcode(bus, OP_READ, s) ||
             bus->read(bus->ctx, REG_RW_BUFFER, out[s], PD_TRIGGER_SECTOR_LEN);
  }
  leave(bus);
  return failed;
}

/* Erases all five sectors and programs them from `image`, in the order ST's
 * flasher and SparkFun's library run it: password, RW buffer cleared, NVM
 * controller reset and powered, then the erase opcodes (SER with every
 * sector, soft program, erase) and one write-and-program per sector. */
static int program(const pd_trigger_bus *bus, const pd_trigger_nvm image) {
  int failed = put(bus, REG_FTP_PASSWORD, FTP_PASSWORD) || put(bus, REG_RW_BUFFER, 0) ||
               put(bus, REG_FTP_CTRL_0, 0) || put(bus, REG_FTP_CTRL_0, FTP_PWR | FTP_RST_N) ||
               put(bus, REG_FTP_CTRL_1, (uint8_t)((0x1Fu << 3) | OP_WRITE_SER)) ||
               run(bus, 0) || opcode(bus, OP_SOFT_PROG_SECTOR, 0) ||
               opcode(bus, OP_ERASE_SECTOR, 0);
  for (uint8_t s = 0; !failed && s < PD_TRIGGER_SECTORS; ++s) {
    failed = bus->write(bus->ctx, REG_RW_BUFFER, image[s], PD_TRIGGER_SECTOR_LEN) ||
             put(bus, REG_FTP_CTRL_0, FTP_PWR | FTP_RST_N) ||
             opcode(bus, OP_WRITE_PL, 0) || opcode(bus, OP_PROG_SECTOR, s);
  }
  leave(bus);
  return failed;
}

/* NVM current codes: 0.25 A steps to 3 A, then 0.5 A steps (SparkFun's
 * mapping). Voltages are 50 mV steps. */
#define CODE_0A5 1u   /* 4 * 0.5 - 1 */
#define CODE_3A 11u   /* 4 * 3 - 1 */
#define CODE_5A 15u   /* 2 * 5 + 5 */
#define V_20 400u     /* 20 V / 50 mV */

void pd_trigger_apply_profile(const pd_trigger_nvm in, pd_trigger_nvm out) {
  memcpy(out, in, sizeof(pd_trigger_nvm));
  /* Sector 3, byte 2 is all profile: PDO1 current (7:4), external power (3)
   * off, PDO count (2:1), USB comms (0) off. */
  out[3][2] = (uint8_t)((CODE_0A5 << 4) | (3u << 1));
  out[3][4] = (uint8_t)((out[3][4] & 0xF0u) | CODE_3A);         /* PDO2 current */
  out[3][5] = (uint8_t)((out[3][5] & 0x0Fu) | (CODE_5A << 4));  /* PDO3 current */
  /* PDO2 voltage: bits 1:0 in sector 4 byte 0 (7:6), bits 9:2 in byte 1. */
  out[4][0] = (uint8_t)((out[4][0] & 0x3Fu) | ((V_20 & 0x03u) << 6));
  out[4][1] = (uint8_t)(V_20 >> 2);
  /* PDO3 voltage: bits 7:0 in sector 4 byte 2, bits 9:8 in byte 3 (1:0). */
  out[4][2] = (uint8_t)(V_20 & 0xFFu);
  out[4][3] = (uint8_t)((out[4][3] & 0xFCu) | (V_20 >> 8));
  /* Sector 4, byte 6: REQ_SRC_CURRENT (4) and POWER_ONLY_ABOVE_5V (3). */
  out[4][6] = (uint8_t)(out[4][6] | 0x18u);
}

uint8_t pd_trigger_provision(const pd_trigger_bus *bus) {
  pd_trigger_nvm found, want, back;
  if (pd_trigger_read_nvm(bus, found)) return PEDAL_PD_PROFILE_NOT_READ;
  pd_trigger_apply_profile(found, want);
  if (memcmp(found, want, sizeof(pd_trigger_nvm)) == 0) return PEDAL_PD_PROFILE_MATCHES;
  if (program(bus, want) || pd_trigger_read_nvm(bus, back) ||
      memcmp(back, want, sizeof(pd_trigger_nvm)) != 0)
    return PEDAL_PD_PROFILE_WRITE_FAILED;
  return PEDAL_PD_PROFILE_WRITTEN;
}

int pd_trigger_read_contract(const pd_trigger_bus *bus, pd_trigger_contract *out) {
  uint8_t rdo[4], volts;
  memset(out, 0, sizeof(*out));
  if (bus->read(bus->ctx, REG_RDO, rdo, 4) || bus->read(bus->ctx, REG_VBUS_SELECT, &volts, 1))
    return 1;
  const uint32_t value = (uint32_t)rdo[0] | (uint32_t)rdo[1] << 8 | (uint32_t)rdo[2] << 16 |
                         (uint32_t)rdo[3] << 24;
  if (!value) return 0; /* no explicit contract */
  /* Fixed-supply RDO: bits 9:0 max operating current, 19:10 operating
   * current (10 mA each), bit 26 capability mismatch. */
  out->max_milliamps = (uint16_t)((value & 0x3FFu) * 10u);
  out->milliamps = (uint16_t)(((value >> 10) & 0x3FFu) * 10u);
  out->mismatch = (uint8_t)((value >> 26) & 1u);
  out->millivolts = (uint16_t)(volts * 100u);
  return 0;
}
