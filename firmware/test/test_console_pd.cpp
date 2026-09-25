#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "../console_board/console_pd.h"

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, message); \
    std::exit(1); \
  } \
} while (0)

static void setRdo(uint16_t operating_ma, uint16_t maximum_ma, uint32_t flags = 0) {
  const uint32_t rdo = (5u << 28) | flags |
    ((uint32_t)(operating_ma / 10) << 10) | (maximum_ma / 10);
  for (unsigned i = 0; i < 4; ++i) fake_wire::registers[0x91 + i] = rdo >> (8 * i);
}

static void expectStatus(uint32_t now, uint8_t state, uint16_t current = 0, uint8_t flags = 0) {
  const auto status = console_pd_status(now);
  CHECK(status.state == state, "PD state must reflect only fresh successful observations");
  CHECK(status.current_ma == current, "unknown or lost contracts must clear current");
  CHECK(status.voltage_mv == 0, "unobservable voltage must never be inferred from a sink PDO");
  CHECK(status.flags == flags, "only a current contract can retain capability mismatch");
  CHECK(fake_wire::register_writes == 0, "monitor must never change a PD register/NVM");
}

static void boot(uint32_t now = 0) {
  fake_wire::reset();
  fake_arduino::now = now;
  console_pd_begin();
  CHECK(fake_wire::sda == 0 && fake_wire::scl == 1, "I2C must use the actual J23 pins");
  CHECK(fake_wire::timeout == 2 && fake_wire::clock == 100000, "I2C must have bounded transfers");
  fake_wire::registers[0x0e] = 1;
  fake_wire::registers[0x10] = 0x0a;
  fake_wire::registers[0x29] = 0x18;
  setRdo(5000, 5000);
  expectStatus(now, PEDAL_PD_UNKNOWN);
}

static void ready() {
  boot();
  console_pd_poll(499);
  CHECK(fake_wire::transfers == 0, "boot must leave time for autonomous negotiation");
  console_pd_poll(500);
  expectStatus(500, PEDAL_PD_NEGOTIATING);
  console_pd_poll(999);
  expectStatus(999, PEDAL_PD_NEGOTIATING);
  // The 999 ms poll starts a 250 ms cadence; the next due poll is 1249.
  console_pd_poll(1249);
  expectStatus(1249, PEDAL_PD_CONTRACT, 5000);
}

static void checkProtocol() {
  const pedal_pd_status s = {PEDAL_PD_CONTRACT, PEDAL_PD_CAPABILITY_MISMATCH, 0, 3000};
  const uint8_t expected[] = {0xa5, 0x05, 0x06, 0x03, 0x01, 0, 0, 0xb8, 0x0b, 0xb2};
  uint8_t frame[PEDAL_LINK_MAX_FRAME] = {};
  CHECK(pedal_link_encode_pd_status(&s, frame) == sizeof(expected), "PD frame must be ten bytes");
  CHECK(!std::memcmp(frame, expected, sizeof(expected)), "PD byte order/checksum must match golden bytes");
  pedal_pd_status decoded = {};
  CHECK(pedal_link_decode_pd_status(frame + 3, 6, &decoded), "golden PD payload must decode");
  CHECK(decoded.current_ma == 3000 && decoded.voltage_mv == 0 && decoded.flags == 1,
        "decoded contract must retain unknown voltage and mismatch");
  for (uint8_t state = 0; state < PEDAL_PD_COUNT; ++state) {
    if (state == PEDAL_PD_CONTRACT) continue;
    const pedal_pd_status non_contract = {state, 0, 0, 0};
    CHECK(pedal_link_encode_pd_status(&non_contract, frame) == 10, "empty states must encode");
  }
  const pedal_pd_status invalid[] = {
    {PEDAL_PD_COUNT, 0, 0, 0}, {PEDAL_PD_CONTRACT, 2, 0, 5000},
    {PEDAL_PD_CONTRACT, 0, 0, 0}, {PEDAL_PD_CONTRACT, 0, 0, 5010},
    {PEDAL_PD_CONTRACT, 0, 0, 3011}, {PEDAL_PD_CONTRACT, 0, 20001, 3000},
    {PEDAL_PD_CONTRACT, 0, 4950, 3000}, {PEDAL_PD_CONTRACT, 0, 20500, 3000},
    {PEDAL_PD_READ_ERROR, 0, 0, 3000}, {PEDAL_PD_STALE, 1, 0, 0},
    {PEDAL_PD_UNATTACHED, 0, 20000, 0},
  };
  for (const auto &bad : invalid) {
    CHECK(!pedal_link_encode_pd_status(&bad, frame), "encoder must reject incoherent PD claims");
    const uint8_t payload[] = {bad.state, bad.flags, (uint8_t)bad.voltage_mv,
      (uint8_t)(bad.voltage_mv >> 8), (uint8_t)bad.current_ma, (uint8_t)(bad.current_ma >> 8)};
    CHECK(!pedal_link_decode_pd_status(payload, 6, &decoded), "decoder must reject incoherent PD claims");
  }
  CHECK(!pedal_link_decode_pd_status(expected + 3, 5, &decoded), "short status must be rejected");
  const pedal_pd_status known = {PEDAL_PD_CONTRACT, 0, 20000, 5000};
  CHECK(pedal_link_encode_pd_status(&known, frame) == 10, "validated fixed voltage may be transmitted");
}

