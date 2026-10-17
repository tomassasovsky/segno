#pragma once
// The ring XIAO's half of ring_update.h: receive an image over the ring UART,
// write it into the other half of the bootrom's A/B partition pair, and reboot
// into it on trial. See firmware/libraries/SegnoRing/src/ring_update.h.
//
// Safety comes from the order of writes and from the bootrom:
//   * BEGIN erases the target's first sector at once. The bootrom finds an
//     image through the block loop that starts in that sector, so an
//     abandoned or interrupted transfer never leaves a bootable image behind.
//   * The first 4 KB arrive into RAM and are written last, at COMMIT, only
//     after the SHA-256 of everything received matches BEGIN's.
//   * The image is sealed with a hash and the TBYB flag. The bootrom checks
//     the hash, tries the image once from a flash-update boot, and reverts to
//     the previous partition unless the image calls explicit_buy() within
//     16.7 s. We buy only on CONFIRM, which the Pi sends after hearing this
//     image through the console.

#include <hardware/flash.h>
#include <pico/bootrom.h>
#include <pico/sha256.h>
#include <string.h>
#include <SegnoRing.h>

// arduino-pico 6.0.0 does not put the SDK's boot/picobin.h and
// boot/picoboot_constants.h on the include path; these are their values.
#ifndef REBOOT2_FLAG_REBOOT_TYPE_FLASH_UPDATE
#define REBOOT2_FLAG_REBOOT_TYPE_FLASH_UPDATE 0x4u
#endif
#ifndef PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_BITS
#define PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_LSB 0u
#define PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_BITS 0x00001fffu
#define PICOBIN_PARTITION_LOCATION_LAST_SECTOR_LSB 13u
#define PICOBIN_PARTITION_LOCATION_LAST_SECTOR_BITS 0x03ffe000u
#endif

template <typename Port>
class RingUpdater {
 public:
  RingUpdater(Port &port, uint8_t fwMajor, uint8_t fwMinor)
      : port_(port), fwMajor_(fwMajor), fwMinor_(fwMinor) {
    ring_frame_parser_init(&parser_, frame_, sizeof(frame_));
  }

  // Reads what the bootrom says about this boot. Call once from setup().
  void begin() {
    boot_info_t info;
    partition_ = -1;
    trial_ = false;
    if (rom_get_boot_info(&info)) {
      partition_ = info.partition;
      trial_ = (info.tbyb_and_update_info & BOOT_TBYB_AND_UPDATE_FLAG_BUY_PENDING) != 0;
    }
    receiving_ = rebooting_ = false;
    sendHello();
  }

  // Every byte the ring UART receives, alongside the ring-link parser.
  void push(uint8_t byte, uint32_t now) {
    size_t length = 0;
    if (!ring_frame_parser_push(&parser_, byte, &length)) return;
    uint8_t type;
    const uint8_t *payload;
    size_t n;
    if (!ring_update_message(frame_, length, &type, &payload, &n)) return;
    lastMs_ = now;
    handle(type, payload, n);
  }

  // Abandons a transfer the Pi stopped feeding. The target's first sector is
  // already erased, so nothing half-written can boot.
  void poll(uint32_t now) {
    if (receiving_ && (uint32_t)(now - lastMs_) >= IDLE_MS) abandon();
  }

  bool trial() const { return trial_; }
  bool receiving() const { return receiving_; }

  static const uint32_t IDLE_MS = 5000;

 private:
  void handle(uint8_t type, const uint8_t *p, size_t n) {
    if (rebooting_) return;
    switch (type) {
      case RING_UPDATE_QUERY: sendHello(); break;
      case RING_UPDATE_BEGIN:
        if (n == RING_UPDATE_BEGIN_LEN) beginTransfer(ring_update_get32(p), p + 4);
        break;
      case RING_UPDATE_DATA:
        if (n > 4) data(ring_update_get32(p), p + 4, n - 4);
        break;
      case RING_UPDATE_COMMIT: commit(); break;
      case RING_UPDATE_CONFIRM: confirm(); break;
      default: break;  // BRIDGE_END is the console's; anything newer is not ours
    }
  }

