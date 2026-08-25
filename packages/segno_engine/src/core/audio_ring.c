#include "audio_ring.h"

#include <stdlib.h>
#include <string.h>

#if defined(__linux__)
#include <sys/mman.h>
#endif

static int is_power_of_two(size_t n) { return n >= 2 && (n & (n - 1)) == 0; }

int le_audio_ring_alloc(le_audio_ring* ring, size_t capacity) {
  if (ring == NULL || !is_power_of_two(capacity)) return 0;
  const size_t bytes = capacity * sizeof(float);
  float* buffer = NULL;
#if defined(__linux__)
  /* Its own mapping rather than a malloc chunk, for one reason: MADV_DONTFORK
   * works on a vma, and a malloc'd ring lives inside [heap] alongside memory
   * the child legitimately inherits. Marking it VM_DONTCOPY makes fork() skip
   * the vma, so the parent's ptes are never write-protected and the audio
   * thread never takes a copy-on-write fault here — measured on the Pi 5 bench
   * as ~100 faults/s while armed against zero while idle, each one able to
   * block the SCHED_FIFO callback on mmap_lock for milliseconds (#804).
   *
   * A forked child cannot touch this mapping. Nothing does: every fork in the
   * host process execs immediately. */
  void* mapped = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mapped == MAP_FAILED) return 0;
  if (madvise(mapped, bytes, MADV_DONTFORK) != 0) {
    /* Without it the ring is back to being CoW'd on every fork, which is the
     * defect this function exists to remove — refuse rather than arm a capture
     * that will click. */
    munmap(mapped, bytes);
    return 0;
  }
  buffer = (float*)mapped;
#else
  buffer = (float*)malloc(bytes);
  if (buffer == NULL) return 0;
#endif
  /* Touch every page HERE, on the control thread. mmap and malloc both hand
   * back untouched pages, and the first lap of a fresh ring would otherwise be
   * faulted in by the audio callback one page at a time. */
  memset(buffer, 0, bytes);
  if (!le_audio_ring_init(ring, buffer, capacity)) {
#if defined(__linux__)
    munmap(buffer, bytes);
#else
    free(buffer);
#endif
    return 0;
  }
  return 1;
}

void le_audio_ring_release(le_audio_ring* ring) {
  if (ring == NULL || ring->buffer == NULL) return;
#if defined(__linux__)
  munmap(ring->buffer, ring->capacity * sizeof(float));
#else
  free(ring->buffer);
#endif
  *ring = (le_audio_ring){0};
}

int le_audio_ring_init(le_audio_ring* ring, float* buffer, size_t capacity) {
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
