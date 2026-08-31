/* alsashim -- presents one synthetic ALSA card to the Looper X app.
 *
 * Docker's kernel has no ALSA at all (no /proc/asound, no snd entries in
 * /proc/devices), so no real card can ever appear and the app segfaults during
 * RtApiAlsa's device enumeration.
 *
 * Only *enumeration* needs faking. alsa-lib's own `null` and `file` plugins are
 * pure userspace, so snd_pcm_open still goes to the real library -- we just
 * rewrite whatever device name was asked for into one that works. That keeps
 * the actual PCM path (hw_params negotiation, read/write, timing) real, which
 * matters: it is the path the captured audio will travel.
 *
 * The control side is faked wholesale. Every snd_ctl_* entry point the app can
 * reach is intercepted, so our sentinel handle is never handed to real alsa-lib.
 *
 * LOOPERX_PCM selects the substitute PCM (default "null"; set to a `file`
 * plugin spec to capture).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define ENODEV_ 19

/* Card/device identity the app expects to find (etc/asound.conf names HG08 as
 * the control card and UAC2Gadget as the PCM card). */
static const char *CARD_ID = "HG08";
static const char *CARD_NAME = "HG08";

/* Sentinel returned from snd_ctl_open. Never reaches real alsa-lib because
 * every snd_ctl_* the app uses is intercepted below. */
static int ctl_sentinel;
#define CTL ((void *)&ctl_sentinel)

/* LOOPERX_NO_AUDIO=1 makes the rig present NO sound cards at all, so RtAudio
 * finds zero devices and the app never starts its engine. Useful to reach the
 * UI when the engine path is the thing crashing. */
static int no_audio(void) {
  const char *e = getenv("LOOPERX_NO_AUDIO");
  return e && *e && *e != '0';
}

static const char *subst_pcm(void) {
  const char *e = getenv("LOOPERX_PCM");
  return (e && *e) ? e : "null";
}

/* ---- card enumeration: exactly one card, index 0 ------------------------- */

int snd_card_next(int *rcard) {
  if (!rcard) return -ENODEV_;
  *rcard = (!no_audio() && *rcard < 0) ? 0 : -1; /* card 0, then end of list */
  return 0;
}

int snd_card_get_index(const char *name) {
  (void)name;
  return 0; /* every name the app asks for is our one card */
}

int snd_card_get_name(int card, char **name) {
  (void)card;
  if (!name) return -ENODEV_;
  *name = strdup(CARD_NAME);
  return 0;
}

int snd_card_get_longname(int card, char **name) {
  return snd_card_get_name(card, name);
}

/* ---- control handles: all synthetic ------------------------------------- */

int snd_ctl_open(void **ctl, const char *name, int mode) {
  (void)name;
  (void)mode;
  if (!ctl || no_audio()) return -ENODEV_;
  *ctl = CTL;
  return 0;
}

int snd_ctl_open_lconf(void **ctl, const char *name, int mode, void *lconf) {
  (void)lconf;
  return snd_ctl_open(ctl, name, mode);
}

int snd_ctl_close(void *ctl) {
  (void)ctl;
  return 0;
}

int snd_ctl_card_info(void *ctl, void *info) {
  (void)ctl;
  (void)info; /* the getters below are intercepted, so nothing to fill */
  return 0;
}

const char *snd_ctl_card_info_get_id(const void *info) {
  (void)info;
  return CARD_ID;
}

const char *snd_ctl_card_info_get_name(const void *info) {
  (void)info;
  return CARD_NAME;
}

const char *snd_ctl_card_info_get_driver(const void *info) {
  (void)info;
  return "looperx-rig";
}

/* snd_ctl_card_info() leaves the caller's struct zeroed, so every getter has to
 * be covered -- a missed one returns an empty string, and an empty card name is
 * exactly what makes airDeviceIdentifier build an empty filename. */
const char *snd_ctl_card_info_get_longname(const void *info) {
  (void)info;
  return "HG08 Looper X internal audio";
}

const char *snd_ctl_card_info_get_mixername(const void *info) {
  (void)info;
  return CARD_NAME;
}

const char *snd_ctl_card_info_get_components(const void *info) {
  (void)info;
  return "";
}

int snd_ctl_card_info_get_card(const void *info) {
  (void)info;
  return 0;
}

/* One playback/capture device (0) per card, then end of list. */
int snd_ctl_pcm_next_device(void *ctl, int *device) {
  (void)ctl;
  if (!device) return -ENODEV_;
  *device = (*device < 0) ? 0 : -1;
  return 0;
}

int snd_ctl_pcm_info(void *ctl, void *info) {
  (void)ctl;
  (void)info;
  return 0;
}

int snd_ctl_rawmidi_next_device(void *ctl, int *device) {
  (void)ctl;
  if (device) *device = -1; /* no raw MIDI; MIDI comes over the seq shim */
  return 0;
}

int snd_ctl_rawmidi_info(void *ctl, void *info) {
  (void)ctl;
  (void)info;
  return -ENODEV_;
}

