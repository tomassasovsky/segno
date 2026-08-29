/*
 * engine_linux.c — Linux implementation of the engine platform seam
 * (engine_platform.h).
 *
 * Linux carries two real capabilities the portable core does not: a backend
 * preference (JACK first, since miniaudio's PulseAudio backend returns silent
 * capture under PipeWire's pulse emulation) plus PipeWire quantum forcing, and
 * JACK port-pinning that repins our ports to the user-selected interface. The
 * whole file is wrapped in `#if defined(__linux__)` so it compiles to a
 * near-empty object on macOS/Windows — a dummy typedef in the `#else` keeps the
 * translation unit non-empty (an entirely #if'd-out TU is UB in ISO C and warns
 * under -Wempty-translation-unit / -pedantic).
 */
#if defined(__linux__)

#include <dlfcn.h>
#include <errno.h>     /* errno for the mlockall / getrlimit diagnostics */
#include <pthread.h>   /* pthread_setschedparam for the appliance RT audio thread */
#include <sched.h>     /* SCHED_FIFO, struct sched_param */
#include <stdarg.h>    /* va_list for the once-per-process memlock diagnostic */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>     /* mlockall / munlockall (le_platform_*_memory) */
#include <sys/resource.h> /* getrlimit / RLIMIT_MEMLOCK — the mlockall guard */
#include <sys/stat.h>  /* stat() — probe /proc/asound/cardN pcm direction */

#include "engine_platform.h"  /* the seam */
#include "engine_private.h"   /* struct le_engine, enumerate_devices, store_i32;
                               * le_config / le_device_info / LE_MAX_CHANNELS /
                               * LE_OK + ma_backend arrive transitively */

/* Test-only override of the pin below: <0 means "read the environment" (the
 * shipping behaviour, and the value in every non-test process). See
 * le_platform_set_alsa_only_for_test. */
static int g_alsa_only_override = -1;

/* The appliance sets SEGNO_ALSA_ONLY (via the kiosk launcher): a single app owns
 * the card with no PipeWire/JACK/Pulse in the image, so we drive ALSA directly
 * for the lowest latency and zero IPC, and skip all the PipeWire quantum plumbing.
 * Read once and cache — the env does not change over a process's life. */
static int le_alsa_only(void) {
  /* Checked BEFORE the cache, deliberately. The cache is a function-static
   * primed on the first call anywhere in the process, so by the time a test
   * wants the other value it is already frozen — putenv/setenv at that point is
   * a silent no-op, and so is setenv in a fork()ed child, which inherits the
   * primed cache. The override is the only way to ask this question twice. */
  if (g_alsa_only_override >= 0) return g_alsa_only_override;
  static int cached = -1;
  if (cached < 0) {
    const char* v = getenv("SEGNO_ALSA_ONLY");
    cached = (v != NULL && v[0] != '\0' && v[0] != '0') ? 1 : 0;
  }
  return cached;
}

void le_platform_set_alsa_only_for_test(int state) {
  g_alsa_only_override = state;
}

/* Force PipeWire's global graph quantum to `frames` (0 restores the dynamic
 * quantum). The per-app PIPEWIRE_QUANTUM env wins only on the first connection
 * and loses to another driver's quantum on a reopen, so we force it globally.
 * Best-effort: pw-metadata ships with PipeWire; if it is missing or fails, the
 * env remains the fallback, so a discarded result is intentional. */
static void le_pipewire_force_quantum(int frames) {
  char cmd[160];
  snprintf(cmd, sizeof(cmd),
           "pw-metadata -n settings 0 clock.force-quantum %d >/dev/null 2>&1",
           frames);
  (void)system(cmd);
}

/* JACK port flags (jack/types.h). */
#define LE_JACK_INPUT 0x1UL
#define LE_JACK_OUTPUT 0x2UL
#define LE_JACK_PHYSICAL 0x4UL
/* jack_client_open option: never auto-start a JACK server for a transient probe. */
#define LE_JACK_NO_START_SERVER 0x1
/* Well-known JACK metadata key (jack/metadata.h) — PipeWire publishes a node's
 * description here, giving us "Scarlett 4i4 USB" instead of the raw node id. */
#define LE_JACK_PRETTY_NAME "http://jackaudio.org/metadata/pretty-name"

/* The trailing decimal index of a port name (e.g. "…AUX10" -> 10), or -1 when it
 * has none — used to sort ports numerically rather than by registration order. */
static long le_trailing_int(const char* s) {
  size_t end = strlen(s);
  size_t i = end;
  while (i > 0 && s[i - 1] >= '0' && s[i - 1] <= '9') --i;
  return i < end ? strtol(s + i, NULL, 10) : -1;
}

/* Reconnects our `count` JACK ports (ppPorts) to the selected device's ports
 * whose name begins with `prefix` ("<name>:capture_" / ":playback_"), in order,
 * dropping miniaudio's aggregate auto-connections; the rest are left silent.
 * Returns the device's matching port count (so the caller can publish it as the
 * channel count). `flags` selects which device ports to match; `we_are_src`
 * is 1 for playback (our port -> device), 0 for capture (device -> our port). */
typedef const char** (*le_jack_get_ports_t)(void*, const char*, const char*,
                                            unsigned long);
typedef int (*le_jack_link_t)(void*, const char*, const char*);
typedef const char* (*le_jack_pname_t)(void*);
typedef const char** (*le_jack_conns_t)(void*, void*);
typedef void (*le_jack_free_t)(void*);

