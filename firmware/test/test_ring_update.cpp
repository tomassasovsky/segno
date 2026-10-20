// Ring firmware updates end to end on the host (#1342): the Pi's update engine
// (segno-ring-flash's ring_flash.c) talks through a bridging console to the
// actual ring sketch, whose flash and bootrom are simulated. Covers a clean
// update and the next one into the other partition, a ring already current
// or on trial, a lost reply, a cut line followed by a clean retry, a wrong
// digest, the bootrom rejecting the image, and the refusals.
#include <cassert>
#include <csignal>
#include <cstdio>
#include <new>
#include <string>

#include "../ring_board/ring_board.ino"
#include "pedal_link.h"
#include "ring_flash.h"

namespace {

// ---- the simulated world -----------------------------------------------------
struct World {
  bool consoleBridges = true;    // false: console firmware without the bridge
  bool bridging = false;
  unsigned bridgeEnds = 0;
  std::vector<uint8_t> fromPi;   // what the console has seen from the Pi
  std::deque<uint8_t> toPi;
  long cutAfter = -1;            // stop carrying Pi bytes after this many
  long carried = 0;
  int dropBeginAcks = 0, dropDataAcks = 0;  // ring replies to lose on the way back
  bool bootromRejects = false;   // the next flash-update boot fails its hash check
  uint8_t nextMajor = 1, nextMinor = 0;  // what the image being sent reports
  unsigned handledReboots = 0;
  unsigned long rebootAt = 0;    // when the requested reboot actually happens
  unsigned attempts = 0;
  std::vector<std::string> log;
} world;

void bootRing(int8_t partition, bool trial, uint8_t major, uint8_t minor) {
  fake_bootrom::partition = partition;
  fake_bootrom::trial = trial;
  ringLink.received.clear();
  ringLink.sent.clear();
  // A different image is a different sketch build: here, a different version.
  g_updater.~RingUpdater();
  new (&g_updater) RingUpdater<SerialPIO>(ringLink, major, minor);
  setup();
}

// Bytes the ring wrote, as the Pi would receive them through the bridge,
// losing whole ACK frames when the test asks for it.
void collect() {
  for (const auto &chunk : ringLink.sent) {
    if (!world.bridging) continue;
    std::vector<uint8_t> bytes(chunk.begin(), chunk.end());
    const bool ack = bytes.size() > 4 && bytes[1] == RING_UPDATE_CHANNEL && bytes[2] == RING_UPDATE_ACK;
    int *drop = !ack ? nullptr : bytes[3] == RING_UPDATE_BEGIN ? &world.dropBeginAcks
                               : bytes[3] == RING_UPDATE_DATA ? &world.dropDataAcks : nullptr;
    if (drop && *drop > 0) {
      --*drop;
      continue;
    }
    for (const uint8_t b : bytes) world.toPi.push_back(b);
  }
  ringLink.sent.clear();
}

void tick() {
  // rom_reboot() resets the chip after its delay; the old image keeps running
  // (and must stay quiet) until then.
  if (fake_bootrom::reboots > world.handledReboots && !world.rebootAt)
    world.rebootAt = fake_arduino::now + fake_bootrom::rebootDelayMs;
  if (world.rebootAt && fake_arduino::now >= world.rebootAt) {
    world.rebootAt = 0;
    world.handledReboots = fake_bootrom::reboots;
    assert(fake_bootrom::rebootFlags == REBOOT2_FLAG_REBOOT_TYPE_FLASH_UPDATE);
    const uint32_t sector = (fake_bootrom::rebootAddress - XIP_BASE) / FLASH_SECTOR_SIZE;
    const int8_t target = sector == fake_bootrom::B_FIRST ? 1 : 0;
    assert(sector == (target ? fake_bootrom::B_FIRST : fake_bootrom::A_FIRST));
    fake_arduino::now += 200;  // reboot, bootrom scan
    if (world.bootromRejects) bootRing(fake_bootrom::partition, false, 1, 0);
    else bootRing(target, true, world.nextMajor, world.nextMinor);
  }
  loop();
  collect();
}

void piWrite(void *, const uint8_t *bytes, size_t n) {
  uint8_t bridge[PEDAL_LINK_MAX_FRAME];
  const size_t b = pedal_link_encode_ring_bridge(bridge);
  for (size_t i = 0; i < n; ++i) {
    world.fromPi.push_back(bytes[i]);
    if (!world.bridging) {
      // The console bridges from the byte after the frame that asks it to.
      const size_t at = world.fromPi.size();
      if (world.consoleBridges && at >= b && memcmp(&world.fromPi[at - b], bridge, b) == 0) world.bridging = true;
      continue;
    }
    if (world.cutAfter >= 0 && world.carried >= world.cutAfter) continue;
    ++world.carried;
    ringLink.received.push_back(bytes[i]);
  }
  // A BRIDGE_END frame ends the console's bridge (its own parser is tested in
  // test_console_bridge.cpp); count them here.
  uint8_t end[16];
  const size_t m = ring_update_encode(RING_UPDATE_BRIDGE_END, nullptr, 0, end);
  if (n == m && memcmp(bytes, end, m) == 0) {
    ++world.bridgeEnds;
    world.bridging = false;
  }
  tick();
}

int piRead(void *, unsigned timeout) {
  const unsigned long until = fake_arduino::now + timeout;
  while (world.toPi.empty()) {
    if (fake_arduino::now >= until) return -1;
    fake_arduino::now += 1;
    tick();
  }
  const uint8_t b = world.toPi.front();
  world.toPi.pop_front();
  return b;
}

unsigned piNow(void *) { return (unsigned)fake_arduino::now; }
void piLog(void *, const char *message) { world.log.emplace_back(message); }
void piAttempt(void *) { ++world.attempts; }

const ring_flash_io io = {nullptr, piWrite, piRead, piNow, piLog, piAttempt};

// ---- images --------------------------------------------------------------------
struct Image {
  std::vector<uint8_t> bytes;
  sha256_result_t digest;
};

Image image(size_t size, uint32_t seed) {
  Image i;
  i.bytes.resize(size);
  for (size_t k = 0; k < size; ++k) {
    seed = seed * 1664525u + 1013904223u;
    i.bytes[k] = (uint8_t)(seed >> 24);
  }
  pico_sha256_state_t s;
  assert(pico_sha256_try_start(&s, SHA256_BIG_ENDIAN, false) == PICO_OK);
  pico_sha256_update(&s, i.bytes.data(), size);
  pico_sha256_finish(&s, &i.digest);
  return i;
}

ring_flash_outcome run(const Image &img, uint8_t major, uint8_t minor, bool mayUpdate = true) {
  world.nextMajor = major;
  world.nextMinor = minor;
  world.toPi.clear();
  world.bridging = false;
  world.carried = 0;
  const ring_flash_job job = {img.bytes.data(), img.bytes.size(), img.digest.bytes, major, minor, mayUpdate};
  const ring_flash_outcome outcome = ring_flash_run(&io, &job);
  for (int k = 0; k < 50; ++k) tick();  // let the ring settle
  return outcome;
}

bool partitionHolds(int8_t partition, const Image &img) {
  const uint32_t first = partition ? fake_bootrom::B_FIRST : fake_bootrom::A_FIRST;
  return memcmp(fake_flash::mem + first * FLASH_SECTOR_SIZE, img.bytes.data(), img.bytes.size()) == 0;
}

bool firstSectorErased(int8_t partition) {
  const uint32_t first = partition ? fake_bootrom::B_FIRST : fake_bootrom::A_FIRST;
  for (uint32_t k = 0; k < FLASH_SECTOR_SIZE; ++k)
    if (fake_flash::mem[first * FLASH_SECTOR_SIZE + k] != 0xff) return false;
  return true;
}

void reset(int8_t partition = 0, bool trial = false, uint8_t major = 1, uint8_t minor = 0) {
  World fresh;
  world = fresh;
  fake_flash::reset();
  // Both partitions hold an older image, so every write must erase first and
  // a "cleared" first sector is the updater's doing.
  memset(fake_flash::mem + fake_bootrom::A_FIRST * FLASH_SECTOR_SIZE, 0x5a,
         (fake_bootrom::B_LAST + 1 - fake_bootrom::A_FIRST) * FLASH_SECTOR_SIZE);
  fake_bootrom::reboots = fake_bootrom::buys = 0;
  fake_bootrom::buyResult = 0;
  fake_bootrom::tableLoaded = true;
  fake_arduino::now = 1000;
  bootRing(partition, trial, major, minor);
}

// ---- scenarios -----------------------------------------------------------------
void sha256KnownAnswer() {
  pico_sha256_state_t s;
  sha256_result_t r;
  assert(pico_sha256_try_start(&s, SHA256_BIG_ENDIAN, false) == PICO_OK);
  pico_sha256_update(&s, (const uint8_t *)"abc", 3);
  pico_sha256_finish(&s, &r);
  static const uint8_t want[32] = {0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40,
                                   0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17,
                                   0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad};
  assert(memcmp(r.bytes, want, 32) == 0);
}

void currentRingCostsOneQuery() {
  reset();
  const Image img = image(70001, 1);
  const unsigned long start = fake_arduino::now;
  assert(run(img, 1, 0) == RING_FLASH_CURRENT);
  assert(world.attempts == 0 && fake_flash::erases == 0 && fake_bootrom::reboots == 0);
  assert(world.bridgeEnds == 1);
  assert(fake_arduino::now - start < 400);
  assert(g_parser.dropped == 0);  // update frames are not ring-link noise
}

void updatesAndThenUpdatesTheOtherPartition() {
  reset();
  const Image first = image(70001, 2);  // not a whole number of chunks
  assert(run(first, 1, 1) == RING_FLASH_UPDATED);
  assert(world.attempts == 1 && fake_bootrom::buys == 1);
  assert(fake_bootrom::partition == 1 && !fake_bootrom::trial && !g_updater.trial());
  assert(partitionHolds(1, first));
  assert(world.bridgeEnds == 1);

  const Image second = image(5000, 3);  // smaller than the first sector plus one chunk
  assert(run(second, 1, 2) == RING_FLASH_UPDATED);
  assert(fake_bootrom::partition == 0 && partitionHolds(0, second) && partitionHolds(1, first));
  assert(fake_bootrom::buys == 2);
}

void confirmsAWantedImageFoundOnTrial() {
  reset(1, true, 1, 3);
  const Image img = image(9000, 4);
  assert(run(img, 1, 3) == RING_FLASH_CONFIRMED);
  assert(fake_bootrom::buys == 1 && !fake_bootrom::trial && world.attempts == 0);
}

void leavesAnUnwantedTrialToRevert() {
  reset(1, true, 1, 4);
  const Image img = image(9000, 5);
  assert(run(img, 1, 5) == RING_FLASH_FAILED);
  assert(fake_bootrom::buys == 0 && fake_flash::erases == 0);
}

void resendsAChunkWhoseAckWasLost() {
  reset();
  const Image img = image(20000, 6);
  world.dropBeginAcks = 1;  // BEGIN is sent again and restarts
  world.dropDataAcks = 1;   // the first chunk is sent again, and not written twice
  assert(run(img, 1, 6) == RING_FLASH_UPDATED);
  assert(partitionHolds(1, img));
  assert(world.dropBeginAcks == 0 && world.dropDataAcks == 0);
}

void aCutLineLeavesTheOldImageAndTheNextBootUpdates() {
  reset();
  const Image img = image(40000, 7);
  world.cutAfter = 15000;  // mid-transfer: the line goes dead
  const unsigned long start = fake_arduino::now;
  assert(run(img, 1, 7) == RING_FLASH_FAILED);
  assert(world.attempts == 1 && fake_bootrom::reboots == 0 && fake_bootrom::partition == 0);
  assert(firstSectorErased(1));  // nothing half-written can boot
  // The ring abandons the transfer on its own, releasing the hash engine.
  fake_arduino::now = start + 30000;
  for (int k = 0; k < 10; ++k) tick();
  assert(!g_updater.receiving());
  world.cutAfter = -1;
  assert(run(img, 1, 7) == RING_FLASH_UPDATED);
  assert(partitionHolds(1, img));
}

void aWrongDigestIsRefusedBeforeTheFirstSector() {
  reset();
  Image img = image(30000, 8);
  img.digest.bytes[0] ^= 1;
  assert(run(img, 1, 8) == RING_FLASH_FAILED);
  assert(fake_bootrom::reboots == 0 && firstSectorErased(1) && fake_bootrom::partition == 0);
}

void theBootromRejectingTheImageKeepsTheOldOne() {
  reset();
  const Image img = image(30000, 9);
  world.bootromRejects = true;
  assert(run(img, 1, 9) == RING_FLASH_FAILED);
  assert(fake_bootrom::reboots == 1 && fake_bootrom::buys == 0 && fake_bootrom::partition == 0);
}

void refusalsAndSilence() {
  reset(-1);  // installed without the partition table
  const Image img = image(9000, 10);
  assert(run(img, 1, 10) == RING_FLASH_NO_TABLE && world.attempts == 0);
  assert(world.log.back().find("over USB") != std::string::npos);

  reset();
  assert(run(img, 1, 10, false) == RING_FLASH_HELD && world.attempts == 0 && fake_flash::erases == 0);
  assert(world.log.back().find("not retrying") != std::string::npos);

  reset();
  world.consoleBridges = false;  // a console that predates the bridge
  const unsigned long start = fake_arduino::now;
  assert(run(img, 1, 10) == RING_FLASH_SILENT);
  assert(fake_arduino::now - start <= RING_FLASH_QUERY_MS + 300);

  reset();
  fake_bootrom::tableLoaded = false;  // a boot path that left the table unloaded
  assert(run(img, 1, 10) == RING_FLASH_UPDATED);
}

// Requests sent straight to the ring, bypassing the engine's own checks.
std::vector<uint8_t> ask(uint8_t type, const std::vector<uint8_t> &payload) {
  uint8_t out[RING_UPDATE_MAX_FRAME];
  const size_t n = ring_update_encode(type, payload.data(), payload.size(), out);
  for (size_t i = 0; i < n; ++i) ringLink.received.push_back(out[i]);
  ringLink.sent.clear();
  loop();
  ring_frame_parser p;
  uint8_t body[RING_UPDATE_PARSER_CAPACITY];
  ring_frame_parser_init(&p, body, sizeof(body));
  for (const auto &chunk : ringLink.sent)
    for (const uint8_t b : chunk) {
      size_t length = 0;
      uint8_t t;
      const uint8_t *pl;
      size_t m;
      if (ring_frame_parser_push(&p, b, &length) && ring_update_message(body, length, &t, &pl, &m) &&
          t == RING_UPDATE_ACK)
        return std::vector<uint8_t>(pl, pl + m);
    }
  return {};
}

std::vector<uint8_t> beginPayload(uint32_t size) {
  std::vector<uint8_t> p(RING_UPDATE_BEGIN_LEN, 0);
  ring_update_put32(p.data(), size);
  return p;
}

void theRingRefusesWhatItCannotDoSafely() {
  reset(0, true, 1, 0);  // on trial: the other partition may be the running image
  auto a = ask(RING_UPDATE_BEGIN, beginPayload(1000));
  assert(a.size() == RING_UPDATE_ACK_LEN && a[0] == RING_UPDATE_BEGIN && a[1] == RING_UPDATE_BAD_STATE);
  assert(fake_flash::erases == 0);

  reset();
  a = ask(RING_UPDATE_BEGIN, beginPayload(128 * FLASH_SECTOR_SIZE + 1));
  assert(a[1] == RING_UPDATE_BAD_SIZE && fake_flash::erases == 0);
  a = ask(RING_UPDATE_DATA, std::vector<uint8_t>(4 + 16, 0));
  assert(a[1] == RING_UPDATE_BAD_STATE);
  a = ask(RING_UPDATE_BEGIN, beginPayload(3000));
  assert(a[1] == RING_UPDATE_OK);
  std::vector<uint8_t> chunk(4 + 1000, 0);
  ring_update_put32(chunk.data(), 1024);  // skips the first chunk
  a = ask(RING_UPDATE_DATA, chunk);
  assert(a[1] == RING_UPDATE_BAD_OFFSET && ring_update_get32(&a[2]) == 0);
  ring_update_put32(chunk.data(), 0);  // a short chunk that is not the last
  a = ask(RING_UPDATE_DATA, chunk);
  assert(a[1] == RING_UPDATE_BAD_OFFSET);
  a = ask(RING_UPDATE_COMMIT, {});
  assert(a[1] == RING_UPDATE_BAD_STATE && fake_bootrom::reboots == 0);
  reset(1, true, 1, 0);
  fake_bootrom::buyResult = -4;
  a = ask(RING_UPDATE_CONFIRM, {});
  assert(a[1] == RING_UPDATE_FLASH && fake_bootrom::trial);
}

}  // namespace

// A failed assertion shows what the engine said on the way.
void dumpLog(int) {
  for (const auto &line : world.log) std::fprintf(stderr, "  engine: %s\n", line.c_str());
}

int main() {
  std::signal(SIGABRT, dumpLog);
  sha256KnownAnswer();
  currentRingCostsOneQuery();
  updatesAndThenUpdatesTheOtherPartition();
  confirmsAWantedImageFoundOnTrial();
  leavesAnUnwantedTrialToRevert();
  resendsAChunkWhoseAckWasLost();
  aCutLineLeavesTheOldImageAndTheNextBootUpdates();
  aWrongDigestIsRefusedBeforeTheFirstSector();
  theBootromRejectingTheImageKeepsTheOldOne();
  refusalsAndSilence();
  theRingRefusesWhatItCannotDoSafely();
  std::puts("Ring firmware update over the console link: ALL PASSED");
}
