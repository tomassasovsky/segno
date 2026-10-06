/*
 * le_midi_port.h - the shared native MIDI input sink (#1228 Part 1).
 *
 * The one path by which MIDI reaches the audio thread without Dart: a capture's
 * OS MIDI thread pushes each message, with a monotonic timestamp, into a
 * per-port SPSC ring owned by the engine; the audio thread drains the rings at
 * block start. MIDI clock (#1228) and instrument notes (#1197) both consume it.
 *
 * Header-only on purpose: the capture (midi.c) and the engine include it, and
 * neither links the other. The engine sees a capture only as the le_midi_sink
 * at its start (midi.c pins `struct le_midi` to begin with one), so the engine
 * test and race binaries can drive a sink without the OS MIDI backends.
 *
 * Threads and ownership:
 *   - producer: the attached capture's OS MIDI thread (le_midi_sink_push and
 *     le_midi_sink_mark_lost). Wait-free, no allocation, no lock, no syscall.
 *   - consumer: the audio thread (le_midi_port_pop and the flag reads).
 *   - control: bind/unbind, which the engine's attach/detach/destroy and the
 *     capture's close call. These run on one control thread and are never
 *     concurrent with each other (the FFI handle rule every handle follows).
 *
 * Quiescence (instruments plan review H2 and delta D5): every producer write
 * into engine-owned memory happens between le_midi_sink_enter and
 * le_midi_sink_leave. Enter increments the sink's in-flight counter and THEN
 * loads the bound port, both seq_cst; unbind stores NULL to the port pointer
 * and THEN loads the counter until it reads zero, both seq_cst. That is a
 * Dekker handshake: the two store-then-load pairs cannot both miss each other,
 * on arm64 as on x86, so when unbind returns no producer is inside the bracket
 * and none can enter it with the old port. The slot may then be rebound,
 * reused or freed. Leave is a release decrement, so everything written inside
 * the bracket happens-before unbind's return. The ring push and the lost mark
 * below are the bracketed writes today; the MIDI clock relay and DIN Thru
 * rings (#1228 Parts 6 and 7) are written inside the same bracket, never
 * outside it.
 *
 * Generations: every bind and unbind bumps the port's generation, and each
 * event carries the generation it was pushed under. The consumer drops events
 * whose generation is not current, so nothing from an old binding replays
 * after a reattach (instruments review H2).
 *
 * Gaps (instruments review H3 and delta D2): a push that finds the ring full
 * records where the stream broke instead of dropping silently: `a_gap` holds
 * the ring tail at the loss plus one, i.e. the index the lost message would
 * have taken. A later loss before the consumer has dealt with it moves the
 * mark forward. Every queued event below the mark precedes a loss, so
 * instruments release a port's voices only after playing those (no note-on
 * queued before a lost note-off is left held), and the clock follower counts
 * pulses across the loss by timestamp (#1228 plan M2).
 *
 * One consumer: le_midi_ports_drain on the audio thread is the only reader
 * that clears `a_gap` and observes `a_lost` edges; every consumer of the
 * events (instruments, the clock follower) is dispatched from that loop.
 */
#ifndef SEGNO_ENGINE_MIDI_PORT_H
#define SEGNO_ENGINE_MIDI_PORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Ring capacity per port (power of two). One slot stays empty to tell full
 * from empty, so 255 events fit between two drains: at the slowest block the
 * engine runs (4096 frames at 44.1 kHz, 93 ms), a 300 BPM clock delivers 12
 * pulses and a dense keyboard a few dozen messages. */
#define LE_MIDI_PORT_RING_CAP 256u
#define LE_MIDI_PORT_RING_MASK (LE_MIDI_PORT_RING_CAP - 1u)

/* One message as the audio thread sees it. `t_ns` is CLOCK_MONOTONIC (the
 * base of le_now_ns) at arrival; `gen` is the port generation it was pushed
 * under. Status, data1 and data2 are the raw bytes of a complete message
 * (unused data bytes are 0). 16 bytes. */
