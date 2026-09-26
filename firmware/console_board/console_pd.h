#ifndef SEGNO_CONSOLE_PD_H
#define SEGNO_CONSOLE_PD_H

#include <Wire.h>
#include <hardware/gpio.h>
#include <pedal_link.h>

// SparkFun DEV-15801, address jumpers in their shipped 0x28 position.
// Register definitions: ST UM2650, PORT_STATUS_1 (0x0e),
// TYPEC_MONITORING_STATUS_1 (0x10), PE_FSM (0x29), RDO (0x91..0x94).
// These reads do not clear alerts, alter PDOs, reset PD or touch NVM.
// The SparkFun library's begin()/read() does write volatile configuration;
// use the core's bounded Wire reads for this status-only monitor instead.
static const uint8_t CONSOLE_PD_ADDRESS = 0x28;
static const uint32_t CONSOLE_PD_POLL_MS = 250;
static const uint32_t CONSOLE_PD_SETTLE_MS = 500;
static const uint32_t CONSOLE_PD_STALE_MS = 1500;

static pedal_pd_status g_pd = {PEDAL_PD_UNKNOWN, 0, 0, 0};
static uint32_t g_pd_started_ms = 0;
static uint32_t g_pd_polled_ms = 0;
static uint32_t g_pd_attached_ms = 0;
static bool g_pd_polled = false;
static bool g_pd_attached = false;

static inline void console_pd_clear(uint8_t state) {
  g_pd = {state, 0, 0, 0};
}

static inline void console_pd_begin() {
  Wire.setSDA(0);
  Wire.setSCL(1);
  Wire.begin();
  Wire.setClock(100000);
  Wire.setTimeout(2, false);
  // The trigger has its own 2.2k pulls. Avoid supplying an absent/unpowered
  // trigger through the Pico's optional internal pull-ups.
  gpio_disable_pulls(0);
  gpio_disable_pulls(1);
  g_pd_started_ms = (uint32_t)millis();
  g_pd_polled_ms = g_pd_started_ms;
  g_pd_attached_ms = g_pd_started_ms;
  g_pd_polled = false;
  g_pd_attached = false;
  console_pd_clear(PEDAL_PD_UNKNOWN);
}

static inline bool console_pd_read(uint8_t reg, uint8_t *data, size_t count) {
  Wire.beginTransmission(CONSOLE_PD_ADDRESS);
  Wire.write(reg);  // register pointer only; no register data is written
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(CONSOLE_PD_ADDRESS, count, true) != count) return false;
  for (size_t i = 0; i < count; ++i) {
    const int value = Wire.read();
    if (value < 0) return false;
    data[i] = (uint8_t)value;
  }
  return true;
}

static inline void console_pd_read_error() {
  console_pd_clear(PEDAL_PD_READ_ERROR);
  g_pd_attached = false;
  // Reset this master's transaction state after an interrupted transfer.
  // There is no reset/renegotiation command sent to the PD controller.
  Wire.end();
  Wire.begin();
  gpio_disable_pulls(0);
  gpio_disable_pulls(1);
}

static inline uint32_t console_pd_le32(const uint8_t *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
         (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static inline bool console_pd_ready(uint8_t pe) {
  return pe == 0x18 || pe == 0x19;  // SNK_READY / SNK_READY_SENDING
}

static inline void console_pd_poll(uint32_t now) {
  if (!g_pd_polled && (uint32_t)(now - g_pd_started_ms) < CONSOLE_PD_SETTLE_MS) return;
  if (g_pd_polled && (uint32_t)(now - g_pd_polled_ms) < CONSOLE_PD_POLL_MS) return;
  g_pd_polled = true;
  g_pd_polled_ms = now;

  uint8_t port, monitor, pe, rdo_bytes[4];
  if (!console_pd_read(0x0e, &port, 1)) {
    console_pd_read_error();
    return;
  }
  if (!(port & 0x01)) {
    g_pd_attached = false;
    console_pd_clear(PEDAL_PD_UNATTACHED);
    return;
  }
  if (!g_pd_attached) {
    g_pd_attached = true;
    g_pd_attached_ms = now;
  }
  if ((uint32_t)(now - g_pd_attached_ms) < CONSOLE_PD_SETTLE_MS) {
    console_pd_clear(PEDAL_PD_NEGOTIATING);
    return;
  }
  if (!console_pd_read(0x10, &monitor, 1) || !console_pd_read(0x29, &pe, 1) ||
      !console_pd_read(0x91, rdo_bytes, sizeof(rdo_bytes))) {
    console_pd_read_error();
    return;
  }
  if ((monitor & 0x0e) != 0x0a || !console_pd_ready(pe)) {
    console_pd_clear(PEDAL_PD_NEGOTIATING);
    return;
  }

  // RDO is requested power, and can retain a prior value during a reset.
  // Recheck attachment, VBUS and policy state, and require an unchanged RDO
  // across the snapshot before publishing it as a current contract.
  uint8_t port_after, monitor_after, pe_after, rdo_after[4];
  if (!console_pd_read(0x0e, &port_after, 1) ||
      !console_pd_read(0x10, &monitor_after, 1) ||
      !console_pd_read(0x29, &pe_after, 1) ||
      !console_pd_read(0x91, rdo_after, sizeof(rdo_after))) {
    console_pd_read_error();
    return;
  }
  const uint32_t rdo = console_pd_le32(rdo_bytes);
  if (!(port_after & 0x01)) {
    g_pd_attached = false;
    console_pd_clear(PEDAL_PD_UNATTACHED);
    return;
  }
  if ((monitor_after & 0x0e) != 0x0a || !console_pd_ready(pe_after) ||
      rdo != console_pd_le32(rdo_after)) {
    console_pd_clear(PEDAL_PD_NEGOTIATING);
    return;
  }
  if (((rdo >> 28) & 0x07) == 0) {
    console_pd_clear(PEDAL_PD_NEGOTIATING);
    return;
  }
  const uint16_t operating_ma = (uint16_t)(((rdo >> 10) & 0x3ff) * 10);
  const uint16_t maximum_ma = (uint16_t)((rdo & 0x3ff) * 10);
  // STUSB4500 only negotiates fixed PDOs. Bit31 and22..20 are reserved;
  // GiveBack (bit27) is unsupported by this monitor. Reject bad/partial data.
  if ((rdo & 0x88700000u) || operating_ma == 0 || operating_ma > 5000 ||
      maximum_ma < operating_ma || maximum_ma > 5000) {
    console_pd_read_error();
    return;
  }
  g_pd.state = PEDAL_PD_CONTRACT;
  g_pd.flags = (rdo & (1u << 26)) ? PEDAL_PD_CAPABILITY_MISMATCH : 0;
  // UM2650 reserves 0x21. Configured sink PDO voltage is also not evidence
  // of the accepted source PDO: RDO indexes SOURCE PDOs, not the three sink
  // PDOs. With this read-only three-wire interface voltage is unobservable.
  g_pd.voltage_mv = 0;
  g_pd.current_ma = operating_ma;
}

static inline pedal_pd_status console_pd_status(uint32_t now) {
  if ((uint32_t)(now - g_pd_polled_ms) >= CONSOLE_PD_STALE_MS) {
    return {PEDAL_PD_STALE, 0, 0, 0};
  }
  return g_pd;
}

#endif
