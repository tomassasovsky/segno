/*
 * segno-prof: look inside the running Segno app without stopping it (#1299).
 *
 *   segno-prof stack <pid> [tid] [samples] [interval-ms]
 *       Samples one thread's stack through ptrace and prints folded stacks
 *       ("root;...;leaf count", flamegraph.pl input), busiest first. Only that
 *       thread is paused, for microseconds per sample; the audio thread never
 *       is. tid defaults to the main thread, which runs GTK and the Dart UI
 *       isolate. Frames are named from each file's .symtab when it has one
 *       (experimental builds keep libapp.so's Dart symbols) and from .dynsym
 *       otherwise; an address outside every known symbol prints as
 *       file:0x<address>.
 *
 *   segno-prof gsources <pid> [--csv]
 *       Counts the GSources attached to the app's default GLib main context,
 *       grouped by kind and callback. GLib walks every one of them on each
 *       main-loop iteration, which is how #1299 pinned the main thread. --csv
 *       prints one line: attached,embedder_timeouts,idle,next_id.
 *       The context address comes from /run/segno/main-context, which the app
 *       writes at startup. The struct offsets are GLib 2.84's private layout,
 *       so any other version is refused rather than misread.
 *
 * aarch64 only: the frame walk follows the AAPCS64 x29 frame-pointer chain.
 */
#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <unistd.h>

#if !defined(__aarch64__)
#error "segno-prof walks aarch64 frame pointers"
#endif

static pid_t target;

static int peek(uint64_t addr, void *buf, size_t len) {
  struct iovec local = {buf, len};
  struct iovec remote = {(void *)(uintptr_t)addr, len};
  return process_vm_readv(target, &local, 1, &remote, 1, 0) == (ssize_t)len ? 0 : -1;
}

static uint64_t peek64(uint64_t addr) {
  uint64_t value = 0;
  peek(addr, &value, sizeof value);
  return value;
}

static uint32_t peek32(uint64_t addr) {
  uint32_t value = 0;
  peek(addr, &value, sizeof value);
  return value;
}

static void *xcalloc(size_t n, size_t size) {
  void *p = calloc(n, size);
  if (p == NULL) {
    perror("calloc");
    exit(1);
  }
  return p;
}

/* ------------------------------------------------------------------------ */
/* Symbols                                                                  */

typedef struct {
  uint64_t value;
  uint64_t size;
  const char *name;
} Sym;

typedef struct {
  char *path;
  const char *base; /* basename of path */
  int loaded;
  const unsigned char *image;
  size_t image_len;
  Sym *syms;
  size_t nsyms;
} Obj;

typedef struct {
  uint64_t start, end, offset;
  Obj *obj; /* NULL for anonymous and [special] mappings */
  char label[32];
} Map;

static Map *maps;
static size_t nmaps;
static Obj *objs;
static size_t nobjs;

static int sym_cmp(const void *a, const void *b) {
  const Sym *x = a, *y = b;
  return x->value < y->value ? -1 : x->value > y->value;
}

/* Reads one symbol table section. Keeps functions and data objects (the
 * census names GLib's exported GSourceFuncs tables). */
static void add_symbols(Obj *o, const Elf64_Shdr *sh, const Elf64_Shdr *shdrs,
                        uint16_t nsh) {
  if (sh->sh_link >= nsh || sh->sh_entsize != sizeof(Elf64_Sym)) return;
  const Elf64_Shdr *strsh = &shdrs[sh->sh_link];
  if (sh->sh_offset + sh->sh_size > o->image_len ||
      strsh->sh_offset + strsh->sh_size > o->image_len)
    return;
  const Elf64_Sym *table = (const Elf64_Sym *)(o->image + sh->sh_offset);
  const char *strings = (const char *)(o->image + strsh->sh_offset);
  size_t count = sh->sh_size / sizeof(Elf64_Sym);
  o->syms = xcalloc(count, sizeof(Sym));
  for (size_t i = 0; i < count; i++) {
    unsigned type = ELF64_ST_TYPE(table[i].st_info);
    if (table[i].st_value == 0 || table[i].st_name >= strsh->sh_size) continue;
    if (type != STT_FUNC && type != STT_OBJECT) continue;
    o->syms[o->nsyms++] = (Sym){table[i].st_value, table[i].st_size,
                                strings + table[i].st_name};
  }
  qsort(o->syms, o->nsyms, sizeof(Sym), sym_cmp);
}

