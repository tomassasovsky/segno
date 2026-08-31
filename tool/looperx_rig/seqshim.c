/* seqshim -- presents a synthetic ALSA sequencer carrying the HG08's own
 * control surface.
 *
 * There is no /dev/snd/seq in a container, so snd_seq_open fails. The app does
 * not check that result and alsa-lib then asserts inside
 * snd_seq_query_next_client, which was the first crash this rig hit. Failing
 * the call gracefully got past the assert but not past startup: the app blocks
 * inside engine-dependency initialisation waiting for its control surface,
 * which IS a MIDI device ("HG08 Control Surface MIDI 1"/"2", see
 * usr/Looper/Assignments/*.qml), so with no sequencer it waits forever and
 * never reaches QCoreApplication::exec().
 *
 * So rather than fail, present a whole sequencer: two clients, one port each,
 * named exactly what the shipped assignment files expect. Every accessor the
 * app can reach is intercepted, so the opaque info structs are never actually
 * read -- their contents do not matter, only the per-struct iteration state
 * this shim keeps alongside them.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define ENODEV_ 19
#define EAGAIN_ 11
#define ENOENT_ 2

/* The two control-surface clients the app's assignment files name. */
#define CLIENT_FIRST 128
#define CLIENT_LAST 129
static const char *client_name(int id) {
  return id == CLIENT_FIRST ? "HG08 Control Surface MIDI 1"
                            : "HG08 Control Surface MIDI 2";
}

static int tag_seq;
#define SEQ ((void *)&tag_seq)

/* Iteration state per info struct. The app allocates these on the stack
 * (snd_seq_*_info_alloca), so key by address; a handful of slots is plenty for
 * the nested client/port enumeration loops. */
#define SLOTS 16
static struct {
  const void *key;
  int client, port;
} slots[SLOTS];

static int *slot_client(const void *k) {
  for (int i = 0; i < SLOTS; ++i)
    if (slots[i].key == k) return &slots[i].client;
  for (int i = 0; i < SLOTS; ++i)
    if (!slots[i].key) {
      slots[i].key = k;
      slots[i].client = -1;
      slots[i].port = -1;
      return &slots[i].client;
    }
  return &slots[0].client;
}

static int *slot_port(const void *k) {
  slot_client(k); /* ensure the slot exists */
  for (int i = 0; i < SLOTS; ++i)
    if (slots[i].key == k) return &slots[i].port;
  return &slots[0].port;
}

/* ---- handle lifecycle ----------------------------------------------------- */

int snd_seq_open(void **h, const char *name, int streams, int mode) {
  (void)name; (void)streams; (void)mode;
  if (!h) return -ENODEV_;
  *h = SEQ;
  fprintf(stderr, "[seqshim] sequencer opened\n");
  return 0;
}

int snd_seq_open_lconf(void **h, const char *name, int streams, int mode,
                       void *lconf) {
  (void)lconf;
  return snd_seq_open(h, name, streams, mode);
}

int snd_seq_close(void *h) { (void)h; return 0; }
int snd_seq_set_client_name(void *h, const char *n) { (void)h; (void)n; return 0; }
int snd_seq_client_id(void *h) { (void)h; return 200; } /* our own client */
int snd_seq_nonblock(void *h, int nb) { (void)h; (void)nb; return 0; }
int snd_seq_drop_input(void *h) { (void)h; return 0; }
int snd_seq_drain_output(void *h) { (void)h; return 0; }

/* ---- client enumeration --------------------------------------------------- */

void snd_seq_client_info_set_client(void *info, int client) {
  *slot_client(info) = client;
}

int snd_seq_client_info_get_client(const void *info) {
  return *slot_client(info);
}

int snd_seq_query_next_client(void *h, void *info) {
  (void)h;
  if (!info) return -ENOENT_;
  int *c = slot_client(info);
  int next = (*c < CLIENT_FIRST) ? CLIENT_FIRST : *c + 1;
  if (next > CLIENT_LAST) return -ENOENT_;
  *c = next;
  return 0;
}