static int32_t le_jack_rewire(void* client, le_jack_get_ports_t get_ports,
                              le_jack_link_t connect_port,
                              le_jack_link_t disconnect_port,
                              le_jack_pname_t port_name,
                              le_jack_conns_t port_conns, le_jack_free_t jfree,
                              void** ppPorts, int32_t count, const char* prefix,
                              unsigned long flags, int we_are_src) {
  const char** all = get_ports(client, NULL, NULL, flags);
  if (all == NULL) return 0;
  const char* match[LE_MAX_CHANNELS];
  int32_t m = 0;
  const size_t plen = strlen(prefix);
  for (int k = 0; all[k] != NULL && m < LE_MAX_CHANNELS; ++k) {
    if (strncmp(all[k], prefix, plen) == 0) match[m++] = all[k];
  }
  /* jack_get_ports returns registration order, not numeric — sort by the port
   * name's trailing index (e.g. AUX2 before AUX10) so channel i maps to the i-th
   * physical channel. Names without a trailing number keep their order (stable
   * insertion sort), covering FL/FR-style ports. */
  for (int32_t a = 1; a < m; ++a) {
    const char* key = match[a];
    const long kn = le_trailing_int(key);
    int32_t b = a - 1;
    while (b >= 0 && le_trailing_int(match[b]) > kn) {
      match[b + 1] = match[b];
      --b;
    }
    match[b + 1] = key;
  }
  for (int32_t i = 0; i < count; ++i) {
    void* port = ppPorts[i];
    if (port == NULL) continue;
    const char* mine = port_name(port);
    const char** cur = port_conns(client, port);
    if (cur != NULL) {
      for (int j = 0; cur[j] != NULL; ++j) {
        if (we_are_src) {
          disconnect_port(client, mine, cur[j]);
        } else {
          disconnect_port(client, cur[j], mine);
        }
      }
      jfree((void*)cur);
    }
    if (i < m) {
      if (we_are_src) {
        connect_port(client, mine, match[i]);
      } else {
        connect_port(client, match[i], mine);
      }
    }
  }
  jfree((void*)all);
  return m;
}

/* miniaudio's JACK backend auto-connects our ports to ALL physical system ports
 * — every device PipeWire aggregates — so on a multi-device box our channels
 * land on the wrong hardware (a webcam mic on input 0, etc.). Rewire our ports
 * to connect ONLY to the user-selected device's "<name>:capture_*" /
 * ":playback_*" ports (skipping its monitor ports), in order, and publish that
 * device's channel count, so the mapping and the exposed channel count match the
 * interface like on CoreAudio. Best-effort: leaves the default auto-connections
 * if anything is unavailable. */
static void le_jack_pin_to_device(le_engine* engine, const le_config* config) {
  if (!engine->context_initialised ||
      engine->context.backend != ma_backend_jack) {
    return;
  }
  void* client = engine->device.jack.pClient;
  if (client == NULL) return;

  void* lib = dlopen("libjack.so.0", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) lib = dlopen("libjack.so", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) return;

  le_jack_get_ports_t get_ports =
      (le_jack_get_ports_t)dlsym(lib, "jack_get_ports");
  le_jack_link_t connect_port = (le_jack_link_t)dlsym(lib, "jack_connect");
  le_jack_link_t disconnect_port = (le_jack_link_t)dlsym(lib, "jack_disconnect");
  le_jack_pname_t port_name = (le_jack_pname_t)dlsym(lib, "jack_port_name");
  le_jack_conns_t port_conns =
      (le_jack_conns_t)dlsym(lib, "jack_port_get_all_connections");
  le_jack_free_t jfree = (le_jack_free_t)dlsym(lib, "jack_free");

  if (get_ports && connect_port && disconnect_port && port_name && port_conns &&
      jfree) {
    /* The selected device id IS the JACK client/node name (that is how
     * le_platform_enumerate_devices reports it), so the port prefix is just
     * "<id>:capture_" / "<id>:playback_" — no name resolution needed. An empty
     * id (system default) or a stale non-JACK id simply matches no ports, and
     * le_jack_rewire leaves miniaudio's default auto-connections in place. */
    char prefix[300];

    const char* cap_id = config->capture_device_id;
    if (cap_id != NULL && cap_id[0] != '\0') {
      snprintf(prefix, sizeof(prefix), "%s:capture_", cap_id);
      int32_t m = le_jack_rewire(
          client, get_ports, connect_port, disconnect_port, port_name,
          port_conns, jfree, (void**)engine->device.jack.ppPortsCapture,
          engine->in_channels, prefix, LE_JACK_OUTPUT, /*we_are_src=*/0);
      if (m > 0 && m <= engine->in_channels) {
        store_i32(&engine->a_in_channels, m);
      }
    }

    const char* play_id = config->playback_device_id;
    if (play_id != NULL && play_id[0] != '\0') {
      snprintf(prefix, sizeof(prefix), "%s:playback_", play_id);
      int32_t m = le_jack_rewire(
          client, get_ports, connect_port, disconnect_port, port_name,
          port_conns, jfree, (void**)engine->device.jack.ppPortsPlayback,
          engine->out_channels, prefix, LE_JACK_INPUT, /*we_are_src=*/1);
      if (m > 0 && m <= engine->out_channels) {
        store_i32(&engine->a_out_channels, m);
      }
    }
  }
  dlclose(lib);
}

/* ---- platform seam ---- */

/* JACK entry points used only for enumeration (opened transiently, separate from
 * the engine's own client). jack_client_open is variadic in the header, but we
 * pass no variadic args, so a fixed 3-arg pointer is ABI-correct. The metadata
 * trio is optional — older libjack lacks it — so each is NULL-guarded. */
typedef void* (*le_jack_open_t)(const char*, int, int*);
typedef int (*le_jack_close_t)(void*);
typedef char* (*le_jack_uuid_for_name_t)(void*, const char*);
typedef int (*le_jack_uuid_parse_t)(const char*, uint64_t*);
typedef int (*le_jack_get_prop_t)(uint64_t, const char*, char**, char**);

/* Resolve a JACK client/node's friendly name via its pretty-name metadata
 * (PipeWire publishes node.description there). Leaves out[0]='\0' if the
 * metadata API or the property is absent, so the caller can fall back. */
static void le_jack_pretty_name(void* client, const char* node,
                                le_jack_uuid_for_name_t uuid_for_name,
                                le_jack_uuid_parse_t uuid_parse,
                                le_jack_get_prop_t get_prop,
                                le_jack_free_t jfree, char* out, size_t cap) {
  out[0] = '\0';
  if (!uuid_for_name || !uuid_parse || !get_prop) return;
  char* uuid_str = uuid_for_name(client, node);
  if (uuid_str == NULL) return;
  uint64_t uuid = 0;
  if (uuid_parse(uuid_str, &uuid) == 0) {
    char* value = NULL;
    char* type = NULL;
    if (get_prop(uuid, LE_JACK_PRETTY_NAME, &value, &type) == 0 &&
        value != NULL) {
      strncpy(out, value, cap - 1);
      out[cap - 1] = '\0';
    }
    if (value) jfree(value);
    if (type) jfree(type);
  }
  jfree(uuid_str);
}

/* Lowest PCM device index on ALSA card `card` that has a stream in the requested
 * direction, or -1 if none — probed from /proc/asound/cardN/pcm<dev><c|p>. */