  void beginTransfer(uint32_t size, const uint8_t *digest) {
    if (receiving_) abandon();
    if (trial_) return ack(RING_UPDATE_BEGIN, RING_UPDATE_BAD_STATE, 0);
    uint32_t first, sectors;
    if (!otherPartition(first, sectors)) return ack(RING_UPDATE_BEGIN, RING_UPDATE_NO_TABLE, 0);
    if (size == 0 || size > sectors * FLASH_SECTOR_SIZE)
      return ack(RING_UPDATE_BEGIN, RING_UPDATE_BAD_SIZE, 0);
    if (pico_sha256_try_start(&sha_, SHA256_BIG_ENDIAN, false) != PICO_OK)
      return ack(RING_UPDATE_BEGIN, RING_UPDATE_FLASH, 0);
    target_ = first * FLASH_SECTOR_SIZE;
    size_ = size;
    next_ = 0;
    previous_ = UINT32_MAX;
    memcpy(digest_, digest, RING_UPDATE_DIGEST_LEN);
    memset(sector0_, 0xff, sizeof(sector0_));
    erase(target_);
    receiving_ = true;
    ack(RING_UPDATE_BEGIN, RING_UPDATE_OK, 0);
  }

  void data(uint32_t offset, const uint8_t *bytes, size_t n) {
    if (!receiving_) return ack(RING_UPDATE_DATA, RING_UPDATE_BAD_STATE, 0);
    // The Pi resends a chunk whose ACK it lost; it is already written.
    if (offset == previous_ && offset + n == next_) return ack(RING_UPDATE_DATA, RING_UPDATE_OK, next_);
    // In order, whole chunks: every offset is then page- and sector-aligned.
    const bool last = offset + n == size_;
    if (offset != next_ || n > RING_UPDATE_CHUNK || offset + n > size_ || (n != RING_UPDATE_CHUNK && !last))
      return ack(RING_UPDATE_DATA, RING_UPDATE_BAD_OFFSET, next_);
    pico_sha256_update_blocking(&sha_, bytes, n);
    if (offset < FLASH_SECTOR_SIZE) {
      memcpy(sector0_ + offset, bytes, n);  // RING_UPDATE_CHUNK divides the sector
    } else {
      if (offset % FLASH_SECTOR_SIZE == 0) erase(target_ + offset);
      uint8_t page[RING_UPDATE_CHUNK];
      const size_t padded = (n + FLASH_PAGE_SIZE - 1) / FLASH_PAGE_SIZE * FLASH_PAGE_SIZE;
      memset(page, 0xff, padded);
      memcpy(page, bytes, n);
      program(target_ + offset, page, padded);
    }
    previous_ = offset;
    next_ = offset + n;
    ack(RING_UPDATE_DATA, RING_UPDATE_OK, next_);
  }

  void commit() {
    if (!receiving_ || next_ != size_) return ack(RING_UPDATE_COMMIT, RING_UPDATE_BAD_STATE, next_);
    sha256_result_t result;
    pico_sha256_finish(&sha_, &result);
    receiving_ = false;
    if (memcmp(result.bytes, digest_, RING_UPDATE_DIGEST_LEN) != 0)
      return ack(RING_UPDATE_COMMIT, RING_UPDATE_DIGEST, 0);
    const size_t head = size_ < FLASH_SECTOR_SIZE ? size_ : FLASH_SECTOR_SIZE;
    program(target_, sector0_, (head + FLASH_PAGE_SIZE - 1) / FLASH_PAGE_SIZE * FLASH_PAGE_SIZE);
    ack(RING_UPDATE_COMMIT, RING_UPDATE_OK, 0);
    port_.flush();
    // The bootrom tries the partition starting here once, on trial.
    rom_reboot(REBOOT2_FLAG_REBOOT_TYPE_FLASH_UPDATE, 100, XIP_BASE + target_, 0);
    rebooting_ = true;
  }

  void confirm() {
    if (trial_) {
      // explicit_buy rewrites the sector holding the TBYB flag: 4 KB of work area.
      if (rom_explicit_buy(sector0_, sizeof(sector0_)) != 0) return ack(RING_UPDATE_CONFIRM, RING_UPDATE_FLASH, 0);
      trial_ = false;
    }
    ack(RING_UPDATE_CONFIRM, RING_UPDATE_OK, 0);
  }

