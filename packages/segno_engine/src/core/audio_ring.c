#include "audio_ring.h"

#include <stdint.h>

#include "rt_alloc.h" /* le_rt_alloc/le_rt_free: the fork-shielded RT allocator */

static int is_power_of_two(size_t n) { return n >= 2 && (n & (n - 1)) == 0; }

static int le_audio_ring_init(le_audio_ring* ring, float* buffer,
                              size_t capacity) {
  if (ring == NULL || buffer == NULL || !is_power_of_two(capacity)) {
    return 0;
  }
  ring->buffer = buffer;
  ring->capacity = capacity;
  ring->mask = capacity - 1;
  atomic_store_explicit(&ring->head, 0, memory_order_relaxed);
  atomic_store_explicit(&ring->tail, 0, memory_order_relaxed);
  return 1;
}

int le_audio_ring_alloc(le_audio_ring* ring, size_t capacity) {
  if (ring == NULL || !is_power_of_two(capacity)) return 0;
  /* is_power_of_two admits anything up to SIZE_MAX/2, so the byte count could
   * wrap and hand mmap a tiny mapping that le_audio_ring_init would then index
   * far past — from the audio thread. No caller can reach this today; the check
   * is one comparison against a wild write on the real-time path. */
  if (capacity > SIZE_MAX / sizeof(float)) return 0;
  /* le_rt_alloc is the whole story: fork-shielded, zeroed, and page-touched on
   * this (control) thread. rt_alloc.h carries the reasoning that used to live
   * here — it is the same reasoning for every buffer the callback writes, which
   * is why it is no longer the capture ring's private business (#804). */
  float* buffer = (float*)le_rt_alloc(capacity * sizeof(float));
  if (buffer == NULL) return 0;
  le_audio_ring_init(ring, buffer, capacity);
  return 1;
}

void le_audio_ring_release(le_audio_ring* ring) {
  if (ring == NULL || ring->buffer == NULL) return;
  le_rt_free(ring->buffer);
  *ring = (le_audio_ring){0};
}


int le_audio_ring_push_frame(le_audio_ring* ring, const float* samples,
                            size_t n) {
  /* Producer owns tail; it only needs an acquire view of head to test whether
   * `n` slots are free. */
  const size_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
  const size_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
  if (tail - head + n > ring->capacity - 1) {
    return 0; /* not enough room: drop the whole frame, write nothing */
  }
  for (size_t i = 0; i < n; ++i) {
    ring->buffer[(tail + i) & ring->mask] = samples[i];
  }
  /* Release so the consumer sees every sample write before the new tail. */
  atomic_store_explicit(&ring->tail, tail + n, memory_order_release);
  return 1;
}

size_t le_audio_ring_pop(le_audio_ring* ring, float* out, size_t max) {
  const size_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
  const size_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
  size_t avail = tail - head;
  if (avail > max) avail = max;
  for (size_t i = 0; i < avail; ++i) {
    out[i] = ring->buffer[(head + i) & ring->mask];
  }
  if (avail > 0) {
    atomic_store_explicit(&ring->head, head + avail, memory_order_release);
  }
  return avail;
}