static int le_alsa_card_pcm_dev(int card, int capture) {
  const char suffix = capture ? 'c' : 'p';
  for (int dev = 0; dev < 8; ++dev) {
    char path[64];
    struct stat st;
    snprintf(path, sizeof(path), "/proc/asound/card%d/pcm%d%c", card, dev,
             suffix);
    if (stat(path, &st) == 0) return dev;
  }
  return -1;
}

/* ---- ALSA channel-count probe ----
 *
 * /proc/asound says a card EXISTS and which directions it has, but never how
 * WIDE it is: no file under /proc/asound/cardN carries a channel count for a
 * device that is not currently streaming. The count lives in the PCM's
 * hardware-parameter space, so the only way to learn it is to open the device
 * and ask it.
 *
 * libasound is dlopen'd rather than linked, exactly as this file already
 * reaches libjack and as miniaudio reaches its own ALSA backend — the Linux
 * engine link line is `-lpthread -lm -ldl` and this must not add to it. A
 * missing or unusable libasound leaves every count at 0 (UNKNOWN), which the
 * picker renders as "no readout" rather than as a zero.
 */

/* snd_pcm_stream_t values and the open mode we want (alsa/pcm.h). */
#define LE_SND_PCM_STREAM_PLAYBACK 0
#define LE_SND_PCM_STREAM_CAPTURE 1
#define LE_SND_PCM_NONBLOCK 0x00000001

/* snd_pcm_t / snd_pcm_hw_params_t are opaque to callers, so `void*` here is the
 * whole of their public shape — no ALSA headers needed to call through them. */
typedef int (*le_snd_open_t)(void**, const char*, int, int);
typedef int (*le_snd_close_t)(void*);
typedef int (*le_snd_hwp_malloc_t)(void**);
typedef void (*le_snd_hwp_free_t)(void*);
typedef int (*le_snd_hwp_any_t)(void*, void*);
typedef int (*le_snd_hwp_chan_max_t)(const void*, unsigned int*);
/* snd_lib_error_set_handler; NULL restores libasound's default handler. */
typedef void (*le_snd_err_fn_t)(const char*, int, const char*, int,
                                const char*, ...);
typedef int (*le_snd_err_set_t)(le_snd_err_fn_t);

/* The libasound entry points the probe needs. `lib == NULL` means "ALSA
 * unavailable" and makes every probe answer 0 — enumeration itself still
 * succeeds, since a card list without widths is strictly better than no card
 * list. */
typedef struct le_alsa_syms {
  void* lib;
  le_snd_open_t pcm_open;
  le_snd_close_t pcm_close;
  le_snd_hwp_malloc_t hwp_malloc;
  le_snd_hwp_free_t hwp_free;
  le_snd_hwp_any_t hwp_any;
  le_snd_hwp_chan_max_t hwp_chan_max;
  le_snd_err_set_t err_set; /* optional — probe still works without it */
} le_alsa_syms;

static void le_alsa_syms_resolve(le_alsa_syms* s) {
  memset(s, 0, sizeof(*s));
  s->lib = dlopen("libasound.so.2", RTLD_NOW | RTLD_LOCAL);
  if (s->lib == NULL) s->lib = dlopen("libasound.so", RTLD_NOW | RTLD_LOCAL);
  if (s->lib == NULL) return;
  s->pcm_open = (le_snd_open_t)dlsym(s->lib, "snd_pcm_open");
  s->pcm_close = (le_snd_close_t)dlsym(s->lib, "snd_pcm_close");
  s->hwp_malloc = (le_snd_hwp_malloc_t)dlsym(s->lib, "snd_pcm_hw_params_malloc");
  s->hwp_free = (le_snd_hwp_free_t)dlsym(s->lib, "snd_pcm_hw_params_free");
  s->hwp_any = (le_snd_hwp_any_t)dlsym(s->lib, "snd_pcm_hw_params_any");
  s->hwp_chan_max =
      (le_snd_hwp_chan_max_t)dlsym(s->lib, "snd_pcm_hw_params_get_channels_max");
  s->err_set = (le_snd_err_set_t)dlsym(s->lib, "snd_lib_error_set_handler");
  if (!s->pcm_open || !s->pcm_close || !s->hwp_malloc || !s->hwp_free ||
      !s->hwp_any || !s->hwp_chan_max) {
    dlclose(s->lib);
    memset(s, 0, sizeof(*s)); /* partial resolve == unusable, same as absent */
  }
}

/* Resolved once and kept for the life of the process — deliberately never
 * dlclosed. snd_pcm_open builds libasound's global config tree (it parses
 * alsa.conf) and caches it behind a library global; unloading the library drops
 * that global without freeing the tree, so a dlopen/dlclose per enumeration
 * would orphan a fresh copy on every pass. Holding the handle keeps ALSA's
 * cache alive to be reused instead, and also skips re-relocating the library.
 * Same cache-it-once idiom as le_alsa_only(): the control thread owns
 * enumeration (see engine_devices.c's ownership note), so no locking. */
static const le_alsa_syms* le_alsa_syms_get(void) {
  static le_alsa_syms syms;
  static int resolved = 0;
  if (!resolved) {
    resolved = 1;
    le_alsa_syms_resolve(&syms);
  }
  return &syms;
}

/* Swallows the probe's own ALSA diagnostics. Installed only around the open and
 * removed straight after, so the engine's real device opens keep the default
 * handler and still report failures. */
static void le_alsa_quiet(const char* file, int line, const char* function,
                          int err, const char* fmt, ...) {
  (void)file;
  (void)line;
  (void)function;
  (void)err;
  (void)fmt;
}

/* The widest channel count hw:<card>,<dev> can carry in `capture`'s direction,
 * or 0 when the card cannot be asked. Opens real hardware — go through
 * le_alsa_channels_cached rather than calling this per enumeration. */
