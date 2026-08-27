/* udevshim -- presents one synthetic `sound` device to the Looper X app.
 *
 * The app's UDevMonitor filters the "sound" subsystem, and its
 * airDeviceIdentifier builds a KnownDevices filename out of the device's
 * vendor/product ids. With no udev in the container it finds nothing, the name
 * comes out empty ("Can't find file: \"\"") and startup never completes.
 *
 * Only enumeration and property lookup are faked, and only for the "sound"
 * subsystem -- Qt uses libudev too (input discovery), so anything it asks for
 * falls through to the real library untouched.
 *
 * Every property/sysattr key the app asks for is logged, so the set it
 * actually needs can be read off a run rather than guessed at.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SYSPATH "/sys/class/sound/card0"
#define SYSNAME "card0"

/* Sentinels. Distinct objects so the fall-through checks below are exact. */
static int tag_udev, tag_enum_sound, tag_dev, tag_entry;
#define UDEV ((void *)&tag_udev)
#define ENUM_SOUND ((void *)&tag_enum_sound)
#define DEV ((void *)&tag_dev)
#define ENTRY ((void *)&tag_entry)

static int mine(const void *p) {
  return p == UDEV || p == ENUM_SOUND || p == DEV || p == ENTRY;
}

/* Function-pointer types need a name inside the parentheses, so go through
 * typedefs rather than spelling the type at each use site. */
typedef void *(*fn_p_p)(void *);
typedef void *(*fn_p_ps)(void *, const char *);
typedef void *(*fn_p_pss)(void *, const char *, const char *);
typedef const char *(*fn_s_p)(void *);
typedef const char *(*fn_s_ps)(void *, const char *);
typedef int (*fn_i_ps)(void *, const char *);
typedef int (*fn_i_pss)(void *, const char *, const char *);
typedef int (*fn_i_p)(void *);