  void abandon() {
    pico_sha256_cleanup(&sha_);
    receiving_ = false;
  }

  // The partner of the partition we booted from, in a two-partition A/B table.
  bool otherPartition(uint32_t &first, uint32_t &sectors) {
    if (partition_ < 0) return false;
    // [flags; count, unpartitioned location, unpartitioned flags; per partition: location, flags]
    uint32_t words[1 + 3 + 2 * 2];
    const uint32_t want = PT_INFO_PT_INFO | PT_INFO_PARTITION_LOCATION_AND_FLAGS;
    int got = rom_get_partition_table_info(words, sizeof(words) / sizeof(words[0]), want);
    if (got == BOOTROM_ERROR_PRECONDITION_NOT_MET) {  // not loaded on this boot path
      rom_load_partition_table(sector0_, sizeof(sector0_), false);
      got = rom_get_partition_table_info(words, sizeof(words) / sizeof(words[0]), want);
    }
    if (got != (int)(sizeof(words) / sizeof(words[0])) || (words[0] & want) != want) return false;
    if ((words[1] & 0xff) != 2) return false;
    const uint32_t location = words[4 + 2 * (uint32_t)(partition_ ^ 1)];
    first = (location & PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_BITS) >> PICOBIN_PARTITION_LOCATION_FIRST_SECTOR_LSB;
    const uint32_t last =
        (location & PICOBIN_PARTITION_LOCATION_LAST_SECTOR_BITS) >> PICOBIN_PARTITION_LOCATION_LAST_SECTOR_LSB;
    if (last < first) return false;
    sectors = last - first + 1;
    return true;
  }

  // Flash runs from XIP: nothing that lives in flash may run while it is busy,
  // on either core. arduino-pico's own pattern (EEPROM, LittleFS); idling the
  // other core is a no-op while the sketch has no setup1()/loop1().
  void erase(uint32_t offset) {
    noInterrupts();
    rp2040.idleOtherCore();
    flash_range_erase(offset, FLASH_SECTOR_SIZE);
    rp2040.resumeOtherCore();
    interrupts();
  }
  void program(uint32_t offset, const uint8_t *bytes, size_t n) {
    noInterrupts();
    rp2040.idleOtherCore();
    flash_range_program(offset, bytes, n);
    rp2040.resumeOtherCore();
    interrupts();
  }

  void sendHello() {
    const uint8_t hello[RING_UPDATE_HELLO_LEN] = {
      fwMajor_, fwMinor_, RING_UPDATE_PROTOCOL,
      (uint8_t)((trial_ ? RING_UPDATE_FLAG_TRIAL : 0) | (partition_ < 0 ? RING_UPDATE_FLAG_NO_TABLE : 0)),
      (uint8_t)partition_,
    };
    send(RING_UPDATE_HELLO, hello, sizeof(hello));
  }
  void ack(uint8_t type, uint8_t status, uint32_t value) {
    uint8_t p[RING_UPDATE_ACK_LEN] = {type, status};
    ring_update_put32(p + 2, value);
    send(RING_UPDATE_ACK, p, sizeof(p));
  }
  void send(uint8_t type, const uint8_t *payload, size_t n) {
    uint8_t out[RING_FRAME_ENCODED_MAX(2 + RING_UPDATE_ACK_LEN)];  // the longer reply
    port_.write(out, ring_update_encode(type, payload, n, out));
  }

  Port &port_;
  const uint8_t fwMajor_, fwMinor_;
  uint8_t frame_[RING_UPDATE_PARSER_CAPACITY];
  ring_frame_parser parser_;
  int8_t partition_ = -1;
  bool trial_ = false, receiving_ = false, rebooting_ = false;
  uint32_t target_ = 0, size_ = 0, next_ = 0, previous_ = UINT32_MAX, lastMs_ = 0;
  uint8_t digest_[RING_UPDATE_DIGEST_LEN];
  pico_sha256_state_t sha_;
  // The image's first sector, held back until COMMIT; also explicit_buy's
  // work area, which needs 4 KB, word-aligned.
  alignas(4) uint8_t sector0_[FLASH_SECTOR_SIZE];
};