static int32_t le_alsa_pcm_channels_max(const le_alsa_syms* s, int card,
                                        int dev, int capture) {
  if (s->lib == NULL) return 0;
  /* hw: — the raw device, the same one the id ":<card>,<dev>" opens. Going
   * through plughw/default would answer about a conversion plugin's arbitrary
   * capabilities, not about the hardware the user picked. */
  char name[32];
  snprintf(name, sizeof(name), "hw:%d,%d", card, dev);

  void* pcm = NULL;
  const int stream =
      capture ? LE_SND_PCM_STREAM_CAPTURE : LE_SND_PCM_STREAM_PLAYBACK;
  /* Non-blocking, so a card someone else already holds fails fast with -EBUSY
   * instead of parking enumeration on it. On the appliance that other holder is
   * our OWN engine, and a running engine already publishes its negotiated count
   * through the status snapshot — so the picker has a count either way, and the
   * probe only has to answer for cards that are idle.
   *
   * A busy card is an ordinary, expected outcome here, not a fault, so mute
   * libasound's default handler across the open — it would otherwise write an
   * "open ... failed: Device or resource busy" line to stderr for the streaming
   * card every time the list is refreshed. Restored (NULL = default) straight
   * after, so this never hides a failure on the engine's own open path. */
  if (s->err_set != NULL) s->err_set(le_alsa_quiet);
  const int rc = s->pcm_open(&pcm, name, stream, LE_SND_PCM_NONBLOCK);
  if (s->err_set != NULL) s->err_set(NULL);
  if (rc < 0) return 0;

  int32_t channels = 0;
  void* params = NULL;
  if (s->hwp_malloc(&params) >= 0) {
    unsigned int value = 0;
    /* _any fills params with the device's FULL capability space, nothing
     * narrowed down yet — which is the question being asked here: how wide can
     * this card go, not how wide some stream happens to be configured. */
    if (s->hwp_any(pcm, params) >= 0 && s->hwp_chan_max(params, &value) >= 0) {
      /* A driver that answers with more channels than any device could have
       * (the ALSA "unlimited" placeholder is 10000, and plugin devices do use
       * it) has told us nothing, so keep 0 = UNKNOWN rather than print it.
       * MA_MAX_CHANNELS is also the ceiling test_enumerate_devices_runs holds
       * enumeration to, so bounding here keeps that invariant true by
       * construction on this path. */
      if (value > 0 && value <= MA_MAX_CHANNELS) channels = (int32_t)value;
    }
    s->hwp_free(params);
  }
  s->pcm_close(pcm);
  return channels;
}

/* ---- width memo ----
 *
 * The picker re-enumerates on a 1s timer, through a synchronous FFI call on the
 * UI isolate, in both directions per tick. Probing from there unconditionally
 * would open every card's /dev/snd node ~2N times a second on that thread — a
 * recurring stall on a Pi, where a USB card's open path runs control transfers,
 * and a repeated intrusion on the very device the engine is streaming.
 *
 * A card's width cannot change while the card is present, so it is asked once
 * and remembered. Identity is (card, dev, direction) PLUS the card's name,
 * because ALSA reuses card indices: unplugging one interface and plugging
 * another can hand index 1 back with different hardware behind it, and the name
 * change is what catches that.
 *
 * UNKNOWN (0) is cached too — otherwise the busy streaming card, the exact case
 * the storm was worst for, would be re-probed on every tick forever. It is
 * retried every LE_ALSA_RETRY_EVERY passes so a card that was merely busy
 * becomes knowable once the engine lets go, without a clock and at ~1/64 of the
 * cost. In the meantime the running device's count still reaches the UI through
 * the engine's status snapshot.
 */
#define LE_ALSA_MEMO_MAX 16
#define LE_ALSA_RETRY_EVERY 64

typedef struct le_alsa_memo {
  int used;
  int card;
  int dev;
  int capture;
  char name[64];
  int32_t channels;
  unsigned probed_at; /* le_alsa_enum_seq when this was last probed */
} le_alsa_memo;

/* Bumped once per enumeration pass; the only "time" the retry rule needs. */
static unsigned le_alsa_enum_seq;

static int32_t le_alsa_channels_cached(const le_alsa_syms* s, int card, int dev,
                                       int capture, const char* name) {
  static le_alsa_memo memo[LE_ALSA_MEMO_MAX];
  le_alsa_memo* slot = NULL;
  for (int i = 0; i < LE_ALSA_MEMO_MAX; ++i) {
    if (!memo[i].used) {
      if (slot == NULL) slot = &memo[i]; /* first free, in case we miss */
      continue;
    }
    if (memo[i].card == card && memo[i].dev == dev &&
        memo[i].capture == capture) {
      if (strncmp(memo[i].name, name, sizeof(memo[i].name) - 1) != 0) {
        slot = &memo[i]; /* index reused by different hardware — re-probe */
        break;
      }
      /* A known width is final; an UNKNOWN gets another chance periodically. */
      if (memo[i].channels > 0 ||
          le_alsa_enum_seq - memo[i].probed_at < LE_ALSA_RETRY_EVERY) {
        return memo[i].channels;
      }
      slot = &memo[i];
      break;
    }
  }

  const int32_t channels = le_alsa_pcm_channels_max(s, card, dev, capture);
  /* More cards than slots is not expected; such a card simply goes unmemoized
   * rather than evicting a live entry. */
  if (slot != NULL) {
    slot->used = 1;
    slot->card = card;
    slot->dev = dev;
    slot->capture = capture;
    strncpy(slot->name, name, sizeof(slot->name) - 1);
    slot->name[sizeof(slot->name) - 1] = '\0';
    slot->channels = channels;
    slot->probed_at = le_alsa_enum_seq;
  }
  return channels;
}

/* Appliance ALSA enumeration: one clean entry per real sound card from
 * /proc/asound/cards (e.g. "Scarlett 4i4 USB"), NOT the ALSA PCM-hint namespace
 * (default, sysdefault, plughw, dmix, front, surround40, samplerate, speex, ...)
 * which is the clutter miniaudio would otherwise surface. The id is
 * ":<card>,<dev>", which is exactly the token miniaudio's simplified ALSA
 * enumeration produces for that hardware device, so le_resolve_device_id still
 * pins it and it opens the raw device directly. Cards without a PCM in the
 * requested direction (HDMI has no capture, say) are skipped. */