#define REAL(fn, T) \
  static T real_##fn; \
  if (!real_##fn) real_##fn = (T)dlsym(RTLD_NEXT, #fn);

/* ---- enumeration ---------------------------------------------------------- */

void *udev_enumerate_new(void *udev) {
  REAL(udev_enumerate_new, fn_p_p)
  return real_udev_enumerate_new ? real_udev_enumerate_new(udev) : ENUM_SOUND;
}

int udev_enumerate_add_match_subsystem(void *e, const char *subsystem) {
  REAL(udev_enumerate_add_match_subsystem, fn_i_ps)
  int r = real_udev_enumerate_add_match_subsystem
              ? real_udev_enumerate_add_match_subsystem(e, subsystem)
              : 0;
  if (subsystem && !strcmp(subsystem, "sound"))
    fprintf(stderr, "[udevshim] enumerate matches subsystem 'sound' (%p)\n", e);
  return r;
}

void *udev_enumerate_get_list_entry(void *e) {
  REAL(udev_enumerate_get_list_entry, fn_p_p)
  void *r = real_udev_enumerate_get_list_entry
                ? real_udev_enumerate_get_list_entry(e)
                : NULL;
  /* An empty sound enumeration is what we are here to fix. */
  if (!r) return ENTRY;
  return r;
}

const char *udev_list_entry_get_name(void *entry) {
  if (entry == ENTRY) return SYSPATH;
  REAL(udev_list_entry_get_name, fn_s_p)
  return real_udev_list_entry_get_name ? real_udev_list_entry_get_name(entry)
                                       : NULL;
}

void *udev_list_entry_get_next(void *entry) {
  if (entry == ENTRY) return NULL; /* exactly one device */
  REAL(udev_list_entry_get_next, fn_p_p)
  return real_udev_list_entry_get_next ? real_udev_list_entry_get_next(entry)
                                       : NULL;
}

/* ---- the device itself ---------------------------------------------------- */

void *udev_device_new_from_syspath(void *udev, const char *syspath) {
  if (syspath && !strcmp(syspath, SYSPATH)) return DEV;
  REAL(udev_device_new_from_syspath, fn_p_ps)
  return real_udev_device_new_from_syspath
             ? real_udev_device_new_from_syspath(udev, syspath)
             : NULL;
}

const char *udev_device_get_property_value(void *dev, const char *key) {
  if (dev == DEV) {
    fprintf(stderr, "[udevshim] property '%s'\n", key ? key : "(null)");
    if (!key) return NULL;
    if (!strcmp(key, "ID_VENDOR_ID")) return "0763";   /* inMusic */
    if (!strcmp(key, "ID_MODEL_ID")) return "501d";
    if (!strcmp(key, "ID_VENDOR")) return "inMusic";
    if (!strcmp(key, "ID_MODEL")) return "HG08";
    if (!strcmp(key, "ID_SERIAL")) return "HG08";
    if (!strcmp(key, "ID_BUS")) return "usb";
    if (!strcmp(key, "SUBSYSTEM")) return "sound";
    if (!strcmp(key, "DEVNAME")) return "/dev/snd/pcmC0D0p";
    return NULL;
  }
  REAL(udev_device_get_property_value, fn_s_ps)
  return real_udev_device_get_property_value
             ? real_udev_device_get_property_value(dev, key)
             : NULL;
}

const char *udev_device_get_sysattr_value(void *dev, const char *attr) {
  if (dev == DEV) {
    fprintf(stderr, "[udevshim] sysattr '%s'\n", attr ? attr : "(null)");
    if (!attr) return NULL;
    if (!strcmp(attr, "id")) return "HG08";
    if (!strcmp(attr, "idVendor")) return "0763";
    if (!strcmp(attr, "idProduct")) return "501d";
    if (!strcmp(attr, "manufacturer")) return "inMusic";
    if (!strcmp(attr, "product")) return "HG08";
    return NULL;
  }
  REAL(udev_device_get_sysattr_value, fn_s_ps)
  return real_udev_device_get_sysattr_value
             ? real_udev_device_get_sysattr_value(dev, attr)
             : NULL;
}

#define PASSTHRU_STR(fn, value)                                  \
  const char *fn(void *dev) {                                    \
    if (dev == DEV) return (value);                              \
    REAL(fn, fn_s_p)                                           \
    return real_##fn ? real_##fn(dev) : NULL;                    \
  }

PASSTHRU_STR(udev_device_get_syspath, SYSPATH)
PASSTHRU_STR(udev_device_get_sysname, SYSNAME)
PASSTHRU_STR(udev_device_get_subsystem, "sound")
PASSTHRU_STR(udev_device_get_devnode, "/dev/snd/pcmC0D0p")
PASSTHRU_STR(udev_device_get_devtype, NULL)
PASSTHRU_STR(udev_device_get_action, "add")

/* ---- the monitor: this is how the app actually discovers devices ----------
 *
 * The app does not enumerate. Its UDevMonitor adds a "sound" subsystem filter,
 * takes the monitor fd and arms a socket notifier on it ("Set socket notifier,
 * got fd: 10"), so devices only ever arrive as hotplug events. With no udev
 * daemon nothing is ever readable, the device list stays empty, and airHost
 * ends up looking up the device named "".
 *
 * So: hand that one monitor a pipe whose read end is already readable, and
 * answer the resulting receive_device() with our synthetic card, once.
 */
static void *sound_mon;
static int mon_fd = -1;
static int mon_delivered;

int udev_monitor_filter_add_match_subsystem_devtype(void *m, const char *sub,
                                                    const char *devtype) {
  REAL(udev_monitor_filter_add_match_subsystem_devtype, fn_i_pss)
  int r = real_udev_monitor_filter_add_match_subsystem_devtype
              ? real_udev_monitor_filter_add_match_subsystem_devtype(m, sub,
                                                                     devtype)
              : 0;
  if (sub && !strcmp(sub, "sound")) {
    sound_mon = m;
    fprintf(stderr, "[udevshim] monitor %p filters 'sound'\n", m);
  }
  return r;
}

int udev_monitor_get_fd(void *m) {
  if (m && m == sound_mon) {
    if (mon_fd < 0) {
      int fds[2];
      if (pipe(fds) == 0) {
        /* one byte, so the notifier fires exactly once */
        (void)!write(fds[1], "u", 1);
        mon_fd = fds[0];
        fprintf(stderr, "[udevshim] handing monitor fd %d (armed)\n", mon_fd);
      }
    }
    if (mon_fd >= 0) return mon_fd;
  }
  REAL(udev_monitor_get_fd, fn_i_p)
  return real_udev_monitor_get_fd ? real_udev_monitor_get_fd(m) : -1;
}

void *udev_monitor_receive_device(void *m) {
  if (m && m == sound_mon) {
    char c;
    if (mon_fd >= 0) (void)!read(mon_fd, &c, 1); /* drain the arming byte */
    if (!mon_delivered++) {
      fprintf(stderr, "[udevshim] delivering synthetic sound device\n");
      return DEV;
    }
    return NULL;
  }
  REAL(udev_monitor_receive_device, fn_p_p)
  return real_udev_monitor_receive_device ? real_udev_monitor_receive_device(m)
                                          : NULL;
}

void *udev_device_get_parent_with_subsystem_devtype(void *dev, const char *s,
                                                    const char *t) {
  if (dev == DEV) return DEV; /* we are our own USB parent */
  REAL(udev_device_get_parent_with_subsystem_devtype, fn_p_pss)
  return real_udev_device_get_parent_with_subsystem_devtype
             ? real_udev_device_get_parent_with_subsystem_devtype(dev, s, t)
             : NULL;
}

void *udev_device_unref(void *dev) {
  if (dev == DEV) return NULL;
  REAL(udev_device_unref, fn_p_p)
  return real_udev_device_unref ? real_udev_device_unref(dev) : NULL;
}

void *udev_enumerate_unref(void *e) {
  if (mine(e)) return NULL;
  REAL(udev_enumerate_unref, fn_p_p)
  return real_udev_enumerate_unref ? real_udev_enumerate_unref(e) : NULL;
}