int main() {
  ready();
  const unsigned reads = fake_wire::requests;
  console_pd_poll(1300);
  CHECK(fake_wire::requests == reads, "polling should not monopolize the loop");
  expectStatus(2748, PEDAL_PD_CONTRACT, 5000);
  expectStatus(2749, PEDAL_PD_STALE);
  fake_wire::registers[0x0e] = 0;
  console_pd_poll(3000);
  expectStatus(3000, PEDAL_PD_UNATTACHED);
  fake_wire::registers[0x0e] = 1;
  console_pd_poll(3250);
  expectStatus(3250, PEDAL_PD_NEGOTIATING);
  setRdo(3000, 5000, 1u << 26);
  console_pd_poll(3750);
  expectStatus(3750, PEDAL_PD_CONTRACT, 3000, 1);
  fake_wire::registers[0x29] = 0x17;
  console_pd_poll(4000);
  expectStatus(4000, PEDAL_PD_NEGOTIATING);

  // Each register transaction can fail: never retain the prior 5 A claim.
  for (unsigned transaction = 1; transaction <= 8; ++transaction) {
    ready();
    fake_wire::fail_transfer = fake_wire::transfers + transaction;
    console_pd_poll(1500);
    expectStatus(1500, PEDAL_PD_READ_ERROR);
    fake_wire::fail_transfer = 0;
    console_pd_poll(1750);
    expectStatus(1750, PEDAL_PD_NEGOTIATING);
    console_pd_poll(2250);
    expectStatus(2250, PEDAL_PD_CONTRACT, 5000);
  }
  ready();
  fake_wire::short_request = fake_wire::requests + 4;
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_READ_ERROR);
  ready();
  fake_wire::negative_request = fake_wire::requests + 4;
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_READ_ERROR);

  ready();
  const unsigned detach_at = fake_wire::requests + 5;
  fake_wire::before_request = [detach_at](unsigned request) {
    if (request == detach_at) fake_wire::registers[0x0e] = 0;
  };
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_UNATTACHED);
  ready();
  const unsigned change_at = fake_wire::requests + 8;
  fake_wire::before_request = [change_at](unsigned request) {
    if (request == change_at) setRdo(3000, 3000);
  };
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_NEGOTIATING);

  ready();
  fake_wire::registers[0x10] = 0x04;
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_NEGOTIATING);
  ready();
  setRdo(0, 5000);
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_READ_ERROR);
  ready();
  setRdo(5000, 3000);
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_READ_ERROR);
  ready();
  setRdo(5000, 5000, 1u << 31);
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_READ_ERROR);
  ready();
  fake_wire::registers[0x94] = 0;
  console_pd_poll(1500);
  expectStatus(1500, PEDAL_PD_NEGOTIATING);

  boot(UINT32_MAX - 600);
  console_pd_poll(UINT32_MAX - 100);
  expectStatus(UINT32_MAX - 100, PEDAL_PD_NEGOTIATING);
  console_pd_poll(399);
  expectStatus(399, PEDAL_PD_CONTRACT, 5000);
  expectStatus(1899, PEDAL_PD_STALE);
  checkProtocol();
  std::puts("Console PD monitor and status codec: ALL PASSED");
}