static int le_alsa_enumerate_cards(le_device_info* out, int32_t max,
                                   int32_t* count, int capture) {
  *count = 0;
  FILE* f = fopen("/proc/asound/cards", "r");
  if (f == NULL) return 0;

  /* Process-lifetime handle; the memo below keeps the actual probing rare. */
  const le_alsa_syms* alsa = le_alsa_syms_get();
  ++le_alsa_enum_seq;

  char line[512];
  int32_t n = 0;
  while (n < max && fgets(line, sizeof(line), f) != NULL) {
    /* Card header lines start with the index: " 2 [USB    ]: USB-Audio - Name".
     * The indented continuation line (the longname) has no leading digit. */
    const char* p = line;
    while (*p == ' ') ++p;
    if (*p < '0' || *p > '9') continue;
    const int card = (int)strtol(p, NULL, 10);
    if (card < 0) continue;

    /* Card name = text after " - " (the driver's card name, e.g. the friendly
     * interface name), trimmed. */
    char* name = strstr(line, " - ");
    if (name == NULL) continue;
    name += 3;
    size_t len = strlen(name);
    while (len > 0 && (name[len - 1] == '\n' || name[len - 1] == '\r' ||
                       name[len - 1] == ' ')) {
      name[--len] = '\0';
    }
    if (len == 0) continue;

    /* Drop the SoC HDMI audio outputs — a live-looping appliance routes through
     * its audio interface, not the display's HDMI audio, so they are only clutter
     * in the picker. Matched by the vc4-hdmi card name. */
    if (strstr(line, "vc4-hdmi") != NULL || strstr(line, "vc4hdmi") != NULL) {
      continue;
    }

    const int dev = le_alsa_card_pcm_dev(card, capture);
    if (dev < 0) continue; /* no PCM in this direction on this card */

    le_device_info* d = &out[n];
    memset(d, 0, sizeof(*d));
    snprintf(d->id, sizeof(d->id), ":%d,%d", card, dev);
    strncpy(d->name, name, sizeof(d->name) - 1);
    d->name[sizeof(d->name) - 1] = '\0';
    /* Only the direction being enumerated — this card was listed because it has
     * a PCM in that direction, and it says nothing about the other one here.
     * Mirrors what the portable miniaudio path fills in device_info_copy. */
    if (capture) {
      d->input_channels =
          le_alsa_channels_cached(alsa, card, dev, capture, name);
    } else {
      d->output_channels =
          le_alsa_channels_cached(alsa, card, dev, capture, name);
    }
    ++n;
  }

  fclose(f);
  *count = n;
  return n > 0 ? 1 : 0;
}

static int le_jack_enumerate_devices(le_device_info* out, int32_t max,
                                     int32_t* count, int capture) {
  *count = 0;
  void* lib = dlopen("libjack.so.0", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) lib = dlopen("libjack.so", RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) return 0; /* no JACK/PipeWire -> defer to ALSA enumeration */

  le_jack_open_t jopen = (le_jack_open_t)dlsym(lib, "jack_client_open");
  le_jack_close_t jclose = (le_jack_close_t)dlsym(lib, "jack_client_close");
  le_jack_get_ports_t get_ports =
      (le_jack_get_ports_t)dlsym(lib, "jack_get_ports");
  le_jack_free_t jfree = (le_jack_free_t)dlsym(lib, "jack_free");
  le_jack_uuid_for_name_t uuid_for_name =
      (le_jack_uuid_for_name_t)dlsym(lib, "jack_get_uuid_for_client_name");
  le_jack_uuid_parse_t uuid_parse =
      (le_jack_uuid_parse_t)dlsym(lib, "jack_uuid_parse");
  le_jack_get_prop_t get_prop =
      (le_jack_get_prop_t)dlsym(lib, "jack_get_property");

  if (!jopen || !jclose || !get_ports || !jfree) {
    dlclose(lib);
    return 0;
  }

  int status = 0;
  void* client = jopen("segno-enum", LE_JACK_NO_START_SERVER, &status);
  if (client == NULL) {
    dlclose(lib); /* server not running -> defer to ALSA enumeration */
    return 0;
  }

  /* One entry per real interface. capture wants the device's OUTPUT ports (it
   * produces audio into the graph), playback its INPUT ports; physical-only
   * keeps it to hardware, not app/monitor nodes. Group ports by their
   * "<node>:" prefix — that prefix is the id le_jack_pin_to_device pins by.
   * Grouping also yields the channel count for free: one physical port IS one
   * channel, so the size of each group is the device's width in this direction,
   * which is why the loop below counts as well as names. */
  const unsigned long flags =
      (capture ? LE_JACK_OUTPUT : LE_JACK_INPUT) | LE_JACK_PHYSICAL;
  const char** ports = get_ports(client, NULL, NULL, flags);

  int32_t n = 0;
  for (int k = 0; ports != NULL && ports[k] != NULL && n < max; ++k) {
    const char* colon = strchr(ports[k], ':');
    if (colon == NULL) continue;
    const size_t plen = (size_t)(colon - ports[k]);
    if (plen == 0 || plen >= sizeof(out[0].id)) continue;

    int32_t found = -1;
    for (int32_t d = 0; d < n; ++d) {
      if (strncmp(out[d].id, ports[k], plen) == 0 && out[d].id[plen] == '\0') {
        found = d;
        break;
      }
    }
    if (found >= 0) {
      if (capture) {
        out[found].input_channels++;
      } else {
        out[found].output_channels++;
      }
      continue;
    }

    le_device_info* dev = &out[n];
    memset(dev, 0, sizeof(*dev));
    memcpy(dev->id, ports[k], plen);
    dev->id[plen] = '\0';
    if (capture) {
      dev->input_channels = 1;
    } else {
      dev->output_channels = 1;
    }
    le_jack_pretty_name(client, dev->id, uuid_for_name, uuid_parse, get_prop,
                        jfree, dev->name, sizeof(dev->name));
    if (dev->name[0] == '\0') {
      strncpy(dev->name, dev->id, sizeof(dev->name) - 1);
      dev->name[sizeof(dev->name) - 1] = '\0';
    }
    ++n;
  }

  if (ports != NULL) jfree((void*)ports);
  jclose(client);
  dlclose(lib);

  if (n == 0) return 0; /* JACK up but no hardware ports -> let ALSA try */
  *count = n;
  return 1;
}