static void load_obj(Obj *o) {
  o->loaded = 1;
  int fd = open(o->path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return;
  struct stat st;
  if (fstat(fd, &st) == 0 && st.st_size > (off_t)sizeof(Elf64_Ehdr)) {
    void *image = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (image != MAP_FAILED) {
      o->image = image;
      o->image_len = st.st_size;
    }
  }
  close(fd);
  if (o->image == NULL) return;
  const Elf64_Ehdr *eh = (const Elf64_Ehdr *)o->image;
  if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 ||
      eh->e_ident[EI_CLASS] != ELFCLASS64 ||
      eh->e_shoff + (uint64_t)eh->e_shnum * sizeof(Elf64_Shdr) > o->image_len)
    return;
  const Elf64_Shdr *shdrs = (const Elf64_Shdr *)(o->image + eh->e_shoff);
  const Elf64_Shdr *symtab = NULL, *dynsym = NULL;
  for (uint16_t i = 0; i < eh->e_shnum; i++) {
    if (shdrs[i].sh_type == SHT_SYMTAB) symtab = &shdrs[i];
    if (shdrs[i].sh_type == SHT_DYNSYM) dynsym = &shdrs[i];
  }
  if (symtab != NULL) add_symbols(o, symtab, shdrs, eh->e_shnum);
  if (o->nsyms == 0 && dynsym != NULL) {
    free(o->syms);
    o->syms = NULL;
    add_symbols(o, dynsym, shdrs, eh->e_shnum);
  }
}

/* Turns a file offset into the virtual address the symbol table uses. */
static uint64_t file_offset_to_vaddr(const Obj *o, uint64_t offset) {
  const Elf64_Ehdr *eh = (const Elf64_Ehdr *)o->image;
  if (eh->e_phoff + (uint64_t)eh->e_phnum * sizeof(Elf64_Phdr) > o->image_len)
    return offset;
  const Elf64_Phdr *ph = (const Elf64_Phdr *)(o->image + eh->e_phoff);
  for (uint16_t i = 0; i < eh->e_phnum; i++) {
    if (ph[i].p_type == PT_LOAD && offset >= ph[i].p_offset &&
        offset < ph[i].p_offset + ph[i].p_filesz)
      return offset - ph[i].p_offset + ph[i].p_vaddr;
  }
  return offset;
}

/* objs grows while maps load, so maps hold an index until it is final. */
static size_t obj_index_for_path(const char *path) {
  for (size_t i = 0; i < nobjs; i++)
    if (strcmp(objs[i].path, path) == 0) return i;
  objs = realloc(objs, (nobjs + 1) * sizeof(Obj));
  if (objs == NULL) {
    perror("realloc");
    exit(1);
  }
  Obj *o = &objs[nobjs];
  memset(o, 0, sizeof *o);
  o->path = strdup(path);
  const char *slash = strrchr(o->path, '/');
  o->base = slash ? slash + 1 : o->path;
  return nobjs++;
}

static void load_maps(void) {
  char path[64];
  snprintf(path, sizeof path, "/proc/%d/maps", target);
  FILE *f = fopen(path, "r");
  if (f == NULL) {
    perror(path);
    exit(1);
  }
  char line[4096];
  size_t *obj_index = NULL;
  while (fgets(line, sizeof line, f) != NULL) {
    uint64_t start, end, offset;
    char perms[8];
    int consumed = 0;
    if (sscanf(line, "%" SCNx64 "-%" SCNx64 " %7s %" SCNx64 " %*s %*s %n", &start,
               &end, perms, &offset, &consumed) < 4)
      continue;
    char *name = line + consumed;
    name[strcspn(name, "\n")] = '\0';
    maps = realloc(maps, (nmaps + 1) * sizeof(Map));
    obj_index = realloc(obj_index, (nmaps + 1) * sizeof(size_t));
    if (maps == NULL || obj_index == NULL) {
      perror("realloc");
      exit(1);
    }
    Map *m = &maps[nmaps];
    memset(m, 0, sizeof *m);
    m->start = start;
    m->end = end;
    m->offset = offset;
    obj_index[nmaps] = SIZE_MAX;
    if (name[0] == '/') {
      obj_index[nmaps] = obj_index_for_path(name);
    } else {
      snprintf(m->label, sizeof m->label, "%s", name[0] ? name : "[anon]");
    }
    nmaps++;
  }
  fclose(f);
  for (size_t i = 0; i < nmaps; i++)
    if (obj_index[i] != SIZE_MAX) maps[i].obj = &objs[obj_index[i]];
  free(obj_index);
}