const char *snd_seq_client_info_get_name(void *info) {
  return client_name(*slot_client(info));
}

int snd_seq_get_any_client_info(void *h, int client, void *info) {
  (void)h;
  *slot_client(info) = client;
  return 0;
}

/* ---- port enumeration ----------------------------------------------------- */

void snd_seq_port_info_set_client(void *info, int client) {
  *slot_client(info) = client;
}

void snd_seq_port_info_set_port(void *info, int port) {
  *slot_port(info) = port;
}

int snd_seq_port_info_get_client(const void *info) {
  return *slot_client(info);
}

int snd_seq_port_info_get_port(const void *info) {
  return *slot_port(info);
}

int snd_seq_query_next_port(void *h, void *info) {
  (void)h;
  if (!info) return -ENOENT_;
  int *p = slot_port(info);
  if (*p >= 0) return -ENOENT_; /* exactly one port per client */
  *p = 0;
  return 0;
}

const char *snd_seq_port_info_get_name(const void *info) {
  return client_name(*slot_client((void *)info));
}

/* READ|WRITE|SUBS_READ|SUBS_WRITE|DUPLEX -- a full bidirectional MIDI port. */
unsigned int snd_seq_port_info_get_capability(const void *info) {
  (void)info;
  return 1u | 2u | 16u | 32u | 64u;
}

/* SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_PORT */
unsigned int snd_seq_port_info_get_type(const void *info) {
  (void)info;
  return (1u << 1) | (1u << 19);
}

int snd_seq_get_any_port_info(void *h, int client, int port, void *info) {
  (void)h;
  *slot_client(info) = client;
  *slot_port(info) = port;
  return 0;
}

/* ---- connections and events ----------------------------------------------- */

int snd_seq_create_simple_port(void *h, const char *name, unsigned int caps,
                               unsigned int type) {
  (void)h; (void)name; (void)caps; (void)type;
  return 0; /* port number 0 */
}

int snd_seq_connect_from(void *h, int myport, int client, int port) {
  (void)h; (void)myport; (void)client; (void)port;
  return 0;
}

int snd_seq_connect_to(void *h, int myport, int client, int port) {
  (void)h; (void)myport; (void)client; (void)port;
  return 0;
}

int snd_seq_subscribe_port(void *h, void *sub) { (void)h; (void)sub; return 0; }
int snd_seq_unsubscribe_port(void *h, void *sub) { (void)h; (void)sub; return 0; }

/* No hardware is generating events, so the input side is simply always empty.
 * Returning -EAGAIN is the "nothing pending" answer callers expect. */
int snd_seq_event_input(void *h, void **ev) {
  (void)h;
  if (ev) *ev = 0;
  return -EAGAIN_;
}

int snd_seq_event_input_pending(void *h, int fetch) {
  (void)h; (void)fetch;
  return 0;
}

int snd_seq_event_output(void *h, void *ev) { (void)h; (void)ev; return 0; }
int snd_seq_event_output_direct(void *h, void *ev) { (void)h; (void)ev; return 0; }

/* The app runs a MIDI input thread that polls the sequencer's descriptors.
 * Handing back zero descriptors makes that thread fail or spin, so give it one
 * real pipe that simply never becomes readable: the thread blocks harmlessly
 * and no phantom events are ever delivered. */
static int quiet_fd = -1;

static int quiet_descriptor(void) {
  if (quiet_fd < 0) {
    int fds[2];
    if (pipe(fds) == 0) quiet_fd = fds[0]; /* write end stays open, never written */
  }
  return quiet_fd;
}

int snd_seq_poll_descriptors_count(void *h, short events) {
  (void)h; (void)events;
  return 1;
}

struct rig_pollfd { int fd; short events; short revents; };

int snd_seq_poll_descriptors(void *h, void *pfds, unsigned int space,
                             short events) {
  (void)h;
  if (!pfds || space < 1) return 0;
  struct rig_pollfd *p = pfds;
  p->fd = quiet_descriptor();
  p->events = events;
  p->revents = 0;
  return 1;
}