typedef struct le_midi_port_event {
  uint64_t t_ns;
  uint32_t gen;
  uint8_t status;
  uint8_t data1;
  uint8_t data2;
  uint8_t reserved;
} le_midi_port_event;

struct le_midi_sink;

/* One engine-owned input port slot. Zero-initialised is unbound and empty. */
typedef struct le_midi_port {
  /* Bumped by every bind and unbind (control thread); read by the producer
   * through its sink and by the consumer to recognise stale events. */
  _Atomic uint32_t a_gen;
  /* 1 after the bound capture's device went away or the capture closed while
   * bound; cleared by the next bind. */
  _Atomic int32_t a_lost;
  /* 0, or the ring index the latest message lost to a full ring would have
   * taken, plus one. Moved forward by the producer, cleared by the
   * consumer once its head has passed it. */
  _Atomic size_t a_gap;
  /* The sink bound to this port, or NULL. Control thread only. */
  struct le_midi_sink* _Atomic a_owner;
  _Atomic size_t head; /* consumer index */
  _Atomic size_t tail; /* producer index */
  le_midi_port_event ring[LE_MIDI_PORT_RING_CAP];
} le_midi_port;

/* The capture side of a binding: the first member of every capture handle. */
typedef struct le_midi_sink {
  le_midi_port* _Atomic port; /* NULL when unbound */
  _Atomic uint32_t gen;        /* the port generation this binding pushes */
  _Atomic int32_t in_flight;   /* producer accesses in progress */
} le_midi_sink;

/* The operations are C only. This header reaches the VST3 C++ translation
 * units through engine_private.h, whose C++ atomics shim covers only the
 * struct members above (written with the `_Atomic T` qualifier form so the
 * shim's empty `_Atomic` leaves valid C++); no C++ code calls these. */
#ifndef __cplusplus

#include <stdatomic.h>
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h> /* SwitchToThread */
#else
#include <sched.h> /* sched_yield */
#endif

/* ---- producer (the capture's OS MIDI thread) ---------------------------- */

/* Opens the quiescence bracket and returns the bound port, or NULL. Every
 * enter is paired with le_midi_sink_leave, whatever it returned. */
static inline le_midi_port* le_midi_sink_enter(le_midi_sink* s) {
  atomic_fetch_add_explicit(&s->in_flight, 1, memory_order_seq_cst);
  return atomic_load_explicit(&s->port, memory_order_seq_cst);
}

static inline void le_midi_sink_leave(le_midi_sink* s) {
  atomic_fetch_sub_explicit(&s->in_flight, 1, memory_order_release);
}

/* Pushes one message to the bound port, if any. Returns 1 when enqueued, 0
 * when unbound or when the ring was full (then the port records the gap). */
static inline int le_midi_sink_push(le_midi_sink* s, uint8_t status,
                                    uint8_t data1, uint8_t data2,
                                    uint64_t t_ns) {
  int pushed = 0;
  le_midi_port* p = le_midi_sink_enter(s);
  if (p != NULL) {
    const size_t tail = atomic_load_explicit(&p->tail, memory_order_relaxed);
    const size_t head = atomic_load_explicit(&p->head, memory_order_acquire);
    if (tail - head >= LE_MIDI_PORT_RING_CAP - 1u) {
      atomic_store_explicit(&p->a_gap, tail + 1u, memory_order_release);
    } else {
      le_midi_port_event* e = &p->ring[tail & LE_MIDI_PORT_RING_MASK];
      e->t_ns = t_ns;
      e->gen = atomic_load_explicit(&s->gen, memory_order_relaxed);
      e->status = status;
      e->data1 = data1;
      e->data2 = data2;
      e->reserved = 0;
      atomic_store_explicit(&p->tail, tail + 1u, memory_order_release);
      pushed = 1;
    }
  }
  le_midi_sink_leave(s);
  return pushed;
}

/* Marks the bound port lost (the device went away under an open capture).
 * Returns 1 when a port was bound. */
