/*
 * pd_trigger.h - the STUSB4500 USB-C PD sink on the SparkFun trigger board,
 * read and provisioned over J23 (I2C0, GP0 SDA / GP1 SCL) (#1352).
 *
 * The chip negotiates the 20 V supply on its own, from the profile in its NVM,
 * whenever it powers up. The console board makes sure that profile is the
 * console's (pd_trigger_provision) and reports what was negotiated
 * (pd_trigger_read_contract) to the app over the pedal link (PD_STATUS).
 *
 * The NVM sequences follow ST's STUSB4500 NVM flasher as SparkFun's
 * STUSB4500 Arduino library (MIT) implements them: password, controller
 * power-up, then read / erase / program opcodes, each polled until the NVM
 * controller clears its request bit.
 *
 * Plain C99 behind a bus interface, so the host tests run it against a
 * simulated chip (firmware/test/test_pd_trigger.cpp).
 */
#ifndef PD_TRIGGER_H
#define PD_TRIGGER_H

#include <stdint.h>

#include "pedal_link.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PD_TRIGGER_ADDRESS 0x28u
#define PD_TRIGGER_SECTORS 5u
#define PD_TRIGGER_SECTOR_LEN 8u

/* Register writes and reads at the chip's address. Each returns 0 on success
 * and nonzero when the chip did not answer. sleep_ms paces the NVM polls. */
typedef struct pd_trigger_bus {
  int (*write)(void *ctx, uint8_t reg, const uint8_t *data, uint8_t len);
  int (*read)(void *ctx, uint8_t reg, uint8_t *data, uint8_t len);
  void (*sleep_ms)(void *ctx, uint32_t ms);
  void *ctx;
} pd_trigger_bus;

typedef uint8_t pd_trigger_nvm[PD_TRIGGER_SECTORS][PD_TRIGGER_SECTOR_LEN];

/* What the source granted, from the chip's RDO (0x91..0x94) and its
 * negotiated-voltage register (0x21, 100 mV steps). All zero without an
 * explicit PD contract. max_milliamps is the source's offer for the matched
 * object; with REQ_SRC_CURRENT set, a fresh contract requests all of it. */
typedef struct pd_trigger_contract {
  uint16_t millivolts;
  uint16_t milliamps;
  uint16_t max_milliamps;
  uint8_t mismatch;
} pd_trigger_contract;

/* The console profile applied to an NVM image: three PDOs (5 V / 0.5 A,
 * 20 V / 3 A, 20 V / 5 A), REQ_SRC_CURRENT, power only above 5 V, no external
 * power, no USB comms. Every other field is copied from `in` unchanged. */
void pd_trigger_apply_profile(const pd_trigger_nvm in, pd_trigger_nvm out);

/* Reads the NVM into `out`. Returns 0, or nonzero when the chip did not
 * answer or the NVM controller never finished. */
int pd_trigger_read_nvm(const pd_trigger_bus *bus, pd_trigger_nvm out);

/* Makes the NVM hold the console profile: reads it, and if any profile field
 * differs erases all five sectors and programs them with the image read plus
 * the profile (the proven full-erase sequence), then reads the NVM back and
 * compares it whole. Returns a PEDAL_PD_PROFILE_* value. The new
 * profile only governs the next negotiation, at the chip's next power-up. */
uint8_t pd_trigger_provision(const pd_trigger_bus *bus);

/* Reads the live contract. Returns 0, or nonzero when the chip did not
 * answer (`out` is then zeroed). */
int pd_trigger_read_contract(const pd_trigger_bus *bus, pd_trigger_contract *out);

#ifdef __cplusplus
}
#endif

#endif