/* ---- library-presence probes (#649) ----
 *
 * le_linux_enum_route_pick (engine_devices.c, where the id-consistency
 * rationale lives) needs to know which of libjack/libpulse exist BEFORE any
 * enumerator runs: "libjack absent" routes differently from "libjack present
 * but the server declined" (only the former may fall through to the ALSA
 * cards list), and le_jack_enumerate_devices collapses both into a 0 return.
 *
 * A probe is one dlopen/dlclose pair — the same call le_jack_enumerate_devices
 * already makes on every tick — and is deliberately NOT cached across ticks:
 * a session that gains PipeWire/JACK mid-run (a package install starting the
 * service) must switch to JACK ids on the next poll, because the OPEN backend
 * order (le_platform_backends) would reach JACK too, and cards ids cannot
 * resolve there. dlopen of an absent library fails in microseconds against
 * the ld.so cache; of a present one it bumps a refcount. Nothing here runs
 * under the appliance pin (see le_platform_enumerate_devices).
 *
 * Test-only overrides, same pattern and reason as g_alsa_only_override: >= 0
 * pins the answer, < 0 probes for real. */
static int g_jack_present_override = -1;
static int g_pulse_present_override = -1;

static int le_lib_present(const char* soname, const char* fallback) {
  void* lib = dlopen(soname, RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) lib = dlopen(fallback, RTLD_NOW | RTLD_LOCAL);
  if (lib == NULL) return 0;
  dlclose(lib);
  return 1;
}

static int le_jack_present(void) {
  if (g_jack_present_override >= 0) return g_jack_present_override;
  return le_lib_present("libjack.so.0", "libjack.so");
}

static int le_pulse_present(void) {
  if (g_pulse_present_override >= 0) return g_pulse_present_override;
  /* The same sonames miniaudio's PulseAudio backend dlopens, so "present" here
   * means "the open would land on Pulse", mirroring the backend order. */
  return le_lib_present("libpulse.so.0", "libpulse.so");
}

void le_platform_set_enum_libs_for_test(int jack_present, int pulse_present) {
  g_jack_present_override = jack_present;
  g_pulse_present_override = pulse_present;
}

int le_platform_enumerate_devices(le_device_info* out, int32_t max,
                                  int32_t* count, int capture) {
  /* The pin is read first and short-circuits the library probes, so the
   * appliance tick is byte-identical to what it was before #649: one
   * le_alsa_enumerate_cards call, no dlopen traffic.
   * test_enum_seam_fallthrough_and_appliance_pin pins this. */
  const int alsa_only = le_alsa_only();
  const le_linux_enum_route route = le_linux_enum_route_pick(
      alsa_only, alsa_only ? 0 : le_jack_present(),
      alsa_only ? 0 : le_pulse_present());
  switch (route) {
    case LE_LINUX_ENUM_ALSA_CARDS:
      /* Appliance pin, or the pure-ALSA desktop fall-through (#649) — the
       * route table in engine_devices.c argues why the cards ids resolve on
       * the ALSA backend the open lands on. Declines (0) when no card has a
       * PCM in this direction, and the portable miniaudio backstop takes it —
       * the pinned unplugged-appliance behaviour (enumerate_devices). */
      return le_alsa_enumerate_cards(out, max, count, capture);
    case LE_LINUX_ENUM_JACK:
      /* Clean names + only real interfaces on PipeWire/JACK desktops. Still
       * declines at runtime (server down, zero hardware ports) to miniaudio —
       * that is a JACK-present host, so the cards fall-through must NOT catch
       * it: its open could land on JACK, where cards ids cannot resolve. */
      return le_jack_enumerate_devices(out, max, count, capture);
    case LE_LINUX_ENUM_MINIAUDIO:
    default:
      /* libpulse without libjack: miniaudio's probe and the open both land on
       * Pulse, ids match, and Pulse enumeration has no hint-clutter cost. */
      *count = 0;
      return 0;
  }
}

void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count) {
  /* Appliance (SEGNO_ALSA_ONLY): drive the card directly through ALSA — lowest
   * latency, zero IPC, and the image ships no PipeWire/JACK/Pulse anyway.
   * Elsewhere (desktop Linux) miniaudio's PulseAudio backend returns silent
   * capture buffers under PipeWire's pulse emulation (verified on a Clarett+
   * 8Pre: pulse = silence, JACK = full multichannel capture), so prefer JACK
   * (PipeWire ships a JACK server), then PulseAudio, then ALSA. */
  static const ma_backend k_alsa_only[] = {ma_backend_alsa};
  static const ma_backend k_backends[] = {
      ma_backend_jack, ma_backend_pulseaudio, ma_backend_alsa};
  if (le_alsa_only()) {
    *out_list = k_alsa_only;
    *out_count = 1;
  } else {
    *out_list = k_backends;
    *out_count = 3;
  }
}

void le_platform_probe_backends(const ma_backend** out_list,
                                ma_uint32* out_count) {
  /* Appliance only. The image has no PulseAudio server, and miniaudio's DEFAULT
   * order tries ma_backend_pulseaudio before ma_backend_alsa, so every probe
   * attempted a connection that could only fail — and each failure leaked a
   * memfd (#721). Excluding Pulse here is the whole fix.
   *
   * Desktop Linux deliberately gets (NULL, 0), NOT the streaming preference: a
   * probe context opened on JACK enumerates one synthetic default device per
   * direction instead of the real cards, and le_find_loopback's "monitor of"
   * match is a PulseAudio-only string that a JACK context can never produce.
   * The streaming path still prefers JACK — that is a different question, asked
   * of a device that is about to be opened, not of a list being read. */
  static const ma_backend k_alsa_only[] = {ma_backend_alsa};
  if (le_alsa_only()) {
    *out_list = k_alsa_only;
    *out_count = 1;
  } else {
    *out_list = NULL;
    *out_count = 0;
  }
}

void le_platform_before_context_init(const le_config* config) {
  /* ALSA takes its period directly from ma_device_config (periodSizeInFrames),
   * so the appliance needs none of the PipeWire quantum plumbing. */
  if (le_alsa_only()) return;
  /* JACK/PipeWire takes its buffer size (quantum) from the server and ignores
   * our requested period, so the in-app buffer selector would otherwise have no
   * effect on Linux latency. Two steps make it stick:
   *   1. export PIPEWIRE_QUANTUM before the JACK client connects (wins on the
   *      first connection);
   *   2. force the graph quantum globally via pw-metadata — a later reopen can
   *      otherwise inherit another driver's larger quantum (e.g. a webcam mic),
   *      and a per-app request loses to it. Best-effort: pw-metadata ships with
   *      PipeWire; if absent the env in (1) is the fallback. le_engine_destroy
   *      restores the dynamic quantum. */
  /* setenv is POSIX, not ISO C; declare it so a strict -std=c11 build (the
   * device-free test harness) sees it — the CMake build uses gnu11. */
  extern int setenv(const char* name, const char* value, int overwrite);
  /* Default to 256 frames (~5 ms) when no buffer is selected, instead of the
   * PipeWire server default (often 1024 / ~21 ms). */
  const int q_rate = config->sample_rate > 0 ? config->sample_rate : 48000;
  const int q_frames =
      config->buffer_frames > 0 ? (int)config->buffer_frames : 256;
  char quantum[32];
  snprintf(quantum, sizeof(quantum), "%d/%d", q_frames, q_rate);
  setenv("PIPEWIRE_QUANTUM", quantum, /*overwrite=*/1);
  le_pipewire_force_quantum(q_frames);
}