static const Map *map_for(uint64_t addr) {
  for (size_t i = 0; i < nmaps; i++)
    if (addr >= maps[i].start && addr < maps[i].end) return &maps[i];
  return NULL;
}

/* Names addr. A symbol only claims addresses inside its recorded size;
 * anything else prints as file:0x<vaddr> rather than as a misleading
 * "nearest exported symbol + offset". */
static void symbolize(uint64_t addr, char *out, size_t len) {
  const Map *m = map_for(addr);
  if (m == NULL) {
    snprintf(out, len, "0x%" PRIx64, addr);
    return;
  }
  if (m->obj == NULL) {
    snprintf(out, len, "%s", m->label);
    return;
  }
  Obj *o = m->obj;
  if (!o->loaded) load_obj(o);
  uint64_t offset = addr - m->start + m->offset;
  uint64_t vaddr = o->image ? file_offset_to_vaddr(o, offset) : offset;
  size_t lo = 0, hi = o->nsyms;
  while (lo < hi) {
    size_t mid = (lo + hi) / 2;
    if (o->syms[mid].value <= vaddr)
      lo = mid + 1;
    else
      hi = mid;
  }
  if (lo > 0) {
    const Sym *s = &o->syms[lo - 1];
    if (vaddr < s->value + (s->size ? s->size : 1)) {
      snprintf(out, len, "%s", s->name);
      return;
    }
  }
  snprintf(out, len, "%s:0x%" PRIx64, o->base, vaddr);
}

/* Whether addr lies in a file whose name starts with prefix. */
static int addr_in_file(uint64_t addr, const char *prefix) {
  const Map *m = map_for(addr);
  return m != NULL && m->obj != NULL &&
         strncmp(m->obj->base, prefix, strlen(prefix)) == 0;
}

/* ------------------------------------------------------------------------ */
/* Counting strings (folded stacks, census groups)                          */

typedef struct {
  char *key;
  uint64_t count;
} Count;

typedef struct {
  Count *slots;
  size_t cap, used;
} Counter;

static uint64_t hash_str(const char *s) {
  uint64_t h = 1469598103934665603ULL;
  while (*s) h = (h ^ (unsigned char)*s++) * 1099511628211ULL;
  return h;
}

static void counter_add(Counter *c, const char *key) {
  if (c->used * 2 >= c->cap) {
    Counter grown = {xcalloc(c->cap ? c->cap * 2 : 256, sizeof(Count)),
                     c->cap ? c->cap * 2 : 256, 0};
    for (size_t i = 0; i < c->cap; i++) {
      if (c->slots[i].key == NULL) continue;
      size_t j = hash_str(c->slots[i].key) & (grown.cap - 1);
      while (grown.slots[j].key != NULL) j = (j + 1) & (grown.cap - 1);
      grown.slots[j] = c->slots[i];
      grown.used++;
    }
    free(c->slots);
    *c = grown;
  }
  size_t j = hash_str(key) & (c->cap - 1);
  while (c->slots[j].key != NULL && strcmp(c->slots[j].key, key) != 0)
    j = (j + 1) & (c->cap - 1);
  if (c->slots[j].key == NULL) {
    c->slots[j].key = strdup(key);
    c->used++;
  }
  c->slots[j].count++;
}

static int count_desc(const void *a, const void *b) {
  const Count *x = a, *y = b;
  return x->count < y->count ? 1 : x->count > y->count ? -1 : 0;
}

static void counter_print(Counter *c, FILE *out) {
  size_t n = 0;
  for (size_t i = 0; i < c->cap; i++)
    if (c->slots[i].key != NULL) c->slots[n++] = c->slots[i];
  qsort(c->slots, n, sizeof(Count), count_desc);
  for (size_t i = 0; i < n; i++)
    fprintf(out, "%s %" PRIu64 "\n", c->slots[i].key, c->slots[i].count);
}

/* ------------------------------------------------------------------------ */
/* stack                                                                    */

enum { kMaxDepth = 128 };

static volatile sig_atomic_t stop_requested;
static void on_signal(int sig) {
  (void)sig;
  stop_requested = 1;
}

