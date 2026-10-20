/* bench_alloc.cpp — a counting replacement of the global C++ allocator for
 * bench_pitch_time (#1179 Part 1). Linked into the bench only, never into the
 * engine.
 *
 * Every allocation the stretch shim and the vendored Signalsmith Stretch make
 * goes through operator new (std::vector, the stretcher itself), so live and
 * peak bytes counted here are exact for le_stretch_*, independent of the
 * platform's malloc statistics and of whatever else the process holds. The
 * library makes no over-aligned allocations (no alignas / align_val_t), so the
 * aligned forms keep their default implementations.
 *
 * Each block carries its size in a max_align_t-sized header so delete can
 * account it without relying on sized deallocation.
 */
#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <new>

namespace {

constexpr std::size_t kHeader = alignof(std::max_align_t);
std::atomic<long long> g_live{0};
std::atomic<long long> g_peak{0};

void* counted_alloc(std::size_t n) noexcept {
  void* p = std::malloc(n + kHeader);
  if (p == nullptr) return nullptr;
  *static_cast<std::size_t*>(p) = n;
  const long long live = g_live.fetch_add((long long)n) + (long long)n;
  long long peak = g_peak.load();
  while (live > peak && !g_peak.compare_exchange_weak(peak, live)) {
  }
  return static_cast<char*>(p) + kHeader;
}

void counted_free(void* q) noexcept {
  if (q == nullptr) return;
  void* p = static_cast<char*>(q) - kHeader;
  g_live.fetch_sub((long long)*static_cast<std::size_t*>(p));
  std::free(p);
}

void* counted_alloc_or_throw(std::size_t n) {
  void* p = counted_alloc(n);
  if (p == nullptr) throw std::bad_alloc();
  return p;
}

}  // namespace

void* operator new(std::size_t n) { return counted_alloc_or_throw(n); }
void* operator new[](std::size_t n) { return counted_alloc_or_throw(n); }
void* operator new(std::size_t n, const std::nothrow_t&) noexcept {
  return counted_alloc(n);
}
void* operator new[](std::size_t n, const std::nothrow_t&) noexcept {
  return counted_alloc(n);
}
void operator delete(void* p) noexcept { counted_free(p); }
void operator delete[](void* p) noexcept { counted_free(p); }
void operator delete(void* p, std::size_t) noexcept { counted_free(p); }
void operator delete[](void* p, std::size_t) noexcept { counted_free(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept {
  counted_free(p);
}
void operator delete[](void* p, const std::nothrow_t&) noexcept {
  counted_free(p);
}

extern "C" {

/* Bytes currently held through operator new. */
long long bench_cxx_heap_live(void) { return g_live.load(); }

/* Restarts the high-water mark at the current live figure. */
void bench_cxx_heap_reset_peak(void) { g_peak.store(g_live.load()); }

/* Highest live figure since the last reset. */
long long bench_cxx_heap_peak(void) { return g_peak.load(); }

}  // extern "C"