static inline int le_midi_sink_mark_lost(le_midi_sink* s) {
  int marked = 0;
  le_midi_port* p = le_midi_sink_enter(s);
  if (p != NULL) {
    atomic_store_explicit(&p->a_lost, 1, memory_order_release);
    marked = 1;
  }
  le_midi_sink_leave(s);
  return marked;
}

/* ---- consumer (the audio thread) ----------------------------------------- */

/* Pops the oldest event into *out and its ring index into *index (may be
 * NULL). Returns 1, or 0 when empty. */
static inline int le_midi_port_pop(le_midi_port* p, le_midi_port_event* out,
                                   size_t* index) {
  const size_t head = atomic_load_explicit(&p->head, memory_order_relaxed);
  const size_t tail = atomic_load_explicit(&p->tail, memory_order_acquire);
  if (head == tail) return 0;
  *out = p->ring[head & LE_MIDI_PORT_RING_MASK];
  if (index != NULL) *index = head;
  atomic_store_explicit(&p->head, head + 1u, memory_order_release);
  return 1;
}

/* The consumer's view of a gap: 0 when none, else the index the latest lost
 * message would have taken plus one. Every queued event with an index below
 * that precedes the loss; every later one follows it. */
static inline size_t le_midi_port_gap(le_midi_port* p) {
  return atomic_load_explicit(&p->a_gap, memory_order_acquire);
}

/* Clears a gap the consumer has dealt with. If the producer moved the mark
 * forward meanwhile, the newer mark is kept for the next drain. */
static inline void le_midi_port_clear_gap(le_midi_port* p, size_t gap) {
  atomic_compare_exchange_strong_explicit(&p->a_gap, &gap, 0,
                                          memory_order_acq_rel,
                                          memory_order_relaxed);
}

/* ---- control (bind / unbind) --------------------------------------------- */

static inline void le_midi_sink_wait_quiescent(le_midi_sink* s) {
  while (atomic_load_explicit(&s->in_flight, memory_order_seq_cst) != 0) {
#if defined(_WIN32)
    SwitchToThread();
#else
    sched_yield();
#endif
  }
}

/* Detaches `s` from its port, if any, and returns that port. When this
 * returns, the old producer can no longer write the port. The port's
 * generation advances, its owner is cleared, and `lost` (1 for a capture that
 * closed while bound) is stored. */
static inline le_midi_port* le_midi_sink_unbind(le_midi_sink* s, int lost) {
  le_midi_port* p =
      atomic_exchange_explicit(&s->port, NULL, memory_order_seq_cst);
  le_midi_sink_wait_quiescent(s);
  if (p == NULL) return NULL;
  struct le_midi_sink* expected = s;
  atomic_compare_exchange_strong_explicit(&p->a_owner, &expected, NULL,
                                          memory_order_acq_rel,
                                          memory_order_acquire);
  atomic_fetch_add_explicit(&p->a_gen, 1u, memory_order_acq_rel);
  if (lost) atomic_store_explicit(&p->a_lost, 1, memory_order_release);
  return p;
}

/* Detaches whatever sink is bound to `p`. Returns 1 when one was. */
static inline int le_midi_port_unbind(le_midi_port* p) {
  le_midi_sink* owner =
      atomic_load_explicit(&p->a_owner, memory_order_acquire);
  if (owner == NULL) return 0;
  return le_midi_sink_unbind(owner, 0) == p;
}

/* Binds `s` to `p`, first detaching `s` from any other port and `p` from any
 * other sink. Events pushed under earlier bindings become stale. */
static inline void le_midi_sink_bind(le_midi_sink* s, le_midi_port* p) {
  le_midi_sink_unbind(s, 0);
  le_midi_port_unbind(p);
  const uint32_t gen =
      atomic_fetch_add_explicit(&p->a_gen, 1u, memory_order_acq_rel) + 1u;
  atomic_store_explicit(&p->a_lost, 0, memory_order_release);
  atomic_store_explicit(&s->gen, gen, memory_order_relaxed);
  atomic_store_explicit(&p->a_owner, s, memory_order_release);
  atomic_store_explicit(&s->port, p, memory_order_seq_cst);
}

#endif /* !__cplusplus */

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_MIDI_PORT_H */