/* Stops tid at a ptrace group-stop. Signals that arrive meanwhile are passed
 * on, never swallowed. */
static int interrupt_thread(pid_t tid) {
  if (ptrace(PTRACE_INTERRUPT, tid, 0, 0) < 0) return -1;
  for (;;) {
    int status;
    if (waitpid(tid, &status, __WALL) < 0) return -1;
    if (!WIFSTOPPED(status)) return -1;
    if ((status >> 16) == PTRACE_EVENT_STOP) return 0;
    ptrace(PTRACE_CONT, tid, 0, (void *)(uintptr_t)WSTOPSIG(status));
  }
}

static int cmd_stack(int argc, char **argv) {
  pid_t tid = argc > 3 ? atoi(argv[3]) : target;
  long samples = argc > 4 ? atol(argv[4]) : 1000;
  long interval_ms = argc > 5 ? atol(argv[5]) : 10;
  if (tid <= 0 || samples <= 0 || interval_ms < 0) {
    fprintf(stderr, "bad arguments\n");
    return 2;
  }
  load_maps();

  signal(SIGINT, on_signal);
  signal(SIGTERM, on_signal);
  if (ptrace(PTRACE_SEIZE, tid, 0, 0) < 0) {
    fprintf(stderr, "ptrace seize %d: %s\n", tid, strerror(errno));
    return 1;
  }

  Counter stacks = {0};
  uint64_t frames[kMaxDepth];
  long taken = 0;
  for (; taken < samples && !stop_requested; taken++) {
    if (interrupt_thread(tid) < 0) break;
    struct user_regs_struct regs;
    struct iovec io = {&regs, sizeof regs};
    int depth = 0;
    if (ptrace(PTRACE_GETREGSET, tid, (void *)NT_PRSTATUS, &io) == 0) {
      frames[depth++] = regs.pc;
      uint64_t fp = regs.regs[29];
      while (fp != 0 && depth < kMaxDepth) {
        uint64_t record[2]; /* saved fp, return address */
        if (peek(fp, record, sizeof record) < 0 || record[1] == 0) break;
        frames[depth++] = record[1] - 4; /* the call, not the instruction after */
        if (record[0] <= fp) break;
        fp = record[0];
      }
    }
    ptrace(PTRACE_CONT, tid, 0, 0);
    if (depth == 0) continue;

    char line[kMaxDepth * 96];
    size_t used = 0;
    line[0] = '\0';
    for (int i = depth - 1; i >= 0; i--) {
      char name[256];
      symbolize(frames[i], name, sizeof name);
      for (char *p = name; *p; p++)
        if (*p == ';' || *p == ' ') *p = '_';
      int wrote = snprintf(line + used, sizeof line - used, "%s%s",
                           used ? ";" : "", name);
      if (wrote < 0 || (size_t)wrote >= sizeof line - used) break;
      used += wrote;
    }
    counter_add(&stacks, line);
    if (interval_ms > 0) usleep(interval_ms * 1000);
  }
  ptrace(PTRACE_DETACH, tid, 0, 0);

  printf("# segno-prof stack pid=%d tid=%d samples=%ld interval_ms=%ld\n", target,
         tid, taken, interval_ms);
  counter_print(&stacks, stdout);
  return 0;
}

/* ------------------------------------------------------------------------ */
/* gsources                                                                 */

/* GLib 2.84 private layouts (glib/gmain.c, glib/ghash.c). */
enum {
  kContextSources = 56, /* GHashTable *sources, keyed by &source->source_id */
  kContextNextId = 80,  /* guint next_id */
  kHashSize = 0,
  kHashNnodes = 16,
  kHashFlags = 24, /* have_big_keys:1, have_big_values:1 */
  kHashValues = 48,
  kHashHashes = 40,
  kSourceIdOffset = 48, /* GSource.source_id: the hash key points here */
  kSourceWords = 12,    /* callback_data .. priv */
};