int snd_ctl_subscribe_events(void *ctl, int subscribe) {
  (void)ctl;
  (void)subscribe;
  return 0;
}

/* snd_ctl_pcm_info() above leaves the caller's snd_pcm_info_t zeroed, so
 * RtAudio would read an empty id and build a device name like "HG08 ()".
 * The app formats device names as "%1 (%2)" (card name, pcm id) and then looks
 * the result up in its KnownDeviceList, so both halves have to be real. */

const char *snd_pcm_info_get_name(const void *info) {
  (void)info;
  return CARD_NAME;
}

const char *snd_pcm_info_get_id(const void *info) {
  (void)info;
  return CARD_ID;
}

const char *snd_pcm_info_get_subdevice_name(const void *info) {
  (void)info;
  return CARD_NAME;
}

unsigned int snd_pcm_info_get_subdevices_count(const void *info) {
  (void)info;
  return 1;
}

unsigned int snd_pcm_info_get_subdevices_avail(const void *info) {
  (void)info;
  return 1;
}

unsigned int snd_pcm_info_get_device(const void *info) {
  (void)info;
  return 0;
}

int snd_pcm_info_get_card(const void *info) {
  (void)info;
  return 0;
}

/* ---- PCM: real alsa-lib, substituted device name ------------------------- */

/* RtAudio links the input and output PCMs so they share a hardware clock. Two
 * independent `null` devices cannot be linked, and the app treats the failure
 * as fatal -- report success, since there is no clock to synchronize. */
int snd_pcm_link(void *pcm1, void *pcm2) {
  (void)pcm1;
  (void)pcm2;
  return 0;
}

int snd_pcm_unlink(void *pcm) {
  (void)pcm;
  return 0;
}

/* ---- hw_params: make the device look like real hardware ------------------
 *
 * alsa-lib's `null` advertises everything: RATE [1 .. 4294967295],
 * BUFFER_SIZE [1 .. 4294967295], CHANNELS [1 .. 1073741823]. Wrapping it in a
 * `plug` does NOT help, because plug converts rather than constrains -- the
 * client still sees the wide ranges and sizes itself from them.
 *
 * The app reads these maxima to size a pool of DSP buffers, allocates a few
 * dozen, and then clears the pool using a count derived from the advertised
 * numbers -- walking ~10000 entries off the end of a ~20 entry array and
 * memset()ing whatever heap follows. Clamping the getters to a plausible
 * audio interface is what stops that.
 */
#define RIG_RATE 48000u
#define RIG_CHANS 4u  /* the HG08 has four inputs (Input 1..4 in its UI) */
#define RIG_PERIOD 256ul
#define RIG_PERIODS 4u
#define RIG_BUFFER (RIG_PERIOD * RIG_PERIODS)

#define GET_U(name, value)                                    \
  int name(const void *p, unsigned int *v) {                  \
    (void)p;                                                  \
    if (v) *v = (value);                                      \
    return 0;                                                 \
  }
#define GET_UL(name, value)                                   \
  int name(const void *p, unsigned long *v) {                 \
    (void)p;                                                  \
    if (v) *v = (value);                                      \
    return 0;                                                 \
  }
#define GET_U_DIR(name, value)                                \
  int name(const void *p, unsigned int *v, int *d) {          \
    (void)p;                                                  \
    if (v) *v = (value);                                      \
    if (d) *d = 0;                                            \
    return 0;                                                 \
  }
#define GET_UL_DIR(name, value)                               \
  int name(const void *p, unsigned long *v, int *d) {         \
    (void)p;                                                  \
    if (v) *v = (value);                                      \
    if (d) *d = 0;                                            \
    return 0;                                                 \
  }

GET_U(snd_pcm_hw_params_get_channels_min, RIG_CHANS)
GET_U(snd_pcm_hw_params_get_channels_max, RIG_CHANS)
GET_U_DIR(snd_pcm_hw_params_get_rate_min, RIG_RATE)
GET_U_DIR(snd_pcm_hw_params_get_rate_max, RIG_RATE)
GET_UL_DIR(snd_pcm_hw_params_get_period_size_min, RIG_PERIOD)
GET_UL_DIR(snd_pcm_hw_params_get_period_size_max, RIG_PERIOD)
GET_U_DIR(snd_pcm_hw_params_get_periods_min, RIG_PERIODS)
GET_U_DIR(snd_pcm_hw_params_get_periods_max, RIG_PERIODS)
GET_UL(snd_pcm_hw_params_get_buffer_size_min, RIG_BUFFER)
GET_UL(snd_pcm_hw_params_get_buffer_size_max, RIG_BUFFER)

int snd_pcm_open(void **pcm, const char *name, int stream, int mode) {
  static int (*real)(void **, const char *, int, int);
  if (!real) real = dlsym(RTLD_NEXT, "snd_pcm_open");
  if (!real) return -ENODEV_;
  if (no_audio()) return -ENODEV_;
  const char *sub = subst_pcm();
  fprintf(stderr, "[alsashim] snd_pcm_open(%s) -> %s\n", name ? name : "(null)",
          sub);
  return real(pcm, sub, stream, mode);
}