/* Appliance only: put the miniaudio worker thread (which runs the ALSA duplex
 * read/write loop and calls the audio callback, so it is the thread that must
 * meet the period deadline) on SCHED_FIFO 80 — above all normal work, with
 * headroom below for the USB sound-card IRQ thread (raised higher by the rtirq
 * service) so the interrupt delivering a period always preempts the thread
 * consuming it. Cross-thread setschedparam is fine. Needs LimitRTPRIO/MEMLOCK on
 * segno.service; without them it EPERMs and is a harmless no-op. */
static void le_alsa_set_rt_priority(le_engine* engine) {
  if (!le_alsa_only() || !engine->device_initialised) return;
  /* Opt-in via SEGNO_RT_AUDIO=1 (set by the kiosk launcher once the ALSA path is
   * validated). Gated so a misbehaving audio loop cannot hard-starve the machine
   * at SCHED_FIFO before it has been proven to sleep between periods. */
  const char* rt = getenv("SEGNO_RT_AUDIO");
  if (rt == NULL || rt[0] != '1') return;
  struct sched_param sp;
  memset(&sp, 0, sizeof(sp));
  sp.sched_priority = 80;
  (void)pthread_setschedparam(engine->device.thread, SCHED_FIFO, &sp);
}

void le_platform_after_device_open(le_engine* engine) {
  /* Appliance: promote the audio thread to real-time BEFORE it starts reading,
   * while it is still idle, so it never runs its deadline-critical first reads
   * at normal priority (which overruns the capture at tiny buffers). */
  le_alsa_set_rt_priority(engine);
}

void le_platform_after_device_start(le_engine* engine, const le_config* config) {
  /* Repin JACK ports to the selected interface (overriding miniaudio's connect-
   * to-every-physical-port default), so channels map to that device only. No-op
   * unless the JACK backend is active, so it does nothing on the ALSA appliance. */
  le_jack_pin_to_device(engine, config);
}

void le_platform_on_engine_teardown(void) {
  if (le_alsa_only()) return; /* no PipeWire quantum was forced */
  le_pipewire_force_quantum(0); /* restore PipeWire's dynamic quantum */
}

/* Pin the whole process into RAM. rt_alloc.h stops the audio thread faulting on
 * pages it WRITES; this stops it faulting on pages it merely touches — the
 * engine's text and rodata, the callback's own stack, the DSP tables, a hosted
 * plugin's binary. Those are reclaimable (file-backed text always is, even with
 * no swap configured), and re-faulting one is a MAJOR fault: disk I/O inside a
 * 333 us callback deadline.
 *
 * GUARDED ON THE RLIMIT, not on the appliance pin, and that guard is the whole
 * safety argument:
 *
 *   - It asks the only question that matters — has the operator actually
 *     granted this? The appliance's segno.service sets LimitMEMLOCK=infinity;
 *     a desktop gets systemd's 8 MB default, or whatever limits.conf gave the
 *     audio group. Gating on SEGNO_ALSA_ONLY instead would both miss a properly
 *     configured desktop rig and say nothing about whether the call can work.
 *
 *   - MCL_FUTURE is the half that could bite. Under it every later mapping is
 *     locked as it is made, and one that would exceed RLIMIT_MEMLOCK FAILS —
 *     an app-wide malloc returning NULL, not a slow path. With the limit at
 *     infinity there is no ceiling to exceed: a future allocation can only fail
 *     by genuinely exhausting RAM, which was already fatal on a unit with no
 *     swap. Under a finite limit we never make the call at all, so no desktop
 *     build can walk into that failure mode.
 *
 * MCL_ONFAULT IS NOT OPTIONAL HERE, and it is the difference between locking
 * what is resident and committing every RESERVATION in the address space.
 * Without it, mlockall pre-populates every readable mapping — and this process
 * is full of large, sparse, MAP_NORESERVE ones it must not commit: the Dart
 * VM's heap reservations, a hosted VST3/CLAP plugin's arena, and (in an
 * instrumented build) ASan's multi-terabyte shadow. On a machine that actually
 * granted the rlimit — that is, the appliance, the one configuration this
 * feature targets — pre-population is an OOM, not a slow start. With
 * MCL_ONFAULT the kernel locks the pages that are PRESENT and marks the rest to
 * be locked as they fault in, which is exactly the property being bought:
 * nothing the audio thread has touched can be reclaimed under it afterwards.
 * The only thing given up is pre-faulting pages nobody has touched yet, and the
 * buffers where that would have mattered are prefaulted by le_rt_alloc already.
 *
 * So if MCL_ONFAULT is unavailable (pre-4.4 kernel, or libc headers without
 * it), this SKIPS rather than falling back to the pre-populating form. The
 * protection is an improvement on a build that ran for years without it; the
 * fallback is a way to OOM the appliance.
 *
 * WHAT IT COSTS, stated because the audio side is not the whole story. This is
 * PROCESS-wide: the Dart heap, Skia's caches, decoded images and every
 * file-backed mapping the UI touches become unevictable too, so the kernel
 * loses clean pages as a reclaim source on a swapless 8 GB unit. Under memory
 * pressure the outcome shifts from "reclaim and degrade" to "OOM-kill segno".
 * MCL_ONFAULT keeps that bounded to what has actually been touched rather than
 * what has been reserved, and the appliance is a single-app kiosk whose
 * touched set is the set it needs — but it is a real change in failure MODE,
 * it is not measurable from a test suite, and it is the reason this ships
 * blocked-verify. On device: watch Locked: in /proc/<pid>/smaps_rollup over a
 * long session and confirm it plateaus rather than tracking RSS upward.
 *
 * Failure is never fatal, in any direction: an ungranted limit, a missing
 * MCL_ONFAULT, an EPERM, an ENOMEM — all of them log and return, and the engine
 * starts exactly as it does today. A user without the rlimit must still be able
 * to run the app; they just run it without this protection, which is where
 * every build stood before.
 *
 * Once per process (mlockall is process-wide, and le_engine_create can run more
 * than once in a host that recreates the engine) — but REFERENCE-COUNTED, not
 * latched, so le_platform_unlock_memory below can actually undo it. A latch
 * would make the lock one-way: MCL_FUTURE would go on locking every heap growth
 * and every dlopen for the rest of the process, long after the engine that
 * wanted it was destroyed.
 *
 * TWO pieces of state, not one, and the distinction is load-bearing:
 * g_memlock_refs counts LIVE ENGINES (every le_platform_lock_memory call takes
 * one, whether or not the lock could be taken), while g_memlock_held says
 * whether this code actually holds the process lock. Counting successful locks
 * instead would mean an engine whose lock attempt failed — a transient ENOMEM,
 * say — contributes no reference, so a later engine that succeeds takes the
 * count to 1 for two live engines, and the FIRST destroy munlockalls the
 * process out from under the second one's audio thread. Splitting them also
 * lets a later create retry a lock an earlier one could not get.
 *
 * The mutex is not paranoia about a hot path — neither function is one. It is
 * because both fields and the process-wide lock they describe have to move
 * together: two concurrent le_engine_creates could otherwise both find
 * g_memlock_held clear and both call mlockall. */