static int read_context_file(uint64_t *context) {
  FILE *f = fopen("/run/segno/main-context", "r");
  if (f == NULL) {
    fprintf(stderr, "/run/segno/main-context: %s (is the app running?)\n",
            strerror(errno));
    return -1;
  }
  int pid = 0;
  char glib[32] = "";
  int ok = fscanf(f, "%d %31s %" SCNx64, &pid, glib, context) == 3;
  fclose(f);
  if (!ok) {
    fprintf(stderr, "/run/segno/main-context: unreadable\n");
    return -1;
  }
  if (pid != target) {
    fprintf(stderr, "/run/segno/main-context is for pid %d, not %d\n", pid,
            target);
    return -1;
  }
  if (strncmp(glib, "2.84.", 5) != 0) {
    fprintf(stderr, "GLib %s: only 2.84's private layout is known\n", glib);
    return -1;
  }
  return 0;
}

static int cmd_gsources(int argc, char **argv) {
  int csv = argc > 3 && strcmp(argv[3], "--csv") == 0;
  uint64_t context;
  if (read_context_file(&context) < 0) return 1;
  load_maps();

  uint64_t table = peek64(context + kContextSources);
  uint32_t next_id = peek32(context + kContextNextId);
  uint64_t size = peek64(table + kHashSize);
  uint32_t flags = peek32(table + kHashFlags);
  if (table == 0 || size == 0 || size > (1u << 24) || (size & (size - 1)) ||
      !(flags & 2)) {
    fprintf(stderr, "main context does not look like GLib 2.84's\n");
    return 1;
  }
  uint32_t *hashes = xcalloc(size, sizeof(uint32_t));
  uint64_t *values = xcalloc(size, sizeof(uint64_t));
  if (peek(peek64(table + kHashHashes), hashes, size * 4) < 0 ||
      peek(peek64(table + kHashValues), values, size * 8) < 0) {
    fprintf(stderr, "cannot read the source table\n");
    return 1;
  }

  Counter groups = {0};
  unsigned attached = 0, embedder_timeouts = 0, idle = 0, foreign = 0;
  for (uint64_t i = 0; i < size; i++) {
    if (hashes[i] < 2) continue; /* 0 empty, 1 tombstone */
    uint64_t source = values[i] - kSourceIdOffset;
    uint64_t f[kSourceWords];
    /* Sources come and go while we read; a vanished one is skipped. */
    if (peek(source, f, sizeof f) < 0) continue;
    if (f[4] != context) {
      foreign++;
      continue;
    }
    if (!((f[5] >> 32) & 1)) continue; /* destroyed */
    attached++;

    char kind[128], callback[256] = "-", name[48] = "";
    symbolize(f[2], kind, sizeof kind);
    if (f[0] != 0 && addr_in_file(f[1], "libglib-2.0.so")) {
      /* g_source_set_callback's GSourceCallback: ref_count, func, data */
      uint64_t func = peek64(f[0] + 8);
      symbolize(func, callback, sizeof callback);
      if (addr_in_file(func, "libflutter_linux_gtk.so") &&
          strcmp(kind, "g_timeout_funcs") == 0)
        embedder_timeouts++;
    }
    if (strcmp(kind, "g_idle_funcs") == 0) idle++;
    if (f[10] != 0 && peek(f[10], name, sizeof name - 1) == 0) {
      for (char *p = name; *p; p++)
        if (*p < 32 || *p > 126) *p = '\0';
    }
    char key[512];
    snprintf(key, sizeof key, "%s %s%s%s", kind, callback, name[0] ? " " : "",
             name);
    counter_add(&groups, key);
  }
  if (attached == 0 && foreign > 0) {
    fprintf(stderr, "no source points back at the context: layout mismatch\n");
    return 1;
  }

  if (csv) {
    printf("%u,%u,%u,%u\n", attached, embedder_timeouts, idle, next_id);
    return 0;
  }
  printf("# segno-prof gsources pid=%d attached=%u embedder_timeouts=%u idle=%u "
         "next_id=%u\n",
         target, attached, embedder_timeouts, idle, next_id);
  counter_print(&groups, stdout);
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr,
            "usage: %s stack <pid> [tid] [samples] [interval-ms]\n"
            "       %s gsources <pid> [--csv]\n",
            argv[0], argv[0]);
    return 2;
  }
  target = atoi(argv[2]);
  if (target <= 0) {
    fprintf(stderr, "bad pid\n");
    return 2;
  }
  if (strcmp(argv[1], "stack") == 0) return cmd_stack(argc, argv);
  if (strcmp(argv[1], "gsources") == 0) return cmd_gsources(argc, argv);
  fprintf(stderr, "unknown command %s\n", argv[1]);
  return 2;
}