static pthread_mutex_t g_memlock_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_memlock_refs = 0; /* live engines that asked for the lock */
static int g_memlock_held = 0; /* whether WE hold the process-wide lock */
/* One diagnostic per process for the paths that DID NOT lock. The attempt
 * itself is retried on every create (cheap, and a later engine may find a
 * limit an earlier one did not), but the reason is process-wide and unchanging
 * in practice — and on a host without the grant, "once per engine create"
 * means the native suite writes thousands of identical lines and the appliance
 * writes them into a segno.log that never rotates. Same hazard rt_alloc.c
 * latches against for MADV_DONTFORK, same answer. */
static int g_memlock_skip_reported = 0;

static void le_memlock_report_skip(const char* fmt, ...)
    __attribute__((format(printf, 1, 2)));

static void le_memlock_report_skip(const char* fmt, ...) {
  if (g_memlock_skip_reported) return;
  g_memlock_skip_reported = 1;
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
}

void le_platform_lock_memory(void) {
  pthread_mutex_lock(&g_memlock_mu);
  ++g_memlock_refs; /* one per engine, taken before anything can fail */
  if (g_memlock_held) { /* already locked: the reference is all that is due */
    pthread_mutex_unlock(&g_memlock_mu);
    return;
  }
  struct rlimit lim;
  if (getrlimit(RLIMIT_MEMLOCK, &lim) != 0) {
    le_memlock_report_skip(
        "segno/rt: RLIMIT_MEMLOCK unreadable (errno %d); memory not locked "
        "(#804)\n",
        errno);
    pthread_mutex_unlock(&g_memlock_mu);
    return;
  }
  if (lim.rlim_cur != RLIM_INFINITY) {
    /* Not a warning: this is the normal state of a desktop Linux build. */
    le_memlock_report_skip(
        "segno/rt: RLIMIT_MEMLOCK is %llu bytes, not unlimited; skipping "
        "mlockall (grant LimitMEMLOCK=infinity to enable it)\n",
        (unsigned long long)lim.rlim_cur);
    pthread_mutex_unlock(&g_memlock_mu);
    return;
  }
#if defined(MCL_ONFAULT)
  if (mlockall(MCL_CURRENT | MCL_FUTURE | MCL_ONFAULT) != 0) {
    /* EINVAL here is the pre-4.4 kernel: the flag compiled but the running
     * kernel does not know it. Deliberately NOT retried without MCL_ONFAULT —
     * see above on why the pre-populating form is the worse outcome. */
    le_memlock_report_skip(
        "segno/rt: mlockall failed (errno %d); the audio thread can still "
        "take major faults (#804)\n",
        errno);
    pthread_mutex_unlock(&g_memlock_mu);
    return;
  }
  g_memlock_held = 1; /* only a lock we actually took is one we may undo */
  /* The success line is NOT latched: it fires on each 0 -> 1 transition, which
   * is once per process in every real host and exactly the signal an on-device
   * check greps for. */
  fprintf(stderr,
          "segno/rt: memory locked (mlockall MCL_CURRENT|MCL_FUTURE|"
          "MCL_ONFAULT)\n");
#else
  le_memlock_report_skip(
      "segno/rt: MCL_ONFAULT unavailable in this libc; skipping mlockall "
      "rather than pre-populating every reservation (#804)\n");
#endif
  pthread_mutex_unlock(&g_memlock_mu);
}

/* Releases the process-wide lock once the LAST engine is gone. A skipped or
 * failed lock left g_memlock_held clear, so this never munlockall's a process
 * this code did not lock — which matters because munlockall is process-wide
 * and would otherwise drop a lock some other component took. See
 * engine_platform.h. */
void le_platform_unlock_memory(void) {
  pthread_mutex_lock(&g_memlock_mu);
  if (g_memlock_refs == 0 ||  /* unbalanced call: nothing of ours to release */
      --g_memlock_refs > 0 || /* another engine is still live */
      !g_memlock_held) {      /* the lock was never taken in the first place */
    pthread_mutex_unlock(&g_memlock_mu);
    return;
  }
  g_memlock_held = 0;
  if (munlockall() != 0) {
    fprintf(stderr,
            "segno/rt: munlockall failed (errno %d); the process stays locked "
            "into RAM\n",
            errno);
  } else {
    fprintf(stderr, "segno/rt: memory unlocked (munlockall)\n");
  }
  pthread_mutex_unlock(&g_memlock_mu);
}

uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count) {
  /* No Linux channel-label source yet (PipeWire labels are future work). */
  (void)uid;
  (void)channel_count;
  return 0;
}

void le_platform_device_id_to_str(const ma_device_id* id, char* out,
                                  size_t cap) {
  /* ALSA/PulseAudio/JACK device ids are NUL-terminated char strings. */
  if (cap == 0) return;
  strncpy(out, (const char*)id, cap - 1);
  out[cap - 1] = '\0';
}

#else
typedef int segno_engine_linux_tu_unused; /* keep the TU non-empty off Linux */
#endif
